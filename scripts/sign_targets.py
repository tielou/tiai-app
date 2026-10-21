#!/usr/bin/env python3
"""Point every target at its own App Store profile in a generated project.

A profile is bound to exactly one App ID, so the app's profile cannot cover an
extension — Xcode says so with "has app ID co.wobker.tiai, which does not match
the bundle ID co.wobker.tiai.activities". The old step replaced a string that
used to appear once, back when the project had one target; with three it handed
the app's profile to all of them.

Each XCBuildConfiguration block names exactly one product bundle id, so the
blocks are the unit to patch and the bundle id is the key.
"""
import json, os, re, sys

MARKER = "isa = XCBuildConfiguration;"


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "TiAi.xcodeproj/project.pbxproj"
    profiles = {"co.wobker.tiai": os.environ["DISTR_PROFILE_NAME"]}
    extra = (os.environ.get("EXT_PROFILES") or "").strip()
    if extra:
        for bundle, entry in json.loads(extra).items():
            profiles[bundle] = entry["name"]
    else:
        print("::warning:: EXT_PROFILES is not set; extension targets will not "
              "sign and the archive will fail if they are in the build")

    text = open(path).read()
    head, _, body = text.partition("/* Begin XCBuildConfiguration section */")
    if not body:
        print("::error:: no XCBuildConfiguration section found", file=sys.stderr)
        return 1
    # Splitting on the marker keeps every block whole: the marker is emitted once
    # per configuration and nowhere else.
    blocks = body.split(MARKER)
    patched = 0
    for index, block in enumerate(blocks):
        match = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", block)
        if not match:
            continue
        bundle = match.group(1).strip().strip('"')
        name = profiles.get(bundle)
        if not name:
            continue
        if 'CODE_SIGN_IDENTITY = "iPhone Developer";' in block:
            block = block.replace('CODE_SIGN_IDENTITY = "iPhone Developer";',
                                  'CODE_SIGN_IDENTITY = "iPhone Distribution";')
        elif "CODE_SIGN_IDENTITY" not in block:
            # Manual style with no identity left to Xcode's default, which is a
            # *Development* certificate — and a CI keychain holds only the
            # distribution one. That is why the extensions failed with "no
            # signing certificate iOS Development found".
            block = block.replace("PRODUCT_BUNDLE_IDENTIFIER",
                                  'CODE_SIGN_IDENTITY = "iPhone Distribution";\n\t\t\t\t'
                                  "PRODUCT_BUNDLE_IDENTIFIER", 1)
        if "CODE_SIGN_STYLE = Automatic;" in block:
            block = block.replace("CODE_SIGN_STYLE = Automatic;", "CODE_SIGN_STYLE = Manual;")
        elif "CODE_SIGN_STYLE" not in block:
            # XcodeGen only writes what the target sets, so a target that never
            # mentioned signing has nothing to replace.
            block = block.replace("PRODUCT_BUNDLE_IDENTIFIER",
                                  "CODE_SIGN_STYLE = Manual;\n\t\t\t\t"
                                  "PRODUCT_BUNDLE_IDENTIFIER", 1)
        if "PROVISIONING_PROFILE_SPECIFIER" in block:
            block = re.sub(r'PROVISIONING_PROFILE_SPECIFIER = "[^"]*";',
                           f'PROVISIONING_PROFILE_SPECIFIER = "{name}";', block)
        else:
            block = block.replace("PRODUCT_BUNDLE_IDENTIFIER",
                                  f'PROVISIONING_PROFILE_SPECIFIER = "{name}";\n\t\t\t\t'
                                  "PRODUCT_BUNDLE_IDENTIFIER", 1)
        blocks[index] = block
        patched += 1

    if patched == 0:
        print("::error:: no signing settings found to patch — the project layout "
              "changed and this step is now doing nothing", file=sys.stderr)
        return 1
    open(path, "w").write(head + "/* Begin XCBuildConfiguration section */" + MARKER.join(blocks))
    print(f"signed {patched} build configurations: "
          + ", ".join(f"{k} -> {v}" for k, v in sorted(profiles.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
