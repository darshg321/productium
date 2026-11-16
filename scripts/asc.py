#!/usr/bin/env python3
"""App Store Connect API helper. Do the Apple-side setup from Linux, no Mac needed.

Needs an App Store Connect API key (Users and Access → Integrations → Team Keys,
role "Admin" or "App Manager"). Run with uv so nothing gets installed globally:

  export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-... ASC_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8
  uv run --with pyjwt --with cryptography --with requests scripts/asc.py devices
  uv run ... scripts/asc.py register-device "My iPhone" 00008110-001A2B3C4D5E801E
  uv run ... scripts/asc.py dev-cert --out ~/productium-signing --password 'choose-one'
  uv run ... scripts/asc.py secrets --out ~/productium-signing     # prints values for GitHub secrets
"""
import argparse
import base64
import os
import sys
import time
from pathlib import Path

import jwt
import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    key = Path(os.environ["ASC_KEY_PATH"]).expanduser().read_text()
    now = int(time.time())
    return jwt.encode({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def call(method: str, path: str, **kw):
    r = requests.request(method, API + path, headers={"Authorization": f"Bearer {token()}"}, timeout=30, **kw)
    if r.status_code >= 400:
        sys.exit(f"{method} {path} → {r.status_code}\n{r.text}")
    return r.json() if r.text else {}


def devices(_):
    for d in call("GET", "/devices?limit=200")["data"]:
        a = d["attributes"]
        print(f'{a["udid"]}  {a["platform"]:<4} {a["status"]:<8} {a["name"]}')


def register_device(a):
    body = {"data": {"type": "devices", "attributes": {"name": a.name, "udid": a.udid, "platform": "IOS"}}}
    d = call("POST", "/devices", json=body)["data"]
    print("registered", d["attributes"]["name"], d["attributes"]["udid"])


def dev_cert(a):
    out = Path(a.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Productium CI")]))
           .sign(key, hashes.SHA256()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    body = {"data": {"type": "certificates", "attributes": {"certificateType": "DEVELOPMENT", "csrContent": csr_pem}}}
    cert_b64 = call("POST", "/certificates", json=body)["data"]["attributes"]["certificateContent"]
    cert = x509.load_der_x509_certificate(base64.b64decode(cert_b64))
    # Legacy (3DES/SHA1) PKCS#12 so macOS `security import` accepts it.
    enc = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50000)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC).hmac_hash(hashes.SHA1())
           .build(a.password.encode()))
    p12 = pkcs12.serialize_key_and_certificates(b"Productium CI", key, cert, None, enc)
    (out / "dev.p12").write_bytes(p12)
    (out / "dev.key.pem").write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                        serialization.NoEncryption()))
    os.chmod(out / "dev.key.pem", 0o600)
    os.chmod(out / "dev.p12", 0o600)
    print(f"wrote {out/'dev.p12'} ({cert.subject.rfc4514_string()}, expires {cert.not_valid_after_utc:%Y-%m-%d})")


def secrets(a):
    out = Path(a.out).expanduser()
    print("DEV_CERT_P12 =", base64.b64encode((out / "dev.p12").read_bytes()).decode())
    print("ASC_KEY_P8   =", base64.b64encode(Path(os.environ["ASC_KEY_PATH"]).expanduser().read_bytes()).decode())
    print("ASC_KEY_ID   =", os.environ["ASC_KEY_ID"])
    print("ASC_ISSUER_ID=", os.environ["ASC_ISSUER_ID"])
    print("(DEV_CERT_PASSWORD = the password you chose; APPLE_TEAM_ID = Membership details on developer.apple.com)")


p = argparse.ArgumentParser()
s = p.add_subparsers(dest="cmd", required=True)
s.add_parser("devices").set_defaults(f=devices)
r = s.add_parser("register-device"); r.add_argument("name"); r.add_argument("udid"); r.set_defaults(f=register_device)
c = s.add_parser("dev-cert"); c.add_argument("--out", required=True); c.add_argument("--password", required=True); c.set_defaults(f=dev_cert)
e = s.add_parser("secrets"); e.add_argument("--out", required=True); e.set_defaults(f=secrets)
args = p.parse_args()
args.f(args)
