#!/usr/bin/env python3
"""Register the extension App IDs and their distribution profiles.

Runs in CI, where the working App Store Connect API credentials live as
secrets. The local copies of the key on a dev machine may be stale, and this
never needs to see one: it reads the same env vars the upload step already uses.

What it does, idempotently:

  1. makes sure an App ID exists for each extension bundle id
  2. mints an App Store distribution profile for each one
  3. writes them to `profiles.json` as {name: base64}, for the caller to store

An App Store profile is bound to exactly one bundle id, so the app's existing
profile cannot simply grow to cover the extensions — each needs its own.

Step 2 does not work on this account: `GET/POST /v1/provisioningProfiles`
answers 404 "the path provided does not match a defined resource type" for both
API keys, Admin included, while every other endpoint works. So the profiles have
to come from somewhere else — `xcodebuild -allowProvisioningUpdates` creates
them during an archive, which is the path actually taken. Step 1 is what this
script is for now, and it is the part that had to happen before Xcode could do
the rest.
"""
import base64, json, os, pathlib, sys, time, urllib.error, urllib.request
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

BASE = "https://api.appstoreconnect.apple.com"
EXTENSIONS = [
    ("co.wobker.tiai.activities", "tiAi Activities"),
    ("co.wobker.tiai.share", "tiAi Share"),
]
_profile_names = {}


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token() -> str:
    # Stripped because a secret set from a shell heredoc often carries a trailing
    # newline, and a `kid` of "ABC123\n" is a perfectly well-signed token that
    # matches no key — which Apple reports as a generic 401, not as a bad kid.
    key_id = os.environ["ASC_KEY_ID"].strip()
    issuer = os.environ["ASC_ISSUER_ID"].strip()
    pem = base64.b64decode(os.environ["ASC_API_KEY"].strip())
    key = serialization.load_pem_private_key(pem, password=None)
    now = int(time.time())
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    # `aud` is not optional here. Apple's REST API rejects a token without it as
    # a generic 401 — a terrible error to get for a missing claim. `notarytool`
    # accepted the same key, which is what pointed here.
    payload = _b64(json.dumps({"iss": issuer, "aud": "appstoreconnect-v1",
                               "iat": now, "exp": now + 500}).encode())
    unsigned = f"{header}.{payload}"
    der = key.sign(unsigned.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    sig = _b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    return f"{unsigned}.{sig}"


def call(method: str, path: str, body=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data=data, timeout=60) as res:
            raw = res.read()
            return res.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except Exception:
            return e.code, {"raw": raw.decode(errors="replace")}


def fail(status, payload):
    # The whole body, not just the first field: Apple distinguishes a bad
    # signature from a key that does not exist from a key with the wrong role,
    # and the difference decides what to do next.
    print(f"::error:: HTTP {status}: {json.dumps(payload)[:600]}", file=sys.stderr)
    sys.exit(1)


def existing_bundle_ids():
    status, data = call("GET", "/v1/bundleIds?limit=200")
    if status != 200:
        fail(status, data)
    return {i["attributes"]["identifier"]: i["id"] for i in data.get("data", [])}


def distribution_certificate():
    # Brackets percent-encoded: unencoded they do not survive urllib's request
    # line and Apple answers 404 "path does not match a defined resource type",
    # which reads like a missing endpoint rather than a mangled query.
    status, data = call("GET",
                        "/v1/certificates?filter%5BcertificateType%5D=IOS_DISTRIBUTION")
    if status != 200:
        fail(status, data)
    certs = data.get("data", [])
    if not certs:
        print("::error:: no iOS distribution certificate found", file=sys.stderr)
        sys.exit(1)
    # Newest first is the one that has not expired.
    certs.sort(key=lambda c: c["attributes"].get("expirationDate", ""), reverse=True)
    return certs[0]["id"]


def existing_profiles():
    status, data = call("GET", "/v1/provisioningProfiles?limit=200")
    if status != 200:
        fail(status, data)
    return {i["attributes"]["name"]: i for i in data.get("data", [])}


def main():
    bundles = existing_bundle_ids()
    print(f"App IDs on the account: {sorted(bundles)}")

    for identifier, name in EXTENSIONS:
        if identifier in bundles:
            print(f"App ID exists: {identifier}")
            continue
        status, data = call("POST", "/v1/bundleIds", {
            "data": {"type": "bundleIds", "attributes": {
                "identifier": identifier, "name": name, "platform": "IOS"}}})
        if status in (201, 409):
            print(f"App ID ready: {identifier}")
        else:
            fail(status, data)

    bundles = existing_bundle_ids()
    cert_id = distribution_certificate()
    print(f"Using distribution certificate {cert_id}")

    profiles = existing_profiles()
    out = {}
    for identifier, name in EXTENSIONS:
        profile_name = f"{name} Distribution"
        if profile_name in profiles:
            print(f"profile exists: {profile_name} (re-issuing to be sure it is current)")
        status, data = call("POST", "/v1/provisioningProfiles", {
            "data": {"type": "provisioningProfiles", "attributes": {
                "name": profile_name, "platform": "IOS",
                "profileType": "IOS_DISTRIBUTION"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundles[identifier]}},
                    "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
        if status != 201:
            fail(status, data)
        content = data["data"]["attributes"]["profileContent"]
        out[profile_name] = content
        print(f"profile minted: {profile_name} ({len(content)} bytes base64)")

    pathlib.Path("profiles.json").write_text(json.dumps(out))
    print(f"wrote profiles.json with {len(out)} profiles")


if __name__ == "__main__":
    main()
