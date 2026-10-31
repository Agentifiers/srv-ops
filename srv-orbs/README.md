# srv-orbs: Amp self-hosted orbs on srv

This uses upstream srv's native orb support, documented in
`docs/examples/amp-orbs.md` of the srv checkout (`$SRV_SRC_DIR` in `site.env`):

- **Dispatcher:** `srv-orb-dispatch`.
- **Bootstrap:** the provider passes Amp's token to the guest over a host-only
  vsock channel, not guest SSH.
- **Snapshots:** project snapshots are supported.

The main addition is **Tailscale in every orb**. Without it, phones and
other tailnet devices couldn't reach dev servers directly. Each orb joins as a
temporary node tagged `ORB_TAILSCALE_TAGS` (default `tag:amp-orb`) named
`amp-<thread-id>`, using Amp's workload identity
([Amp docs](https://ampcode.com/docs/orbs/customizing#use-tailscale)).
No Tailscale key lives on the host or in the image.

All settings named below are variables in the repo's `site.env` (copy
`site.env.example`); the scripts read it through `common/site-env.sh`.

The image also adds Google Chrome stable as `google-chrome`, which Amp's
Desktop launches (Arch only packages Chromium), and `xvfb-run` for headed
browser tests outside the Desktop. `chromium` and `chromedriver` come from the
base, as does `agent-browser`; the build copies its skill to
`/home/user/.config/agents/skills/` (the base installs it for root only, but
Amp runs as `user`) and fails if `agent-browser doctor` cannot launch Chrome.

Every orb also gets [pstack](agents/pstack/README.md) (MIT, Lauren Tan) as
user skills in `~/.config/agents/skills/pstack`, so no repository needs to
vendor it.

```
Amp ──jobs──> amp orb provider (srv-orbs.service, user srv-orbs)
                └─ srv-orb-dispatch ──ssh $SRV_HOST orb new/start/stop/delete-proof──> srv
                                     └─ vsock bootstrap ──> guest: amp orb bootstrap
guest boot ──> amp-orb-tailscale.service: amp orb id-token → tailscale up (ephemeral, $ORB_TAILSCALE_TAGS, --ssh)
```

## Files

| Repo | Installed to |
|---|---|
| `build-image.sh` | Layer build. It turns `$SRV_IMAGES_DIR/$ORB_IMAGE-base` into `$SRV_IMAGES_DIR/$ORB_IMAGE` (`ORB_IMAGE` defaults to `amp-orb`). |
| `guest/amp-orb-tailscale{,.service}`, `guest/tailscaled-mem-state.conf` | Baked into the image by `build-image.sh`. |
| `guest/amp-orb-tailscale.env.example` | Template for `/etc/amp-orb-tailscale.env` in the image; `build-image.sh` renders it from `site.env` (`AMP_WORKSPACE_ID`, `ORB_TAILSCALE_*`). |
| `guest/agent-desktop`, `guest/agent-desktop-orb.md` | `/usr/local/bin/agent-desktop` (runs the CLI from `/opt/agent-desktop` inside the Desktop session) and the orb section appended to the `agent-desktop` skill. See [Desktop and computer use](#desktop-and-computer-use). |
| `guest/labwc-{environment,autostart}`, `guest/amp-desktop-accessibility.conf` | `/etc/xdg/labwc/{environment,autostart}` and `/etc/systemd/system/run-.service.d/amp-desktop-accessibility.conf`: accessibility for the Desktop session and the apps Amp launches in it. |
| `../common/install-google-chrome.sh` | Run by both image builds; installs Google Chrome stable from Google's Debian repository after checking its SHA256. |
| `agents/` | `/home/user/.config/agents/` (owned by `user`): pstack's generated skills, its Amp adapter `pstack/amp.md`, and `pstack/sync.ts` to regenerate them. |
| `install.sh` | `render [DIR]` writes, `install` installs the providers' host files below (and the mobile provider's, see `mobile/README.md`), rendered from `site.env`. Existing env files keep their `AMP_ORB_PROVIDER_TOKEN` line. Nothing is enabled or restarted. |
| `srv-orbs.env.example` | Template for `/etc/srv-orbs.env` (root, 0600): `SRV_HOST`, `ORB_IMAGE`, the per-orb shape `ORB_CPUS` / `ORB_RAM` / `ORB_DISK` and `ORB_KEEPALIVE_HOURS`. Add `AMP_ORB_PROVIDER_TOKEN` by hand. |
| `systemd/srv-orbs.service.d-coredump.conf` | `/etc/systemd/system/srv-orbs.service.d/coredump.conf`. The unit itself is upstream's `contrib/amp/orbs/srv-orbs.service`, which `install.sh` copies from `SRV_SRC_DIR`. |
| `systemd/srv-orbs.service.d-keepalive.conf` | `/etc/systemd/system/srv-orbs.service.d/keepalive.conf`: dispatch through `srv-orb-keepalive` (see [Keep-alive](#keep-alive)). |
| `keepalive/srv-orb-keepalive` | `/usr/local/bin/srv-orb-keepalive`, the dispatch program of both providers. |
| `keepalive/srv-orb-keepalive-reap@.{service,timer}` | `/etc/systemd/system/`; enable one per provider: `srv-orb-keepalive-reap@srv-orbs.timer`, `srv-orb-keepalive-reap@srv-orbs-mobile.timer`. |

The coredump drop-in is needed because upstream's unit won't start when crash dumps are
piped to a collector, such as `systemd-coredump`. The
unit's `LimitCORE=0` still applies.

## Build

Set `SRV_SRC_DIR`, `AMP_WORKSPACE_ID` and `ORB_TAILSCALE_*` in `site.env` (see
[Tailscale](#tailscale)); `SRV_IMAGES_DIR` and `ORB_IMAGE` choose where the
image goes.

```sh
# Upstream orb base. It shares the same vsock kernel config as arch-base.
sudo SRV_AMP_ORB=1 OUTPUT_DIR="$SRV_IMAGES_DIR/$ORB_IMAGE-base" \
  WORK_DIR="$SRV_IMAGES_DIR"/arch-base/work "$SRV_SRC_DIR"/images/arch-base/build.sh
sudo ./build-image.sh
```

`/etc/srv/images.json` (render it with `host/render.sh images.json`) maps
`$ORB_IMAGE` to `$ORB_IMAGE-base/vmlinux` and `$ORB_IMAGE/rootfs-base.img`.
srv refuses to clone a base image that is still attached to a loop device, so
unmount any inspection mounts before orbs spawn.

## Provider

```sh
go build -o /tmp/srv-orb-dispatch "$SRV_SRC_DIR"/cmd/srv-orb-dispatch
sudo install -m 0755 /tmp/srv-orb-dispatch /usr/local/bin/
sudo ./install.sh install    # units, drop-ins, keep-alive and /etc/srv-orbs.env; then add AMP_ORB_PROVIDER_TOKEN
sudo systemctl enable --now srv-orb-keepalive-reap@srv-orbs.timer srv-orb-keepalive-reap@srv-orbs-mobile.timer
```

- **Amp CLI:** installed for user `srv-orbs` (`/var/lib/srv-orbs/.amp`) and
  symlinked as `/usr/local/bin/amp`, so the CLI can update itself.
- **srv access:** `srv-orbs` reaches srv (`SRV_HOST`) as the host's Tailscale
  identity. Its `known_hosts` contains srv's host key.
- **State:** dispatcher state lives in `/var/lib/srv-orbs/dispatch`. Back it up
  together with srv's state. Never hand-edit it.

## Keep-alive

Amp pauses an orb after a few minutes without thread activity, even while a
background command is still running, and upstream's `srv-orb-dispatch` answers
a pause by stopping the microVM: terminals, dev servers, containers and
anything else in memory are gone, and the next message cold-boots the orb.

Both providers therefore dispatch through `srv-orb-keepalive`:

- **Pause** (without a project snapshot) only records the time in
  `$SRV_ORB_STATE_DIR-keepalive/` and leaves the VM running.
- **Spawn** clears that record and runs `srv-orb-dispatch`, which finds the VM
  running and restarts only Amp's bootstrap with the new token.
- **Delete** and **snapshot pauses** go straight to `srv-orb-dispatch`
  (a snapshot needs a stopped source).
- **Reap:** every 10 minutes `srv-orb-keepalive-reap@<provider>.timer` really
  pauses (stops) orbs whose last pause is `ORB_KEEPALIVE_HOURS` old
  (`SRV_ORB_KEEPALIVE_HOURS` in the provider env, default 24; `0` disables
  keep-alive). `srv-orb-keepalive status` lists kept-alive orbs.

Kept-alive orbs hold their full RAM (`ORB_RAM`, `MOBILE_ORB_RAM`) until reaped
or deleted; size `ORB_KEEPALIVE_HOURS` to the host.

Every idle stretch of a few minutes makes Amp send another pause, which
restarts the clock. The host cannot see thread activity itself (CPU and
network of an orb waiting on the model look idle), so a thread that works
without any such gap for `ORB_KEEPALIVE_HOURS` after its last pause is still
stopped by the reaper.

Amp's headless agent runs inside `srv-orb-bootstrap.service`. While the VM
keeps running, Amp usually wakes a paused thread through that still-connected
agent without sending a spawn, so its shells and background commands survive
too. A spawn makes the guest agent restart the unit
(`KillMode=control-group`), which ends the agent's shells and anything they
started directly (including a tmux server); other systemd units, `sudo
systemd-run` jobs, Docker containers (redroid), Amp services
(`.amp/services.yaml`), `/tmp` and the orb's tailnet node and IP survive even
that.

## Desktop and computer use

Every thread's orb has Amp's Desktop (the thread's **Desktop** tab): srv's orb
base bakes Amp's Wayland stack (`/opt/amp-wayland`: labwc 0.9.8 and waymote),
and Amp installs `/opt/amp-desktop` and `amp-desktop.service` the first time
the tab opens.

Agents operate it with [agent-desktop](https://github.com/vercel-labs/agent-desktop)
from the [Agentifiers fork](https://github.com/Agentifiers/agent-desktop), whose
Linux backend adds a wlroots route (virtual keyboard and pointer, screencopy,
foreign-toplevel). `build-image.sh` installs a pinned release
(`AGENT_DESKTOP_VERSION`, archive and skill checked by SHA-256) and the skill,
with an orb section from `guest/agent-desktop-orb.md`.

- **Session environment:** Amp's agent shell is outside the Desktop session.
  `/usr/local/bin/agent-desktop` loads `~/.cache/amp/desktop/environment` and
  the session's D-Bus address (read from labwc), so `agent-desktop ...` works
  from any shell while the Desktop is running.
- **Accessibility on:** at-spi2-core 2.62 starts the accessibility bus
  disabled and ignores any default. labwc's system `autostart` (Amp writes only
  `~/.config/labwc/rc.xml`) enables it, links the bus socket to
  `$XDG_RUNTIME_DIR/at-spi-bus` and publishes `AT_SPI_BUS` for Xwayland apps.
  labwc's `environment` sets `ACCESSIBILITY_ENABLED=1` and
  `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` for apps it starts.
- **Apps Amp launches** (`/opt/amp-desktop/launch-app`, including the
  Desktop's Chrome) run as transient `systemd-run` units with a fixed
  environment and no session bus. The `run-.service.d` prefix drop-in gives
  every transient unit those two variables plus `AT_SPI_BUS_ADDRESS` pointing
  at the linked socket.
- **Web pages** stay with agent-browser over the Desktop Chrome's DevTools
  port (`127.0.0.1:9222`); agent-desktop is for native apps and window control.

## Tailscale

- **Tag:** add the tags in `ORB_TAILSCALE_TAGS` (default `tag:amp-orb`) to
  the tailnet policy, owned by e.g. `autogroup:admin`. To shell into orbs, add an
  SSH rule from your admin login(s) (`SITE_ADMIN_LOGINS`) to that tag as root, for example
  `{"action": "accept", "src": ["you@example.com"], "dst": ["tag:amp-orb"], "users": ["root"]}`.
- **Trust credential:** create an OIDC trust credential (workload identity
  federation) in the Tailscale admin console:
  - Issuer: `https://ampcode.com/api/workload-identity`.
  - Subject: `workspace:<your Amp workspace id>`.
  - Claims: `workspace_id` and `token_use=exchanged`.
  - Scope: `auth_keys` with the tags in `ORB_TAILSCALE_TAGS`.
  - Put the workspace id in `AMP_WORKSPACE_ID` and the credential's client ID
    and audience in `ORB_TAILSCALE_CLIENT_ID` / `ORB_TAILSCALE_AUDIENCE` in
    `site.env`. They are identifiers, not secrets; `build-image.sh` bakes them
    into `/etc/amp-orb-tailscale.env`.
- **Wakes:** tailscaled keeps node state in memory, so each wake joins as a
  fresh temporary node with a new IP but the same name.
- **SSH host keys:** these live in `/var/lib/tailscale`. srv's snapshot
  sanitizer removes that directory.

Reach a dev server from a tailnet device at `http://amp-<thread-id>:<port>`.
Shell in with `ssh root@amp-<thread-id>`.

## Host requirements this depends on

- **ufw allows the Amp CONNECT gateway** (tcp/`$SRV_AMP_CONNECT_GATEWAY_PORT`,
  default 3128, in on `tap+`) and routed VM egress; see the top-level README
  for the rules. Without the gateway rule, `amp orb bootstrap` times out and
  the orb never connects.
- **A short `SRV_JAILER_BASE_DIR`** (default `/srv/jail`, set in srv's
  `srv.env`). Dispatcher VM names are 60 characters, and under srv's default
  `/var/lib/srv/jailer` the Firecracker API socket path (114 bytes) is longer
  than the 108-byte Unix socket limit. Launch then times out and srv
  quarantines it until the host reboots.

## Known limits

- **Uncertain creates stay fenced.** If `orb new` fails, the dispatcher treats
  the outcome as unknown (upstream design). The thread's orb ID stays fenced:
  delete that thread and start a new one.
- **Joining takes a few seconds.** The node comes up after `amp orb bootstrap`
  connects, about 10 s after boot. A command the agent runs immediately on
  wake can still see `Logged out`.
- **connmark warning.** The orb kernel lacks netfilter connmark, so
  `tailscale status` shows a health warning. It only matters for exit-node or
  subnet-route setups.
