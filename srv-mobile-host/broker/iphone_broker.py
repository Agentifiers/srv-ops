#!/opt/pymobiledevice3/bin/python
"""iphone-broker: one USB-attached iPhone shared by Amp orbs over the tailnet, with an exclusive lease.

HTTP API on BROKER_BIND:BROKER_PORT (the host's tailnet address only). Callers are identified with
Tailscale WhoIs (tailscaled's local API); see ../README.md for the API and the policy. Device work
goes through pmd3-tunneld's USB CoreDevice tunnel, one pymobiledevice3 subprocess per operation
(killed on timeout), plus pmd3_helper.py for what the CLI does not expose.
"""
import asyncio
import collections
import io
import json
import logging
import os
import plistlib
import re
import secrets
import shutil
import signal
import socket
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.parse import quote

import uvicorn
from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response, StreamingResponse
from starlette.routing import Route

sys.path.insert(0, str(Path(__file__).resolve().parent))
from signer import SignError, Signer  # noqa: E402
from pymobiledevice3.irecv_devices import IRECV_DEVICES  # noqa: E402

MODELS = {d.product_type: d.display_name for d in IRECV_DEVICES}

log = logging.getLogger("iphone-broker")


def env_list(name, default=""):
    return [x.strip() for x in os.environ.get(name, default).replace(",", " ").split() if x.strip()]


# Settings come from /etc/srv-mobile/iphone-broker.env (see iphone-broker.env.example).
# Access lists default to empty: no orbs, no admins, no installable or signable bundle ids.
UDID = os.environ.get("IPHONE_UDID", "")  # empty: discovered at startup (tunneld, then usbmuxd)
BIND = os.environ.get("BROKER_BIND", "")  # required: the host's tailnet address
PORT = int(os.environ.get("BROKER_PORT", "8787"))
_lo, _hi = os.environ.get("FORWARD_PORTS", "8790-8799").split("-")
FORWARD_PORTS = list(range(int(_lo), int(_hi) + 1))
ALLOW_TAGS = set(env_list("ALLOW_TAGS"))
ADMIN_LOGINS = set(env_list("ADMIN_LOGINS"))
TEST_NODES = set(env_list("TEST_NODES"))
IDLE_TIMEOUT = int(os.environ.get("IDLE_TIMEOUT", "600"))
BUNDLE_PREFIXES = env_list("BUNDLE_PREFIXES")
LAUNCH_ALLOW = set(env_list("LAUNCH_ALLOW", "com.apple.Preferences com.apple.mobilesafari"))
TUNNELD = os.environ.get("TUNNELD", "127.0.0.1:49151")
# "lat,lon" of where the phone really is. After a simulated location the phone keeps the
# simulated place's time zone until it gets a fix of its own; simulating this spot for a
# moment before clearing puts the clock back right away.
HOME_LOCATION = os.environ.get("HOME_LOCATION", "")
PMD3 = os.environ.get("PMD3", "/opt/pymobiledevice3/bin/pymobiledevice3")
PYTHON = os.environ.get("PMD3_PYTHON", "/opt/pymobiledevice3/bin/python")
HELPER = str(Path(__file__).resolve().parent / "pmd3_helper.py")
TS_SOCK = os.environ.get("TAILSCALED_SOCKET", "/run/tailscale/tailscaled.sock")
STATE_DIR = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/iphone-broker").split(":")[0])
MAX_UPLOAD = int(os.environ.get("MAX_UPLOAD_MB", "4096")) * 1024 * 1024
MAX_STREAM_SECONDS = 600
# System processes whose logs matter for installing/launching/testing apps.
SYSLOG_SYSTEM = {"SpringBoard", "installd", "runningboardd", "testmanagerd", "amfid", "kernel"}
LOCKDOWN_INFO_KEYS = ("DeviceName", "ProductType", "HardwareModel", "ProductVersion", "BuildVersion",
                      "UniqueDeviceID", "DeviceClass", "CPUArchitecture", "TimeZone")


def fail(status, msg, **extra):
    raise HTTPException(status, json.dumps({"error": msg, **extra}))


# ====================================================================== subprocesses
def _pmd3_env():
    return {"PATH": "/usr/local/bin:/usr/bin", "HOME": str(STATE_DIR), "PYMOBILEDEVICE3_TUNNEL": UDID,
            "PYTHONUNBUFFERED": "1", "LANG": "C.UTF-8", "TERM": "dumb", "COLUMNS": "200", "NO_COLOR": "1"}


async def spawn(*argv, merge=False, quiet=False):
    """merge: stderr into stdout; quiet: no output pipes at all (long-lived helpers)."""
    out = asyncio.subprocess.DEVNULL if quiet else asyncio.subprocess.PIPE
    err = asyncio.subprocess.DEVNULL if quiet else asyncio.subprocess.STDOUT if merge else asyncio.subprocess.PIPE
    return await asyncio.create_subprocess_exec(*argv, stdin=asyncio.subprocess.DEVNULL, stdout=out, stderr=err,
                                                env=_pmd3_env(), start_new_session=True)


def kill_group(proc):
    if proc and proc.returncode is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


async def run(*argv, timeout=60.0):
    """Run a command; returns (rc, stdout bytes, stderr text). rc -9 on timeout."""
    proc = await spawn(*argv)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        kill_group(proc)
        await proc.wait()
        return -9, b"", f"timed out after {timeout:.0f}s"
    return proc.returncode, out, err.decode(errors="replace")


def last_error(err):
    lines = [ln.strip() for ln in err.splitlines() if ln.strip() and not ln.strip().startswith(("│", "╭", "╰", "Traceback"))]
    for ln in reversed(lines):
        if "ERROR" in ln or "Error" in ln or "error" in ln:
            return ln[-500:]
    return (lines[-1] if lines else "failed")[-500:]


async def pmd3(*args, timeout=60.0, ok=True):
    rc, out, err = await run(PMD3, *args, timeout=timeout)
    if ok and rc != 0:
        fail(502, f"pymobiledevice3 {' '.join(args[:3])}: {last_error(err)}")
    return rc, out, err


async def pmd3_json(*args, timeout=60.0):
    _, out, _ = await pmd3(*args, timeout=timeout)
    try:
        return json.loads(out)
    except ValueError:
        fail(502, f"pymobiledevice3 {' '.join(args[:3])}: unexpected output")


# ====================================================================== tailscale identity
class Caller:
    def __init__(self, name, role, login, ip):
        self.name, self.role, self.login, self.ip = name, role, login, ip

    @property
    def admin(self):
        return self.role == "admin"

    def json(self):
        return {"node": self.name, "role": self.role, "login": self.login, "ip": self.ip}


_whois_cache = {}


async def whois(ip, port):
    hit = _whois_cache.get(ip)
    if hit and hit[0] > time.monotonic():
        return hit[1]
    addr = f"[{ip}]:{port}" if ":" in ip else f"{ip}:{port}"
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(TS_SOCK), 5)
        writer.write(f"GET /localapi/v0/whois?addr={quote(addr)} HTTP/1.0\r\nHost: local-tailscaled.sock\r\n\r\n".encode())
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(), 5)
        writer.close()
    except (OSError, asyncio.TimeoutError) as e:
        log.warning("whois %s: %s", addr, e)
        return None
    head, _, body = raw.partition(b"\r\n\r\n")
    if b" 200 " not in head.split(b"\r\n", 1)[0]:
        return None
    try:
        data = json.loads(body)
    except ValueError:
        return None
    _whois_cache[ip] = (time.monotonic() + 30, data)
    return data


async def identify(ip, port):
    data = await whois(ip, port)
    if not data:
        return None
    node = data.get("Node") or {}
    name = (node.get("Name") or node.get("ComputedName") or "").split(".")[0]
    tags = set(node.get("Tags") or [])
    login = (data.get("UserProfile") or {}).get("LoginName", "")
    if tags & ALLOW_TAGS:
        role = "orb"
    elif name in TEST_NODES:
        role = "test"
    elif not tags and login in ADMIN_LOGINS:
        role = "admin"
    else:
        return Caller(name, None, login, ip)
    return Caller(name, role, login, ip)


async def caller_of(request: Request) -> Caller:
    host, port = request.client.host, request.client.port
    c = await identify(host, port)
    if c is None:
        fail(401, f"{host} is not a known tailnet node")
    if c.role is None:
        fail(403, f"node {c.name} ({c.login}) may not use the iPhone broker: needs one of {sorted(ALLOW_TAGS)}, "
                  f"or an untagged device of {sorted(ADMIN_LOGINS)}")
    return c


# ====================================================================== state
class Broker:
    def __init__(self):
        self.state_file = STATE_DIR / "state.json"
        st = {}
        if self.state_file.exists():
            try:
                st = json.loads(self.state_file.read_text())
            except ValueError:
                st = {}
        self.holder = st.get("holder")
        self.holder_role = st.get("holder_role")
        self.since = st.get("since")
        self.last_activity = st.get("last_activity")
        self.installed = st.get("installed", {})  # bundle id -> {"by": node, "at": ts}
        self.phone = {"connected": False, "udid": UDID, "name": None, "ios": None, "build": None,
                      "product_type": None, "model": None, "ddi_mounted": None, "battery": None,
                      "screen": {"state": "unknown", "checked_at": None}, "tunnel": None}
        self.display = None  # (width px, height px, scale)
        self.forwards = {}  # listen port -> Forward
        self.xcuitest = None
        self.location = None
        self.streams = set()  # holder's running subprocesses (console/syslog), killed on release
        self.hid_lock = asyncio.Lock()
        self.last_device_op = 0.0
        self.keepawake = None
        self.live = None  # Supervised serve-web
        self.live_password = None
        self.signer = Signer(STATE_DIR, UDID, BUNDLE_PREFIXES)

    def save(self):
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps({"holder": self.holder, "holder_role": self.holder_role, "since": self.since,
                                   "last_activity": self.last_activity, "installed": self.installed}, indent=1))
        tmp.replace(self.state_file)

    def touch(self):
        self.last_activity = time.time()
        self.last_device_op = time.monotonic()

    def lease_json(self):
        idle = time.time() - self.last_activity if self.holder else None
        return {"holder": self.holder, "holder_role": self.holder_role, "since": self.since,
                "last_activity": self.last_activity, "idle_seconds": round(idle) if idle is not None else None,
                "idle_timeout": IDLE_TIMEOUT,
                "expires_in": max(0, round(IDLE_TIMEOUT - idle)) if idle is not None else None}

    async def release(self, reason):
        log.info("lease of %s released (%s)", self.holder, reason)
        self.holder = self.holder_role = self.since = self.last_activity = None
        self.save()
        for fwd in list(self.forwards.values()):
            await fwd.close()
        self.forwards.clear()
        for proc in list(self.streams):
            kill_group(proc)
        self.streams.clear()
        if self.xcuitest:
            await self.xcuitest.stop()
            self.xcuitest = None
        if self.location:
            await end_location()


B: Broker = None  # set in main()


def held_for():
    return (f"held for {round((time.time() - B.since) / 60)} min, "
            f"idle {round(time.time() - B.last_activity)}s")


def require_holder(c: Caller):
    if B.holder is None:
        fail(409, "no lease: run `iphone lease acquire` (POST /v1/lease) first", holder=None)
    if B.holder != c.name:
        fail(409, f"the iPhone is leased by {B.holder} ({held_for()}; auto-release after {IDLE_TIMEOUT}s idle)",
             holder=B.holder, lease=B.lease_json())
    if not B.phone["connected"]:
        fail(503, "the iPhone is not connected (no USB tunnel); retry in a minute or ask the host admin")
    B.touch()


def allowed_app(c: Caller, bundle_id, action):
    if c.admin or bundle_id in B.installed or (action == "launch" and bundle_id in LAUNCH_ALLOW):
        return
    fail(403, f"{action} {bundle_id}: only apps installed through the broker"
              + (f" or {sorted(LAUNCH_ALLOW)}" if action == "launch" else "") + " (the rest of the phone is off limits)")


async def body_json(request):
    raw = await request.body()
    if not raw:
        return {}
    try:
        d = json.loads(raw)
    except ValueError:
        fail(400, "body is not JSON")
    if not isinstance(d, dict):
        fail(400, "body must be a JSON object")
    return d


async def save_upload(request, suffix):
    STATE_DIR.joinpath("uploads").mkdir(exist_ok=True)
    fd, path = tempfile.mkstemp(suffix=suffix, dir=STATE_DIR / "uploads")
    size = 0
    with os.fdopen(fd, "wb") as f:
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_UPLOAD:
                f.close()
                os.unlink(path)
                fail(413, f"upload larger than {MAX_UPLOAD >> 20} MiB")
            f.write(chunk)
    if size == 0:
        os.unlink(path)
        fail(400, "empty upload")
    return Path(path)


# ====================================================================== device helpers
async def tunneld_tunnels():
    """tunneld's `GET /`: {udid: [tunnel, ...]}; None when tunneld does not answer."""
    host, port = TUNNELD.split(":")
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(host, int(port)), 3)
        writer.write(f"GET / HTTP/1.0\r\nHost: {TUNNELD}\r\n\r\n".encode())
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(), 5)
        writer.close()
        tunnels = json.loads(raw.partition(b"\r\n\r\n")[2])
    except (OSError, ValueError, asyncio.TimeoutError):
        return None
    return tunnels if isinstance(tunnels, dict) else None


async def tunnel_address():
    tunnels = ((await tunneld_tunnels()) or {}).get(UDID) or []
    return tunnels[0]["tunnel-address"] if tunnels else None


async def discover_udid():
    """The one iPhone that tunneld has a tunnel to, else the one usbmuxd sees on USB."""
    udids = sorted(await tunneld_tunnels() or {})
    if not udids:
        from pymobiledevice3.usbmux import list_devices
        try:
            udids = sorted({d.serial for d in await list_devices() if d.is_usb})
        except Exception as e:  # usbmuxd not running, socket missing, ...
            log.warning("usbmuxd: %s", e)
    if len(udids) == 1:
        return udids[0]
    if not udids:
        sys.exit("no iPhone found through pmd3-tunneld or usbmuxd; plug it in (USB-paired) or set IPHONE_UDID")
    sys.exit(f"several iPhones attached ({', '.join(udids)}): set IPHONE_UDID to the one to share")


async def display_size():
    if B.display is None:
        info = await pmd3_json("developer", "core-device", "get-display-info", timeout=30)
        d = info["displays"][0]
        w, h = d["bounds"][1]
        scale = d.get("currentMode", {}).get("preferredUIScale") or d["availableModes"][0].get("preferredUIScale", 3)
        B.display = (float(w), float(h), float(scale))
    return B.display


async def to_norm(x, y, unit):
    if unit == "norm":
        return int(x), int(y)
    w, h, scale = await display_size()
    if unit == "pt":
        x, y = x * scale, y * scale
    elif unit != "px":
        fail(400, "unit must be px (screenshot pixels, default), pt (points) or norm (0..65535)")
    clamp = lambda v: max(0, min(65535, int(round(v))))
    return clamp(x / w * 65535), clamp(y / h * 65535)


async def screenshot_png():
    fd, path = tempfile.mkstemp(suffix=".png", dir=STATE_DIR)
    os.close(fd)
    try:
        rc, _, err = await pmd3("developer", "dvt", "screenshot", path, timeout=30, ok=False)
        if rc != 0:  # fall back to CoreDevice's screen capture service
            await pmd3("developer", "core-device", "screen-capture", "screenshot", path, timeout=30)
        return Path(path).read_bytes()
    finally:
        os.unlink(path)


def is_black(png):
    from PIL import Image, ImageStat
    im = Image.open(io.BytesIO(png)).convert("L").resize((64, 128))
    return ImageStat.Stat(im).mean[0] < 2.0


async def press(button):
    async with B.hid_lock:
        await pmd3("developer", "core-device", "hid", "button", button, timeout=30)


async def wake():
    """Screen off -> lock screen -> home screen (no passcode). Returns the screen state seen first."""
    png = await screenshot_png()
    if not is_black(png):
        return "on"
    await press("home")
    await asyncio.sleep(1.0)
    await press("home")
    await asyncio.sleep(1.0)
    B.phone["screen"] = {"state": "on" if not is_black(await screenshot_png()) else "off", "checked_at": time.time()}
    return "off"


# ====================================================================== monitor
async def monitor():
    """Phone state, DDI auto-mount (also after a reboot), keep-awake, idle lease release."""
    last_battery = last_screen = 0.0
    while True:
        try:
            if B.holder and time.time() - B.last_activity > IDLE_TIMEOUT:
                await B.release(f"idle for {IDLE_TIMEOUT}s")
            addr = await tunnel_address()
            was = B.phone["connected"]
            B.phone["connected"] = addr is not None
            B.phone["tunnel"] = addr
            if addr and not was:
                log.info("iPhone tunnel up at %s", addr)
                B.display = None
                last_battery = last_screen = 0.0
            if not addr:
                B.phone["ddi_mounted"] = None
                if was:
                    log.warning("iPhone tunnel gone")
            else:
                if B.phone.get("ios") is None:
                    rc, out, _ = await pmd3("lockdown", "info", timeout=30, ok=False)
                    if rc == 0:
                        i = json.loads(out)
                        B.phone.update(name=i.get("DeviceName"), ios=i.get("ProductVersion"),
                                       build=i.get("BuildVersion"), product_type=i.get("ProductType"),
                                       model=MODELS.get(i.get("ProductType"), i.get("ProductType")))
                rc, out, err = await pmd3("mounter", "list", timeout=30, ok=False)
                mounted = rc == 0 and json.loads(out or b"[]") != []
                if not mounted and rc == 0:
                    log.info("DDI not mounted: auto-mount")
                    rc2, _, err2 = await pmd3("mounter", "auto-mount", timeout=300, ok=False)
                    if rc2 != 0:
                        log.warning("auto-mount failed: %s", last_error(err2))
                    rc, out, _ = await pmd3("mounter", "list", timeout=30, ok=False)
                    mounted = rc == 0 and json.loads(out or b"[]") != []
                B.phone["ddi_mounted"] = mounted if rc == 0 else None
                if B.keepawake is None or B.keepawake.returncode is not None:
                    B.keepawake = await spawn(PYTHON, HELPER, "keepawake", UDID, "900", quiet=True)
                now = time.monotonic()
                if now - last_battery > 120:
                    last_battery = now
                    rc, out, _ = await pmd3("diagnostics", "battery", "single", timeout=30, ok=False)
                    if rc == 0:
                        b = json.loads(out)
                        B.phone["battery"] = {"percent": b.get("CurrentCapacity"), "charging": b.get("IsCharging"),
                                              "external_power": b.get("ExternalConnected"),
                                              "temperature_c": (b.get("Temperature") or 0) / 100 or None}
                # Screen: checked every 3 min while nobody drove the phone for a minute. Woken
                # automatically only while no one holds the lease (pressing home would leave their app).
                if now - last_screen > 180 and now - B.last_device_op > 60:
                    last_screen = now
                    png = await screenshot_png()
                    state = "off" if is_black(png) else "on"
                    B.phone["screen"] = {"state": state, "checked_at": time.time()}
                    if state == "off" and B.holder is None:
                        log.info("screen off and no lease: waking")
                        await wake()
        except HTTPException as e:
            log.warning("monitor: %s", e.detail)
        except Exception:
            log.exception("monitor")
        await asyncio.sleep(30)


# ====================================================================== TCP forwards
class Forward:
    """Listener on BIND:port that pipes each connection of the allowed node(s) to a target."""

    def __init__(self, port, kind, device_port=None, local_port=None, allow_admin=False):
        self.port, self.kind, self.device_port, self.local_port = port, kind, device_port, local_port
        self.allow_admin = allow_admin
        self.server = None
        self.conns = set()

    async def start(self):
        self.server = await asyncio.start_server(self.handle, BIND, self.port, reuse_address=True)

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        c = await identify(peer[0], peer[1])
        if c is None or not (c.name == B.holder or (self.allow_admin and c.admin)):
            log.warning("forward :%s refused %s", self.port, c.name if c else peer[0])
            writer.close()
            return
        if self.kind == "device":
            addr = await tunnel_address()
            target = (addr, self.device_port)
        else:
            target = ("127.0.0.1", self.local_port)
        try:
            r2, w2 = await asyncio.wait_for(asyncio.open_connection(*target), 10)
        except (OSError, asyncio.TimeoutError) as e:
            log.warning("forward :%s -> %s: %s", self.port, target, e)
            writer.close()
            return
        if c.name == B.holder:
            B.touch()

        async def pipe(src, dst):
            try:
                while data := await src.read(65536):
                    dst.write(data)
                    await dst.drain()
                    if c.name == B.holder:
                        B.last_activity = time.time()
            except (OSError, asyncio.CancelledError):
                pass
            finally:
                try:
                    dst.close()
                except OSError:
                    pass

        task = asyncio.gather(pipe(reader, w2), pipe(r2, writer))
        self.conns.add(task)
        try:
            await task
        finally:
            self.conns.discard(task)

    async def close(self):
        if self.server:
            self.server.close()
        for t in list(self.conns):
            t.cancel()
        if self.kind == "live" and B.live:
            await B.live.stop()
            B.live = None

    def json(self):
        return {"port": self.port, "host": BIND, "kind": self.kind, "device_port": self.device_port,
                "connections": len(self.conns)}


def free_forward_port():
    for p in FORWARD_PORTS:
        if p not in B.forwards:
            return p
    fail(503, f"all forward ports {FORWARD_PORTS[0]}-{FORWARD_PORTS[-1]} are in use")


# ====================================================================== supervised processes
class Supervised:
    """A long-running pymobiledevice3 process (xcuitest, location) with a log ring buffer."""

    def __init__(self, argv, meta):
        self.argv, self.meta = argv, meta
        self.proc = None
        self.log = collections.deque(maxlen=4000)
        self.seq = 0
        self.started = time.time()
        self.reader = None

    async def start(self, stdin=False):
        self.proc = await asyncio.create_subprocess_exec(
            *self.argv, stdin=asyncio.subprocess.PIPE if stdin else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, env=_pmd3_env(), start_new_session=True)
        self.reader = asyncio.create_task(self._read())

    async def _read(self):
        while line := await self.proc.stdout.readline():
            self.seq += 1
            self.log.append((self.seq, line.decode(errors="replace").rstrip("\n")))

    async def stop(self):
        kill_group(self.proc)
        if self.proc:
            try:
                await asyncio.wait_for(self.proc.wait(), 10)
            except asyncio.TimeoutError:
                os.killpg(self.proc.pid, signal.SIGKILL)

    def json(self, since=0):
        rc = self.proc.returncode if self.proc else None
        return {**self.meta, "state": "running" if rc is None else "exited", "returncode": rc,
                "started": self.started, "log_seq": self.seq,
                "log": [ln for s, ln in self.log if s > since]}


# ====================================================================== handlers
async def h_whoami(request):
    c = await caller_of(request)
    return JSONResponse({**c.json(), "holder": B.holder})


async def h_status(request):
    await caller_of(request)
    return JSONResponse({"lease": B.lease_json(), "phone": B.phone,
                         "forwards": [f.json() for f in B.forwards.values()],
                         "xcuitest": B.xcuitest.json(10**12) if B.xcuitest else None,
                         "signing": {"available": B.signer.available, "bundle_prefixes": BUNDLE_PREFIXES}})


async def h_lease_acquire(request):
    c = await caller_of(request)
    if B.holder and B.holder != c.name:
        fail(409, f"the iPhone is leased by {B.holder} ({held_for()}; auto-release after {IDLE_TIMEOUT}s idle). "
                  "Try again later.", holder=B.holder, lease=B.lease_json())
    if B.holder != c.name:
        B.holder, B.holder_role, B.since = c.name, c.role, time.time()
        log.info("lease acquired by %s (%s)", c.name, c.role)
    B.last_activity = time.time()
    B.save()
    return JSONResponse({"lease": B.lease_json(), "phone": B.phone})


async def h_lease_renew(request):
    c = await caller_of(request)
    if B.holder != c.name:
        fail(409, f"you do not hold the lease (holder: {B.holder})", holder=B.holder)
    B.last_activity = time.time()
    B.save()
    return JSONResponse({"lease": B.lease_json()})


async def h_lease_release(request):
    c = await caller_of(request)
    force = request.query_params.get("force") in ("1", "true", "yes")
    if B.holder is None:
        return JSONResponse({"released": False, "lease": B.lease_json()})
    if B.holder != c.name:
        if not (force and c.admin):
            fail(409 if not force else 403, f"the lease is held by {B.holder}"
                 + ("; only an admin can force-release it" if force else ""), holder=B.holder)
    await B.release(f"released by {c.name}" + (" (forced)" if B.holder != c.name else ""))
    return JSONResponse({"released": True, "lease": B.lease_json()})


async def h_info(request):
    c = await caller_of(request)
    require_holder(c)
    info = await pmd3_json("lockdown", "info", timeout=30)
    w, h, scale = await display_size()
    return JSONResponse({**{k: info.get(k) for k in LOCKDOWN_INFO_KEYS},
                         "display": {"width_px": w, "height_px": h, "scale": scale,
                                     "width_pt": w / scale, "height_pt": h / scale},
                         "battery": B.phone["battery"], "ddi_mounted": B.phone["ddi_mounted"],
                         "screen": B.phone["screen"]})


async def h_screenshot(request):
    c = await caller_of(request)
    require_holder(c)
    png = await screenshot_png()
    B.phone["screen"] = {"state": "off" if is_black(png) else "on", "checked_at": time.time()}
    fmt = request.query_params.get("format", "png")
    scale = float(request.query_params.get("scale", "1"))
    if fmt == "png" and scale == 1:
        return Response(png, media_type="image/png")

    def convert():
        from PIL import Image
        im = Image.open(io.BytesIO(png)).convert("RGB")
        if scale != 1:
            im = im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG" if fmt == "jpeg" else "PNG", quality=85)
        return buf.getvalue()

    if fmt not in ("png", "jpeg") or not 0.05 <= scale <= 1:
        fail(400, "format must be png|jpeg, scale 0.05..1")
    return Response(await asyncio.to_thread(convert), media_type=f"image/{fmt}")


async def h_wake(request):
    c = await caller_of(request)
    require_holder(c)
    before = await wake()
    return JSONResponse({"screen_before": before, "screen": B.phone["screen"]})


async def h_apps(request):
    c = await caller_of(request)
    require_holder(c)
    kind = "Any" if request.query_params.get("all") in ("1", "true") else "User"
    apps = await pmd3_json("apps", "list", "--type", kind, timeout=60)
    return JSONResponse([{"bundle_id": bid, "name": a.get("CFBundleDisplayName") or a.get("CFBundleName"),
                          "version": a.get("CFBundleShortVersionString"), "build": a.get("CFBundleVersion"),
                          "type": a.get("ApplicationType"), "path": a.get("Path"),
                          "installed_by_broker": bid in B.installed}
                         for bid, a in sorted(apps.items())])


def ipa_bundle_id(path):
    try:
        with zipfile.ZipFile(path) as z:
            plists = [n for n in z.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
            if len(plists) != 1:
                fail(400, "not an .ipa: expected exactly one Payload/<name>.app/Info.plist")
            return plistlib.loads(z.read(plists[0]))["CFBundleIdentifier"]
    except zipfile.BadZipFile:
        fail(400, "not an .ipa (zip)")


async def h_install(request):
    c = await caller_of(request)
    require_holder(c)
    path = await save_upload(request, ".ipa")
    try:
        bid = ipa_bundle_id(path)
        if not c.admin:
            if not any(bid.startswith(p) for p in BUNDLE_PREFIXES):
                fail(403, f"{bid}: only bundle ids under {BUNDLE_PREFIXES} may be installed")
            if bid not in B.installed:
                apps = await pmd3_json("apps", "list", "--type", "User", timeout=60)
                if bid in apps:
                    fail(403, f"{bid} is already on the phone and was not installed by the broker (the owner's app); refusing to replace it")
        B.touch()
        rc, out, err = await pmd3("apps", "install", str(path), timeout=900, ok=False)
        B.touch()
        if rc != 0:
            fail(502, f"install failed: {last_error(err)}")
        B.installed[bid] = {"by": c.name, "at": time.time()}
        B.save()
        return JSONResponse({"installed": bid})
    finally:
        path.unlink(missing_ok=True)


async def h_uninstall(request):
    c = await caller_of(request)
    require_holder(c)
    bid = request.path_params["bundle_id"]
    allowed_app(c, bid, "uninstall")
    await pmd3("apps", "uninstall", bid, timeout=120)
    B.installed.pop(bid, None)
    B.save()
    return JSONResponse({"uninstalled": bid})


async def stream_proc(proc, seconds, head=b""):
    """Stream a subprocess' stdout to the client for `seconds`, then kill it."""
    B.streams.add(proc)
    deadline = time.monotonic() + seconds

    async def gen():
        try:
            if head:
                yield head
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                try:
                    chunk = await asyncio.wait_for(proc.stdout.read(65536), min(left, 15))
                except asyncio.TimeoutError:
                    B.last_activity = time.time()
                    continue
                if not chunk:
                    break
                B.last_activity = time.time()
                yield chunk
        finally:
            kill_group(proc)
            B.streams.discard(proc)

    return StreamingResponse(gen(), media_type="text/plain; charset=utf-8")


async def launch(c, bid, d):
    allowed_app(c, bid, "launch")
    args = d.get("args") or []
    envv = d.get("env") or {}
    if not isinstance(args, list) or not isinstance(envv, dict):
        fail(400, "args must be a list, env an object")
    console = float(d.get("console_seconds") or 0)
    if console > MAX_STREAM_SECONDS:
        fail(400, f"console_seconds <= {MAX_STREAM_SECONDS}")
    argv = [PYTHON, HELPER, "launch", UDID, bid]
    for a in args:
        argv += ["--arg", str(a)]
    for k, v in envv.items():
        argv += ["--env", f"{k}={v}"]
    if d.get("url"):
        argv += ["--url", str(d["url"])]
    if d.get("kill_existing") is False:
        argv.append("--no-kill-existing")
    if console > 0:
        argv += ["--console-seconds", str(console)]
        proc = await spawn(*argv, merge=True)
        skipped = b""
        while True:
            line = await asyncio.wait_for(proc.stdout.readline(), 60)
            if not line or line.startswith(b"{"):
                break
            skipped += line
        if not line:
            kill_group(proc)
            fail(502, f"launch {bid} failed: {last_error(skipped.decode(errors='replace'))}")
        return await stream_proc(proc, console + 2, head=line)
    rc, out, err = await run(*argv, timeout=60)
    if rc != 0:
        fail(502, f"launch {bid} failed: {last_error(err or out.decode(errors='replace'))}")
    return JSONResponse(json.loads(out.splitlines()[0]))


async def h_launch(request):
    c = await caller_of(request)
    require_holder(c)
    return await launch(c, request.path_params["bundle_id"], await body_json(request))


async def h_open_url(request):
    c = await caller_of(request)
    require_holder(c)
    d = await body_json(request)
    url = str(d.get("url") or "")
    if not url or "://" not in url:
        fail(400, "url required (scheme://...)")
    bid = d.get("bundle_id") or ("com.apple.mobilesafari" if url.split(":", 1)[0] in ("http", "https") else None)
    if not bid:
        fail(400, "bundle_id required for a non-http URL: the app that handles it (e.g. your dev client)")
    return await launch(c, bid, {"url": url, "kill_existing": d.get("kill_existing", True)})


async def h_terminate(request):
    c = await caller_of(request)
    require_holder(c)
    bid = request.path_params["bundle_id"]
    allowed_app(c, bid, "launch")
    # `dvt pkill --bundle` silently matches nothing for some apps on 27.2; resolve the pid instead.
    _, out, _ = await pmd3("developer", "dvt", "process-id-for-bundle-id", bid, timeout=30)
    try:
        pid = int(out.strip() or 0)
    except ValueError:
        fail(502, f"terminate {bid}: unexpected pid {out[:80]!r}")
    if pid <= 0:
        return JSONResponse({"terminated": bid, "pid": None, "was_running": False})
    await pmd3("developer", "dvt", "kill", str(pid), timeout=30)
    return JSONResponse({"terminated": bid, "pid": pid, "was_running": True})


async def h_processes(request):
    c = await caller_of(request)
    require_holder(c)
    procs = await pmd3_json("developer", "core-device", "list-processes", timeout=30)
    out = []
    for p in procs:
        url = (p.get("executableURL") or {}).get("relative", "")
        out.append({"pid": p.get("processIdentifier"), "path": url.removeprefix("file://"),
                    "name": url.rsplit("/", 1)[-1]})
    return JSONResponse(out)


async def h_kill(request):
    c = await caller_of(request)
    require_holder(c)
    pid = int(request.path_params["pid"])
    if not c.admin:
        procs = await pmd3_json("developer", "core-device", "list-processes", timeout=30)
        path = next(((p.get("executableURL") or {}).get("relative", "").removeprefix("file://")
                     for p in procs if p.get("processIdentifier") == pid), None)
        if path is None:
            fail(404, f"no process {pid}")
        apps = await pmd3_json("apps", "list", "--type", "Any", timeout=60)
        owner = next((bid for bid, a in apps.items() if a.get("Path") and path.startswith(a["Path"].rstrip("/") + "/")), None)
        if owner is None or not (owner in B.installed or owner in LAUNCH_ALLOW):
            fail(403, f"pid {pid} ({path.rsplit('/', 1)[-1]}) does not belong to a broker-installed app")
    await pmd3("developer", "dvt", "kill", str(pid), timeout=30)
    return JSONResponse({"killed": pid})


async def allowed_executables(c):
    """CFBundleExecutable of the apps the caller may inspect -> bundle id."""
    apps = await pmd3_json("apps", "list", "--type", "Any" if c.admin else "User", timeout=60)
    return {a.get("CFBundleExecutable"): bid for bid, a in apps.items()
            if a.get("CFBundleExecutable") and (c.admin or bid in B.installed or bid in LAUNCH_ALLOW)}


async def h_crashes(request):
    c = await caller_of(request)
    require_holder(c)
    process = request.query_params.get("process", "")
    limit = int(request.query_params.get("limit", "3"))
    if process not in await allowed_executables(c):
        fail(403, f"crash reports: process must be the executable of a broker-installed app (got {process!r})")
    with tempfile.TemporaryDirectory(dir=STATE_DIR) as tmp:
        await pmd3("crash", "pull", tmp, "/", "--match", rf"^{re.escape(process)}[-_.]", timeout=180)
        files = sorted((p for p in Path(tmp).rglob("*") if p.is_file()), key=lambda p: p.name, reverse=True)[:limit]
        return JSONResponse([{"name": p.name, "content": p.read_text(errors="replace")} for p in files])


async def h_syslog(request):
    c = await caller_of(request)
    require_holder(c)
    q = request.query_params
    seconds = min(float(q.get("seconds", "30")), MAX_STREAM_SECONDS)
    process = q.get("process")
    if not c.admin and (not process or (process not in SYSLOG_SYSTEM and process not in await allowed_executables(c))):
        fail(403, f"process=<name> must be the executable of a broker-installed app or one of {sorted(SYSLOG_SYSTEM)} "
                  "(the phone's other logs are off limits)")
    argv = [PMD3, "syslog", "live"]
    if process:
        argv += ["-pn", process]
    if q.get("match"):
        argv += ["-m", q["match"]]
    if q.get("format") == "json":
        argv += ["--format", "json"]
    proc = await spawn(*argv, merge=True)
    return await stream_proc(proc, seconds)


async def hid_run(*args):
    B.touch()
    async with B.hid_lock:
        await pmd3("developer", "core-device", *args, timeout=60)
    B.touch()


async def h_hid(request):
    c = await caller_of(request)
    require_holder(c)
    action = request.path_params["action"]
    d = await body_json(request)
    unit = d.get("unit", "px")
    try:
        if action == "tap":
            x, y = await to_norm(float(d["x"]), float(d["y"]), unit)
            await hid_run("universal-hid-service", "tap", str(x), str(y))
        elif action in ("swipe", "drag"):
            x1, y1 = await to_norm(float(d["x1"]), float(d["y1"]), unit)
            x2, y2 = await to_norm(float(d["x2"]), float(d["y2"]), unit)
            dur = float(d.get("duration", 0.3 if action == "swipe" else 0.6))
            steps = int(d.get("steps", max(10, int(dur * 60))))
            await hid_run("universal-hid-service", "drag", str(x1), str(y1), str(x2), str(y2),
                          "--steps", str(steps), "--duration", str(dur))
        elif action == "type":
            await hid_run("universal-hid-service", "type", str(d["text"]))
        elif action == "key":
            await hid_run("universal-hid-service", "key", str(d["key"]), "--count", str(int(d.get("count", 1))))
        elif action == "button":
            name = str(d["name"])
            if name not in ("home", "lock", "volume-up", "volume-down", "mute", "siri"):
                fail(400, "button: home|lock|volume-up|volume-down|mute|siri")
            await hid_run("hid", "button", name, str(d.get("state", "press")))
        else:
            fail(404, f"unknown HID action {action}")
    except (KeyError, ValueError) as e:
        fail(400, f"{action}: bad or missing field {e}")
    return JSONResponse({"ok": True, "action": action})


async def h_location(request):
    c = await caller_of(request)
    require_holder(c)
    if request.method == "DELETE":
        await end_location()
        return JSONResponse({"location": None})
    if B.location:
        await B.location.stop()
        B.location = None
    d = await body_json(request)
    try:
        lat, lon = float(d["lat"]), float(d["lon"])
    except (KeyError, ValueError):
        fail(400, "lat and lon required")
    sup = Supervised([PMD3, "developer", "dvt", "simulate-location", "set", "--", str(lat), str(lon)],
                     {"lat": lat, "lon": lon})
    await sup.start(stdin=True)
    await asyncio.sleep(3)
    if sup.proc.returncode is not None:
        fail(502, "simulate-location failed: " + " | ".join(ln for _, ln in list(sup.log)[-3:]))
    B.location = sup
    return JSONResponse({"location": {"lat": lat, "lon": lon}})


async def end_location():
    """Stop the simulation; with HOME_LOCATION, pass through home first (time zone)."""
    if B.location:
        await B.location.stop()
        B.location = None
    if HOME_LOCATION:
        lat, lon = HOME_LOCATION.split(",")
        home = Supervised([PMD3, "developer", "dvt", "simulate-location", "set", "--", lat.strip(), lon.strip()], {})
        await home.start(stdin=True)
        await asyncio.sleep(20)
        await home.stop()
    await pmd3("developer", "dvt", "simulate-location", "clear", timeout=30, ok=False)


async def h_forward(request):
    c = await caller_of(request)
    if request.method == "GET":
        return JSONResponse([f.json() for f in B.forwards.values()])
    require_holder(c)
    if request.method == "DELETE":
        dp = int(request.path_params["device_port"])
        for p, f in list(B.forwards.items()):
            if f.kind == "device" and f.device_port == dp:
                await f.close()
                del B.forwards[p]
                return JSONResponse({"closed": dp})
        fail(404, f"no forward for device port {dp}")
    d = await body_json(request)
    dp = int(d.get("device_port", 0))
    if not 1 <= dp <= 65535:
        fail(400, "device_port 1..65535 required")
    for f in B.forwards.values():
        if f.kind == "device" and f.device_port == dp:
            return JSONResponse(f.json())
    fwd = Forward(free_forward_port(), "device", device_port=dp)
    await fwd.start()
    B.forwards[fwd.port] = fwd
    return JSONResponse(fwd.json())


async def h_xcuitest(request):
    c = await caller_of(request)
    require_holder(c)
    if request.method == "GET":
        if not B.xcuitest:
            fail(404, "no XCUITest runner started")
        return JSONResponse(B.xcuitest.json(int(request.query_params.get("since", "0"))))
    if B.xcuitest:
        await B.xcuitest.stop()
        old, B.xcuitest = B.xcuitest, None
        if request.method == "DELETE":
            return JSONResponse(old.json(10**12))
    elif request.method == "DELETE":
        fail(404, "no XCUITest runner started")
    d = await body_json(request)
    runner = str(d.get("runner_bundle_id") or "")
    if not runner:
        fail(400, "runner_bundle_id required")
    allowed_app(c, runner, "launch")
    argv = [PMD3, "developer", "dvt", "xcuitest", runner]
    if d.get("target_bundle_id"):
        allowed_app(c, d["target_bundle_id"], "launch")
        argv += ["--target-bundle-id", str(d["target_bundle_id"])]
    for k, v in (d.get("env") or {}).items():
        argv += ["--env", f"{k}={v}"]
    if d.get("timeout"):
        argv += ["--timeout", str(float(d["timeout"]))]
    sup = Supervised(argv, {"runner_bundle_id": runner, "target_bundle_id": d.get("target_bundle_id")})
    await sup.start()
    B.xcuitest = sup
    return JSONResponse(sup.json())


async def h_live(request):
    c = await caller_of(request)
    if not (c.admin or c.name == B.holder):
        fail(403, f"live view is for the leaseholder ({B.holder}) or an admin")
    if B.holder == c.name:
        B.touch()
    existing = next((f for f in B.forwards.values() if f.kind == "live"), None)
    if request.method == "GET":
        if not (existing and B.live):
            fail(404, "no live view running")
        return JSONResponse({"url": f"http://{BIND}:{existing.port}/", "port": existing.port,
                             "server": B.live.json(int(request.query_params.get("since", "0")))})
    if request.method == "DELETE":
        if existing:
            await existing.close()
            del B.forwards[existing.port]
        return JSONResponse({"live": None})
    if existing:
        return JSONResponse({"url": f"http://{BIND}:{existing.port}/", "password": B.live_password, "port": existing.port})
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        local = s.getsockname()[1]
    B.live_password = secrets.token_urlsafe(12)
    live = Supervised([PMD3, "developer", "core-device", "display", "serve-web", "--bind", "127.0.0.1",
                       "--http-port", str(local), "--password", B.live_password, "--no-audio"], {"port": local})
    await live.start()
    for _ in range(60):
        await asyncio.sleep(0.5)
        if live.proc.returncode is not None:
            fail(502, "serve-web failed: " + last_error("\n".join(ln for _, ln in live.log)))
        try:
            _, w = await asyncio.open_connection("127.0.0.1", local)
            w.close()
            break
        except OSError:
            pass
    else:
        await live.stop()
        fail(504, "serve-web did not start within 30s")
    B.live = live
    fwd = Forward(free_forward_port(), "live", local_port=local, allow_admin=True)
    await fwd.start()
    B.forwards[fwd.port] = fwd
    return JSONResponse({"url": f"http://{BIND}:{fwd.port}/", "password": B.live_password, "port": fwd.port,
                         "note": "Safari or Chrome with HEVC WebCodecs (macOS/iOS); any user name + this password"})


async def h_sign(request):
    c = await caller_of(request)
    if not c.admin:
        require_holder(c)
    if not B.signer.available:
        fail(503, "signing is not configured on the host")
    src = await save_upload(request, ".zip")
    out = src.with_suffix(".signed.ipa")
    try:
        result = await asyncio.to_thread(B.signer.sign, src, out)
    except SignError as e:
        out.unlink(missing_ok=True)
        fail(400 if "allowed prefixes" in str(e) or "explicit" in str(e) or "archive" in str(e) or "zip" in str(e) else 502, str(e))
    finally:
        src.unlink(missing_ok=True)
    if B.holder == c.name:
        B.touch()
    return FileResponse(out, media_type="application/octet-stream", filename=result["app"].removesuffix(".app") + ".ipa",
                        headers={"X-Signed": json.dumps(result)}, background=_unlink_task(out))


def _unlink_task(path):
    from starlette.background import BackgroundTask
    return BackgroundTask(lambda: path.unlink(missing_ok=True))


async def http_error(request, exc):
    try:
        body = json.loads(exc.detail)
    except (TypeError, ValueError):
        body = {"error": exc.detail}
    return JSONResponse(body, status_code=exc.status_code)


async def any_error(request, exc):
    log.exception("unhandled %s %s", request.method, request.url.path)
    return JSONResponse({"error": f"internal error: {exc}"}, status_code=500)


routes = [
    Route("/v1/whoami", h_whoami),
    Route("/v1/status", h_status),
    Route("/v1/lease", h_lease_acquire, methods=["POST"]),
    Route("/v1/lease", h_lease_release, methods=["DELETE"]),
    Route("/v1/lease/renew", h_lease_renew, methods=["POST"]),
    Route("/v1/device/info", h_info),
    Route("/v1/device/screenshot", h_screenshot),
    Route("/v1/device/wake", h_wake, methods=["POST"]),
    Route("/v1/device/syslog", h_syslog),
    Route("/v1/device/crashes", h_crashes),
    Route("/v1/device/open-url", h_open_url, methods=["POST"]),
    Route("/v1/device/location", h_location, methods=["POST", "DELETE"]),
    Route("/v1/device/processes", h_processes),
    Route("/v1/device/processes/{pid:int}/kill", h_kill, methods=["POST"]),
    Route("/v1/apps", h_apps),
    Route("/v1/apps/install", h_install, methods=["POST"]),
    Route("/v1/apps/{bundle_id}", h_uninstall, methods=["DELETE"]),
    Route("/v1/apps/{bundle_id}/launch", h_launch, methods=["POST"]),
    Route("/v1/apps/{bundle_id}/terminate", h_terminate, methods=["POST"]),
    Route("/v1/hid/{action}", h_hid, methods=["POST"]),
    Route("/v1/forward", h_forward, methods=["GET", "POST"]),
    Route("/v1/forward/{device_port:int}", h_forward, methods=["DELETE"]),
    Route("/v1/xcuitest", h_xcuitest, methods=["GET", "POST", "DELETE"]),
    Route("/v1/live", h_live, methods=["GET", "POST", "DELETE"]),
    Route("/v1/sign", h_sign, methods=["POST"]),
]


async def main():
    global B, UDID
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    if not BIND:
        sys.exit("BROKER_BIND is not set: the host's tailnet address (see iphone-broker.env.example)")
    if not UDID:
        UDID = await discover_udid()
        log.info("iPhone %s (discovered; set IPHONE_UDID to pin it)", UDID)
    if not ADMIN_LOGINS:
        log.warning("ADMIN_LOGINS is empty: no admins")
    if not ALLOW_TAGS:
        log.warning("ALLOW_TAGS is empty: no orbs may use the broker")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(STATE_DIR / "uploads", ignore_errors=True)
    B = Broker()
    log.info("signing %s; lease holder at start: %s", "available" if B.signer.available else "NOT configured", B.holder)
    if B.holder and not B.last_activity:
        B.last_activity = time.time()
    app = Starlette(routes=routes, exception_handlers={HTTPException: http_error, Exception: any_error})
    server = uvicorn.Server(uvicorn.Config(app, host=BIND, port=PORT, proxy_headers=False, log_level="info",
                                           timeout_keep_alive=30))
    mon = asyncio.create_task(monitor())
    try:
        await server.serve()
    finally:
        mon.cancel()
        kill_group(B.keepawake)
        for sup in (B.live, B.xcuitest, B.location):
            if sup:
                await sup.stop()


if __name__ == "__main__":
    asyncio.run(main())
