# srv-mobile-host: a shared iPhone on the srv host

One physical iPhone stays plugged into the srv host's USB. Amp agents in mobile orbs
(`MOBILE_ORB_IMAGE`) use it over the tailnet through an HTTP broker. The broker gives out one
exclusive lease at a time, so one thread drives the phone at a time. Orbs run the `iphone` CLI
(`srv-orbs/mobile/modules/iphone-client`).

Why USB and not the phone's own network: on iOS 27.2, RemotePairing to the phone over the
tailnet (or Wi-Fi) fails during pairing with an SRP proof mismatch, so CoreDevice services are
unreachable that way. A USB CoreDevice tunnel works, so all device traffic goes through the
host and the broker exposes it on the tailnet.

```
orb (ORB_TAILSCALE_TAGS) ──tailnet──> SITE_HOST_TAILNET_IP:IPHONE_BROKER_PORT iphone-broker (user iphone-broker)
                                   │  pymobiledevice3 subprocesses, --tunnel <UDID>
                                   ▼
                     127.0.0.1:49151 pmd3-tunneld (root) ──USB CoreDevice tunnel (TUN)──> iPhone
                                                    usbmuxd ─┘
```

## Layout

| Path | Installed as | Purpose |
|---|---|---|
| `systemd/pmd3-tunneld.service` | `/etc/systemd/system/` | `pymobiledevice3 remote tunneld --usb --no-wifi --no-mobdev2` on `127.0.0.1:49151`. Runs as root because each tunnel is a kernel TUN interface. |
| `systemd/iphone-broker.service` | `/etc/systemd/system/` | The broker, running as system user `iphone-broker` with state in `/var/lib/iphone-broker` (0700) and a hardened sandbox. |
| `broker/iphone_broker.py` | `/opt/iphone-broker/` | HTTP API (starlette/uvicorn from the pymobiledevice3 venv), Tailscale WhoIs auth, lease, phone monitor, TCP forwards. |
| `broker/pmd3_helper.py` | `/opt/iphone-broker/` | Device calls the CLI lacks: launch with a payload URL (deep link) and console capture, and the keep-awake power assertions. |
| `broker/signer.py` | `/opt/iphone-broker/` | `/v1/sign`: App Store Connect API (cert, bundle ids, profiles) and `rcodesign`. |
| `iphone-broker.env.example` | `/etc/srv-mobile/iphone-broker.env` | Broker config template (no secrets), rendered from `site.env`. |
| `install.sh` | | Installs or updates everything above (idempotent). |

The broker runs `/opt/pymobiledevice3/bin/python` (a venv with pymobiledevice3 11.45.0 on a
system Python with TLS-PSK support, e.g. 3.14). `rcodesign` 0.29.0 lives at `/opt/rcodesign/bin`,
the same pin as the orb image.

## Setup

### 1. Prepare the phone

Use a phone dedicated to this, or accept that agents see whatever is on its screen.

- **Developer Mode** on (Settings → Privacy & Security → Developer Mode; the menu appears
  after the phone has been paired with a developer tool once, e.g. `pymobiledevice3 amfi
  reveal-developer-mode`).
- **No passcode**: the broker wakes and unlocks the phone by pressing home, and agents cannot
  type a passcode.
- **Auto-Lock: Never** (Settings → Display & Brightness). The broker also holds power
  assertions, but those are best effort.
- **Do Not Disturb / a Focus** that silences everything, so notifications and banners do not
  cover the apps under test.
- **Wi-Fi on** and the **Tailscale app** signed in to your tailnet, so development clients on the
  phone (e.g. the Expo dev client) can reach Metro/dev servers inside an orb.
- Automatic iOS updates off, so the OS version does not change under the tooling.
- Plugged in permanently (it charges over the same cable).

### 2. Pair over USB and mount the DDI

On the host, with the phone plugged in and unlocked:

```bash
sudo systemctl enable --now usbmuxd   # often socket/udev-activated already
idevicepair pair                       # tap "Trust" on the phone; record lands in /var/lib/lockdown
/opt/pymobiledevice3/bin/pymobiledevice3 mounter auto-mount
```

`mounter auto-mount` downloads the personalized Developer Disk Image (cryptex) into
`~/.local/share/pymobiledevice3/Xcode_iOS_DDI_Cryptex`; `install.sh` copies that cache to the
broker's home so re-mounts need no download.

### 3. Signing (optional): App Store Connect API key

`/v1/sign` makes development builds for this one phone through the App Store Connect API.

1. Register the phone's UDID as a device of your team (developer.apple.com → Devices). The
   broker only uses ENABLED devices; it does not register them.
2. Create an API key (App Store Connect → Users and Access → Integrations → App Store Connect API)
   with access to certificates, identifiers and profiles (role Admin). Download the `.p8` once.
3. Put it on the host, readable by root only:

   ```bash
   sudo install -d -m 0700 /etc/srv-mobile/asc
   sudo install -m 0600 AuthKey_ABC123XYZ9.p8 /etc/srv-mobile/asc/
   sudo install -m 0600 /dev/stdin /etc/srv-mobile/asc.env <<'EOF'
   ASC_KEY_ID=ABC123XYZ9
   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
   ASC_KEY_PATH=/etc/srv-mobile/asc/AuthKey_ABC123XYZ9.p8
   EOF
   ```

`install.sh` turns these into systemd credentials for the broker (see below). Without
`asc.env`, everything except `/v1/sign` works.

### 4. Configure and install

Set these in the repo's `site.env` (see `site.env.example`):

| site.env | Broker setting | Meaning |
|---|---|---|
| `SITE_HOST_TAILNET_IP` | `BROKER_BIND` | Required. The host's tailnet address; the API and forwards listen only there. |
| `IPHONE_BROKER_PORT` | `BROKER_PORT` | API port (default 8787). |
| `IPHONE_BROKER_FORWARD_PORTS` | `FORWARD_PORTS` | Port range for leaseholder TCP forwards and the live view (default 8790-8799). |
| `ORB_TAILSCALE_TAGS` | `ALLOW_TAGS` | Tags whose nodes get role `orb`. |
| `SITE_ADMIN_LOGINS` | `ADMIN_LOGINS` | Tailscale logins whose untagged devices get role `admin`. |
| `APPLE_BUNDLE_PREFIX` | `BUNDLE_PREFIXES` | Bundle id prefix (with trailing dot) that non-admins may install and anyone may sign. |
| `IPHONE_LEASE_IDLE_SECONDS` | `IDLE_TIMEOUT` | Lease auto-release after this many idle seconds (default 600). |
| `IPHONE_HOME_LOCATION` | `HOME_LOCATION` | `lat,lon` near the phone's real location; see Location below. Empty: plain clear. |
| `MOBILE_CACHE_DIR` | | Download cache for `rcodesign` (default `/var/cache/srv-mobile`). |

Empty lists in the broker's env grant nothing: no `ALLOW_TAGS` means no orbs, no `ADMIN_LOGINS`
means no admins, no `BUNDLE_PREFIXES` means nothing can be installed by non-admins or signed.
The broker refuses to start without `BROKER_BIND`.

```bash
./install.sh --print-env     # preview /etc/srv-mobile/iphone-broker.env
sudo ./install.sh
```

The script:

- installs rcodesign;
- creates the `iphone-broker` user;
- copies the DDI cache from the invoking admin's (or root's) pymobiledevice3 directory into
  `/var/lib/iphone-broker/.local/share/pymobiledevice3/`;
- copies the code to `/opt/iphone-broker`;
- renders `/etc/srv-mobile/iphone-broker.env` from `iphone-broker.env.example` and `site.env` if
  it does not exist yet. An existing file is kept, so local edits (`TEST_NODES`, `IPHONE_UDID`)
  survive; `sudo ./install.sh --render-env` rewrites it and keeps the old one as `.bak-<time>`;
- installs the units and writes the credentials drop-in;
- enables and starts both services, and restarts the broker.

**Which phone:** with `IPHONE_UDID` empty, the broker uses the one iPhone that pmd3-tunneld has a
tunnel to (or, failing that, the one usbmuxd sees on USB) and logs its UDID. With none it exits
and systemd retries; with several it exits asking for `IPHONE_UDID`. Set `IPHONE_UDID=<udid>` in
`/etc/srv-mobile/iphone-broker.env` to pin a phone (`idevicepair list` shows it).

### What the broker user gets, and why

| Need | How |
|---|---|
| Device access | The tunneld API on `127.0.0.1:49151` and the TUN route to the device. Every device command runs with `--tunnel <UDID>`. Lockdown services go over the RSD tunnel, so the broker needs **no pairing record** of its own: `/var/lib/lockdown` and the admin's `~/.local/share/pymobiledevice3` stay private. |
| usbmuxd | `/var/run/usbmuxd` is mode 0666. tunneld uses it; the broker only lists devices there to find the UDID. |
| Caller identity | `/run/tailscale/tailscaled.sock` (0666). The local API's `whois` endpoint is allowed for any local user. |
| DDI | A copy of the cryptex cache in its home. `mounter auto-mount` personalizes it against Apple's TSS (needs internet). |
| ASC key (signing) | systemd credentials. `install.sh` reads `ASC_KEY_PATH` from `/etc/srv-mobile/asc.env` and writes `/etc/systemd/system/iphone-broker.service.d/asc-credentials.conf` with `LoadCredential=asc.env:/etc/srv-mobile/asc.env` and `LoadCredential=asc.p8:<key>`. systemd, as root, copies both files into the service's private `$CREDENTIALS_DIRECTORY`. The originals stay root 0600, and no other process or user can read the copies. |
| Signing state | `/var/lib/iphone-broker/signing/`: `key.pem` (0600), `cert.der` and `certificate-id` of the broker's own *iOS Development* certificate ("srv-mobile iphone-broker"), and `profiles/<bundle id>.mobileprovision`. |

## Policy

- **Callers.** The broker sees the TCP peer's tailnet address and asks tailscaled's `WhoIs` who it is.
  - Nodes with a tag in `ALLOW_TAGS` (the orbs' `ORB_TAILSCALE_TAGS`) get role `orb`.
  - Untagged devices of `ADMIN_LOGINS` (`SITE_ADMIN_LOGINS`, which can include the host itself) get role `admin`.
  - Nodes named in `TEST_NODES` get role `test`. mobile-test VMs are tagged nodes without the orb tag, so tests list the VMs' node names there; empty this list after testing.
  - Anyone else gets 403. Nothing else can reach the port anyway: it is bound to the tailnet address only, and a host firewall should drop LAN traffic to it.
- **Lease.** The holder is a tailnet node name. Every device endpoint requires the caller to hold the lease (409 otherwise, with `holder`).
  - Acquiring is idempotent for the holder.
  - Any authorized call, streamed console/syslog output, or forwarded traffic counts as activity. After `IDLE_TIMEOUT` seconds with no activity, the lease is released.
  - Releasing closes the holder's forwards, live view, XCUITest runner, location simulation and running streams.
  - An admin can force-release (`DELETE /v1/lease?force=1`). Admins also need the lease for device operations.
  - Signing (`/v1/sign`) needs the lease, except for admins.
- **The rest of the phone is off limits.** The phone may be someone's personal phone, so non-admins are fenced in:
  - Install only bundle ids under `BUNDLE_PREFIXES`, and never over an app that is already on the phone but was not installed by the broker.
  - Uninstall, terminate, kill, XCUITest, crash reports and syslog only for apps installed through the broker. `LAUNCH_ALLOW` (Settings, Safari) may also be launched and terminated. Syslog may also read SpringBoard/installd/runningboardd/testmanagerd/amfid/kernel.
  - The broker remembers what it installed in `/var/lib/iphone-broker/state.json`, together with the lease.
  - Screenshots and the live view show whatever is on screen.
- **Signing.** Development signing for the wired iPhone only:
  - `IOS_APP_DEVELOPMENT` profiles named `srv-mobile dev <bundle id>`, holding the broker's certificate and this one device. They are cached and remade 7 days before they expire.
  - Explicit bundle ids under `BUNDLE_PREFIXES` only. Wildcards, and any App Store or ad-hoc distribution, are refused.
  - App IDs are registered on demand.
- **Location.** A simulated location lasts until `DELETE /v1/device/location` or the end of the lease.
  Ending it simulates `HOME_LOCATION` for 20 s first, then clears. Without that, the phone keeps
  the simulated place's time zone after the clear.
- **Phone upkeep** (monitor, every 30 s):
  - Tracks tunnel presence, so a reboot or replug shows up as connected `false` and then `true`.
  - Mounts the DDI whenever it is unmounted, for example after a reboot.
  - Reads the battery every 2 min.
  - Holds `PreventUserIdleDisplaySleep` + `PreventUserIdleSystemSleep` power assertions through a helper that it restarts every 15 min.
  - Checks the screen every 3 min while nobody has driven the phone for a minute. A fully black screenshot means "off". If the screen is off and **no one holds the lease**, the monitor presses home twice: wake, then unlock (no passcode). Under a lease it only reports `screen.state`, and the holder runs `iphone wake`.

## API

Base `http://<SITE_HOST_TAILNET_IP>:<IPHONE_BROKER_PORT>` (or the host's MagicDNS name), e.g. `http://100.64.0.10:8787`. JSON in and out. Errors look like
`{"error": "...", "holder"?: "..."}` with status 400 (bad request), 401/403 (caller not allowed),
404, 409 (lease), 413, 502 (device command failed; the message is pymobiledevice3's last error
line), 503 (phone or tunnel missing, or signing not configured). "L" = needs the lease.

| Method and path | L | Body / query | Response |
|---|---|---|---|
| `GET /v1/whoami` | | | `{node, role, login, ip, holder}` |
| `GET /v1/status` | | | `{lease: {holder, holder_role, since, last_activity, idle_seconds, idle_timeout, expires_in}, phone: {connected, udid, name, ios, build, product_type, model, ddi_mounted, battery: {percent, charging, external_power}, screen: {state: on/off/unknown, checked_at}, tunnel}, forwards: [...], xcuitest, signing: {available, bundle_prefixes}}` |
| `POST /v1/lease` | | | `{lease, phone}`; 409 if someone else holds it |
| `POST /v1/lease/renew` | holder | | `{lease}` |
| `DELETE /v1/lease[?force=1]` | holder (force: admin) | | `{released, lease}` |
| `GET /v1/device/info` | L | | lockdown subset (`DeviceName, ProductType, ProductVersion, BuildVersion, UniqueDeviceID, …`), `display {width_px, height_px, scale, width_pt, height_pt}`, battery, DDI, screen |
| `GET /v1/device/screenshot` | L | `?format=png\|jpeg&scale=0.05..1` | image (full size: 1179×2556 PNG) |
| `POST /v1/device/wake` | L | | `{screen_before, screen}` |
| `POST /v1/hid/tap` | L | `{x, y, unit: px\|pt\|norm}` | `{ok}`. `px` = screenshot pixels (default), `pt` = points, `norm` = 0..65535 |
| `POST /v1/hid/swipe` (= `drag`) | L | `{x1, y1, x2, y2, duration=0.3, steps?, unit}` | finger contact drag |
| `POST /v1/hid/type` | L | `{text}` | virtual keyboard; `\n` = Return, `\t` = Tab |
| `POST /v1/hid/key` | L | `{key: backspace\|enter\|escape\|tab\|left\|right\|up\|down, count}` | |
| `POST /v1/hid/button` | L | `{name: home\|lock\|volume-up\|volume-down\|mute\|siri, state=press}` | |
| `GET /v1/apps[?all=1]` | L | | `[{bundle_id, name, version, build, type, path, installed_by_broker}]` (user apps; `all`: system apps too) |
| `POST /v1/apps/install` | L | raw `.ipa` (`application/octet-stream`, ≤ 4 GiB) | `{installed: bundle_id}` |
| `DELETE /v1/apps/{bundle_id}` | L | | `{uninstalled}` |
| `POST /v1/apps/{bundle_id}/launch` | L | `{args: [], env: {}, url?, kill_existing=true, console_seconds?}` | `{pid, bundle_id, url}`; with `console_seconds`, `text/plain` stream: that JSON line, then the app's stdout/stderr |
| `POST /v1/apps/{bundle_id}/terminate` | L | | `{terminated, pid, was_running}` |
| `POST /v1/device/open-url` | L | `{url, bundle_id?}` | launches `bundle_id` (default Safari for http/https) with the URL as CoreDevice payload URL |
| `GET /v1/device/syslog` | L | `?process=<exe>&seconds=30&match=&format=text\|json` | `text/plain` stream for ≤ 600 s |
| `GET /v1/device/crashes` | L | `?process=<exe>&limit=3` | `[{name, content}]` newest first |
| `GET /v1/device/processes` | L | | `[{pid, name, path}]` |
| `POST /v1/device/processes/{pid}/kill` | L | | `{killed}` |
| `POST/DELETE /v1/device/location` | L | `{lat, lon}` | DVT location simulation, held until DELETE or lease end |
| `POST /v1/forward` | L | `{device_port}` | `{host, port, kind, device_port, connections}`. A listener on `BROKER_BIND:<FORWARD_PORTS>` that accepts only the leaseholder's node and pipes to `[tunnel address]:device_port` on the phone (WDA/runner 8100, debugserver, app servers) |
| `GET /v1/forward` / `DELETE /v1/forward/{device_port}` | – / L | | |
| `POST /v1/xcuitest` | L | `{runner_bundle_id, target_bundle_id?, env: {}, timeout?}` | starts `developer dvt xcuitest` (testmanagerd over the tunnel); `{state, returncode, log_seq, log}` |
| `GET /v1/xcuitest?since=N` / `DELETE /v1/xcuitest` | L | | log lines after `N`; stop |
| `POST /v1/live` / `GET /v1/live?since=N` / `DELETE /v1/live` | holder or admin | | `{url, password, port}`: `core-device display serve-web` on loopback, exposed on a forward port to the holder and admins (HTTP basic auth, any user name). `GET` adds the server's log. |
| `POST /v1/sign` | L (admins exempt) | zip of `X.app` (or `Payload/X.app`, i.e. an `.ipa`) | signed `.ipa`; header `X-Signed: {bundle_ids: [{bundle_id, path, profile_expires}], team, app}` |

How signing works: each `.app`/`.appex` with a bundle id gets its development profile
embedded, and the profile's entitlements are applied to it, scoped by path. Then one
`rcodesign sign` call signs everything inside out: frameworks, dylibs and `.xctest`
bundles get the certificate only.

## Operations

```bash
systemctl status pmd3-tunneld iphone-broker
journalctl -u iphone-broker -f
curl -s http://100.64.0.10:8787/v1/status | jq .   # your BROKER_BIND:BROKER_PORT
iphone lease release --force         # from an admin device with the orb CLI, or:
curl -X DELETE 'http://100.64.0.10:8787/v1/lease?force=1'   # from the host (if it is an admin device)
```

- **Phone rebooted or replugged:** tunneld recreates the tunnel, and the monitor re-mounts the DDI
  within a minute.
- **Screen black under a lease:** the holder runs `iphone wake`.
- **New iOS version:** if the cached cryptex no longer fits, run `mounter auto-mount` and then
  `sudo ./install.sh` to recopy it. pymobiledevice3 also downloads it on its own.
- **Test allowlist:** `TEST_NODES` in `/etc/srv-mobile/iphone-broker.env`, then
  `systemctl restart iphone-broker`. A restart keeps the lease (`state.json`) but drops forwards and runners.

## What works on iOS 27.2 over USB (iPhone15,4, pymobiledevice3 11.45.0)

Measured through the broker from mobile-test VMs, with an iPhone 14 (iPhone15,4) on iOS 27.2.

| Feature | Status |
|---|---|
| tunneld USB tunnel, RSD services, lockdown over RSD (no pairing record for the broker) | works |
| DDI (cryptex) mount, `mounter list` | works |
| Screenshot: `dvt screenshot` (about 1.6 s) and `core-device screen-capture` | works |
| App list / install / uninstall (installation_proxy over RSD) | works. The Expo Release app, built by expo-ios on Linux and signed by `/v1/sign`, installed in 26 s and runs. |
| Launch with args/env (`core-device launchapplication`), console capture (OpenStdioSocket) | works |
| Deep link / open URL: launch option `payloadURL = {"relative": url}` (what `devicectl --payload-url` sends) | works. Safari opened an https URL; `pbtest://explore` opened the expo-router Explore route. |
| Terminate | `dvt pkill --bundle` silently matches nothing for an installed app. The broker uses `dvt process-id-for-bundle-id` + `dvt kill` instead, which works. |
| Process list (`core-device list-processes`), `dvt kill` | works |
| HID: `universal-hid-service tap`/`drag`/`type`/`key`, `hid button home/lock` | works. A tap opened a Settings row, a left-edge drag went back, typing filled Settings search, a tap switched an Expo app tab, and home/lock work. One tap on a row partly under Settings' floating search bar did nothing. |
| `universal-hid-service swipe` | pointer motion without contact, so it does not scroll; the broker's swipe uses `drag` |
| `core-device get-lockstate` | **not implemented** on 27.2 ("Action … getlockstate is not implemented") |
| `get-display-info` `backlightState` | stays `activeOn` while the screen is off, so it cannot report screen state; the broker checks for a black screenshot instead |
| Wake from screen off | `hid button home` twice: lock screen, then home screen (no passcode) |
| Power assertions (assertion_agent) | accepted (best effort; Auto-Lock is Never anyway) |
| Syslog (`syslog live -pn`), battery (diagnostics), crash report pull | works |
| Location (`dvt simulate-location set` / `clear`) | works. The phone's time zone followed the simulated place and stayed there after `clear`, hence `HOME_LOCATION`. |
| Live view `display serve-web` | works over USB. HEVC (`hev1.1.6.L150.B0`) reaches `/stream.bin` 10–45 s after start, then about 0.3–0.5 MB/s. Audio decoding fails (AAC-ELD needs macOS) and is off. Viewing needs HEVC WebCodecs (Safari, or Chrome on macOS/iOS). HID calls from the API open their own media stream and can stall a running live view; restart it with `iphone live --stop; iphone live`. |
| TCP forward to a device port at the tunnel address | works: agent-device's runner on the phone answered through `/v1/forward` from an orb |
| XCUITest runner (`dvt xcuitest`) | works: agent-device's XCUITest runner, signed by `/v1/sign`, started and served `snapshot`/`press`. pymobiledevice3 logs NSError objects without their fields (`<NSError object at 0x…>`). |
| Over-tailnet RemotePairing directly to the phone | **fails** on 27.2 (SRP proof mismatch), so it is not used |
