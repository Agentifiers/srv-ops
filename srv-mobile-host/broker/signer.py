"""Development signing for the wired iPhone through the App Store Connect API (the broker's /v1/sign).

The team's ASC key never leaves the host: systemd hands it to the broker as credentials
(LoadCredential=asc.env / asc.p8, see the unit's install drop-in). State in <state>/signing:
key.pem (0600) + cert.der of the broker's own iOS Development certificate, and
profiles/<bundle id>.mobileprovision (IOS_APP_DEVELOPMENT, that certificate, the wired iPhone only).

Policy: explicit bundle ids only, each under one of the allowed prefixes; wildcard ids and any
distribution profile type are never requested.
"""
import base64
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

API = "https://api.appstoreconnect.apple.com"
CERT_NAME = "srv-mobile iphone-broker"
PROFILE_PREFIX = "srv-mobile dev "
BUNDLE_RE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
PROFILED_SUFFIXES = (".app", ".appex")


class SignError(Exception):
    pass


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def profile_payload(raw):
    return plistlib.loads(raw[raw.index(b"<?xml"):raw.rindex(b"</plist>") + 8])


def read_env_file(path):
    env = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


class Signer:
    def __init__(self, state_dir, udid, prefixes, rcodesign="/opt/rcodesign/bin/rcodesign"):
        self.dir = Path(state_dir) / "signing"
        self.udid = udid
        self.prefixes = [p for p in prefixes if p]
        self.rcodesign = rcodesign
        self.lock = threading.Lock()  # one ASC/profile/sign run at a time
        cred = os.environ.get("CREDENTIALS_DIRECTORY")
        self.key_id = self.issuer = self.asc_key = None
        if cred and Path(cred, "asc.env").exists() and Path(cred, "asc.p8").exists():
            env = read_env_file(Path(cred, "asc.env"))
            self.key_id, self.issuer = env.get("ASC_KEY_ID"), env.get("ASC_ISSUER_ID")
            self.asc_key = serialization.load_pem_private_key(Path(cred, "asc.p8").read_bytes(), None)

    @property
    def available(self):
        return bool(self.key_id and self.issuer and self.asc_key and Path(self.rcodesign).exists())

    # ------------------------------------------------------------------ ASC API
    def _token(self):
        now = int(time.time())
        head = _b64(json.dumps({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}).encode())
        body = _b64(json.dumps({"iss": self.issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
        r, s = decode_dss_signature(self.asc_key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256())))
        return f"{head}.{body}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"

    def call(self, method, path, body=None):
        req = urllib.request.Request(API + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": "Bearer " + self._token(),
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                errs = json.loads(detail).get("errors", [])
                detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in errs) or detail
            except ValueError:
                pass
            raise SignError(f"App Store Connect {method} {path.split('?')[0]}: HTTP {e.code}: {detail}") from None
        return json.loads(raw) if raw else {}

    # ------------------------------------------------------------------ identity
    def ensure_certificate(self):
        key_path, cert_path, id_path = self.dir / "key.pem", self.dir / "cert.der", self.dir / "certificate-id"
        if key_path.exists() and cert_path.exists() and id_path.exists():
            cert = x509.load_der_x509_certificate(cert_path.read_bytes())
            cid = id_path.read_text().strip()
            if cert.not_valid_after_utc > datetime.now(timezone.utc) + timedelta(days=7):
                try:
                    self.call("GET", f"/v1/certificates/{cid}")
                    return cid
                except SignError:
                    pass  # revoked in the portal: make a new one
        self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        csr = (x509.CertificateSigningRequestBuilder()
               .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, CERT_NAME)]))
               .sign(key, hashes.SHA256()))
        made = self.call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
            "certificateType": "IOS_DEVELOPMENT",
            "csrContent": csr.public_bytes(serialization.Encoding.PEM).decode()}}})["data"]
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()))
        cert_path.write_bytes(base64.b64decode(made["attributes"]["certificateContent"]))
        id_path.write_text(made["id"] + "\n")
        # Profiles made for the old certificate are useless now.
        shutil.rmtree(self.dir / "profiles", ignore_errors=True)
        return made["id"]

    def device_id(self):
        found = self.call("GET", f"/v1/devices?filter[udid]={self.udid}")["data"]
        if not found or found[0]["attributes"].get("status") != "ENABLED":
            raise SignError(f"iPhone {self.udid} is not an ENABLED device of the team")
        return found[0]["id"]

    def check_bundle_id(self, ident):
        if "*" in ident or not BUNDLE_RE.match(ident):
            raise SignError(f"bundle id {ident!r}: only explicit reverse-DNS ids are signed (no wildcards)")
        if not any(ident.startswith(p) for p in self.prefixes):
            raise SignError(f"bundle id {ident!r} is outside the allowed prefixes {self.prefixes}; "
                            "set the app's bundle identifier under one of them")

    def bundle_id_resource(self, ident):
        for b in self.call("GET", f"/v1/bundleIds?filter[identifier]={ident}&limit=200")["data"]:
            if b["attributes"]["identifier"] == ident:
                return b["id"]
        return self.call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": ident, "name": f"srv-mobile {ident}".replace(".", " ")[:60], "platform": "IOS"}}})["data"]["id"]

    def ensure_profile(self, ident, cert_id):
        path = self.dir / "profiles" / f"{ident}.mobileprovision"
        if path.exists():
            p = profile_payload(path.read_bytes())
            ok_dev = self.udid in p.get("ProvisionedDevices", [])
            ok_time = p["ExpirationDate"].replace(tzinfo=timezone.utc) > datetime.now(timezone.utc) + timedelta(days=7)
            cert_der = (self.dir / "cert.der").read_bytes()
            ok_cert = cert_der in p.get("DeveloperCertificates", [])
            if ok_dev and ok_time and ok_cert:
                return path
        name = PROFILE_PREFIX + ident
        for p in self.call("GET", f"/v1/profiles?filter[name]={urllib.request.quote(name)}&limit=200")["data"]:
            if p["attributes"]["name"] == name:
                self.call("DELETE", f"/v1/profiles/{p['id']}")
        made = self.call("POST", "/v1/profiles", {"data": {"type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_DEVELOPMENT"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": self.bundle_id_resource(ident)}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                "devices": {"data": [{"type": "devices", "id": self.device_id()}]}}}})["data"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(base64.b64decode(made["attributes"]["profileContent"]))
        return path

    # ------------------------------------------------------------------ signing
    @staticmethod
    def _extract(src, work):
        """src: .ipa, or a zip holding X.app at its top level. Returns Payload/X.app."""
        payload = work / "Payload"
        payload.mkdir()
        try:
            with zipfile.ZipFile(src) as z:
                names = z.namelist()
                for n in names:
                    if n.startswith("/") or ".." in Path(n).parts:
                        raise SignError(f"unsafe path in archive: {n}")
                z.extractall(work / "x")
        except zipfile.BadZipFile:
            raise SignError("upload is not a zip/.ipa") from None
        # zip does not keep modes reliably: executables are re-marked below via Info.plist.
        root = work / "x" / "Payload" if (work / "x" / "Payload").is_dir() else work / "x"
        apps = [p for p in root.iterdir() if p.suffix == ".app" and p.is_dir()]
        if len(apps) != 1:
            raise SignError(f"expected exactly one .app at the top of the upload (or in Payload/), found {len(apps)}")
        app = payload / apps[0].name
        shutil.move(str(apps[0]), app)
        return app

    @staticmethod
    def _bundles(app):
        """Every nested bundle with an Info.plist, deepest first, then the app."""
        found = []
        for p in sorted(app.rglob("*"), key=lambda p: -len(p.parts)):
            if p.is_dir() and p.suffix in (".app", ".appex", ".xctest", ".framework", ".bundle") and (p / "Info.plist").exists():
                found.append(p)
        return found + [app]

    def sign(self, src, out_ipa):
        if not self.available:
            raise SignError("signing is not configured on the host (ASC credentials or rcodesign missing)")
        with self.lock, tempfile.TemporaryDirectory(prefix="sign-", dir=self.dir.parent) as tmp:
            work = Path(tmp)
            app = self._extract(src, work)
            for root, dirs, files in os.walk(work):
                for d in dirs:
                    os.chmod(os.path.join(root, d), 0o755)
            plan = []  # (bundle path, bundle id)
            for b in self._bundles(app):
                info = plistlib.loads((b / "Info.plist").read_bytes())
                exe = info.get("CFBundleExecutable")
                if exe and (b / exe).exists():
                    os.chmod(b / exe, 0o755)
                if b.suffix in PROFILED_SUFFIXES:
                    ident = info.get("CFBundleIdentifier", "")
                    self.check_bundle_id(ident)
                    plan.append((b, ident))
            cert_id = self.ensure_certificate()
            args = [self.rcodesign, "sign", "--pem-file", str(self.dir / "key.pem"),
                    "--certificate-der-file", str(self.dir / "cert.der")]
            team = None
            signed = []
            for b, ident in plan:
                prof = self.ensure_profile(ident, cert_id)
                payload = profile_payload(prof.read_bytes())
                team = payload["TeamIdentifier"][0]
                shutil.copyfile(prof, b / "embedded.mobileprovision")
                ent = work / f"ent-{ident}.plist"
                ent.write_bytes(plistlib.dumps(payload["Entitlements"]))
                rel = b.relative_to(app).as_posix()
                args += ["--entitlements-xml-file", f"{ent}" if rel == "." else f"{rel}:{ent}"]
                signed.append({"bundle_id": ident, "path": rel, "profile_expires": payload["ExpirationDate"].isoformat()})
            args += ["--team-name", team, str(app)]
            r = subprocess.run(args, capture_output=True, text=True, timeout=900)
            if r.returncode:
                raise SignError("rcodesign failed: " + (r.stderr or r.stdout)[-2000:])
            out_ipa = Path(out_ipa)
            with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED) as z:
                for p in sorted(app.parent.parent.joinpath("Payload").rglob("*")):
                    arc = p.relative_to(work).as_posix()
                    if p.is_symlink():
                        zi = zipfile.ZipInfo(arc)
                        zi.create_system = 3
                        zi.external_attr = (0o120777 << 16)
                        z.writestr(zi, os.readlink(p))
                    elif p.is_file():
                        z.write(p, arc)
            return {"bundle_ids": signed, "team": team, "app": app.name}
