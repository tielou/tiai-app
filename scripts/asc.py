#!/usr/bin/env python3
"""Talk to App Store Connect API with the local ASC key.

Used to register the two extension bundle ids and read back what already
exists. Writes nothing unless asked.
"""
import base64, json, sys, time, urllib.request, pathlib
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

KEY_ID = "94Y728XG8T"
ISSUER_ID = "1d9bbba2-815d-4b8c-bc37-3f7e4c223cc1"
KEY_PATH = pathlib.Path.home() / ".appstoreconnect/private_keys/AuthKey_94Y728XG8T.p8"
BASE = "https://api.appstoreconnect.apple.com"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token() -> str:
    key = serialization.load_pem_private_key(KEY_PATH.read_bytes(), password=None)
    now = int(time.time())
    header = _b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    payload = _b64(json.dumps({"iss": ISSUER_ID, "iat": now,
                               "exp": now + 500}).encode())
    # Kept as a str and encoded separately: an f-string over the bytes gives
    # "b'eyJ...'", which Apple rejects as a malformed bearer token.
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
        return e.code, json.loads(e.read() or b"{}")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "list"
    if what == "list":
        for kind in ("bundleIds", "certificates"):
            status, data = call("GET", f"/v1/{kind}?limit=50")
            print(f"--- {kind} ({status})")
            for item in data.get("data", []):
                a = item["attributes"]
                if kind == "bundleIds":
                    print("  ", a.get("identifier"), "|", a.get("name"), "|", a.get("platform"))
                else:
                    print("  ", a.get("name"), "|", a.get("certificateType"),
                          "|", a.get("expirationDate"))
    elif what == "profiles":
        status, data = call("GET", "/v1/profiles?limit=50")
        print(f"--- profiles ({status})")
        for item in data.get("data", []):
            a = item["attributes"]
            print("  ", a.get("name"), "|", a.get("profileType"), "|", a.get("uuid"))
            print("     includes:", [x["id"] for x in item.get("relationships", {})
                                     .get("bundleId", {}).get("data", [])] or "see relationships")
    else:
        print("usage: asc.py [list|profiles]")
