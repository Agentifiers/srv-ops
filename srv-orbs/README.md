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
| `../common/install-google-chrome.sh` | Run by both image builds; installs Google Chrome stable from Google's Debian repository after checking its SHA256. |
| `agents/` | `/home/user/.config/agents/` (owned by `user`): pstack's generated skills, its Amp adapter `pstack/amp.md`, and `pstack/sync.ts` to regenerate them. |
| `install.sh` | `render [DIR]` writes, `install` installs the providers' host files below (and the mobile provider's, see `mobile/README.md`), rendered from `site.env`. Existing env files keep their `AMP_ORB_PROVIDER_TOKEN` line. Nothing is enabled or restarted. |
| `srv-orbs.env.example` | Template for `/etc/srv-orbs.env` (root, 0600): `SRV_HOST`, `ORB_IMAGE` and the per-orb shape `ORB_CPUS` / `ORB_RAM` / `ORB_DISK`. Add `AMP_ORB_PROVIDER_TOKEN` by hand. |
| `systemd/srv-orbs.service.d-coredump.conf` | `/etc/systemd/system/srv-orbs.service.d/coredump.conf`. The unit itself is upstream's `contrib/amp/orbs/srv-orbs.service`, which `install.sh` copies from `SRV_SRC_DIR`. |

The drop-in is needed because upstream's unit won't start when crash dumps are
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
sudo ./install.sh install    # unit, drop-in and /etc/srv-orbs.env; then add AMP_ORB_PROVIDER_TOKEN
```

- **Amp CLI:** installed for user `srv-orbs` (`/var/lib/srv-orbs/.amp`) and
  symlinked as `/usr/local/bin/amp`, so the CLI can update itself.
- **srv access:** `srv-orbs` reaches srv (`SRV_HOST`) as the host's Tailscale
  identity. Its `known_hosts` contains srv's host key.
- **State:** dispatcher state lives in `/var/lib/srv-orbs/dispatch`. Back it up
  together with srv's state. Never hand-edit it.

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

- **ufw allows the Amp CONNECT gateway** (`$SRV_VM_NETWORK_CIDR →
  $SRV_VM_NETWORK_CIDR tcp/$SRV_AMP_CONNECT_GATEWAY_PORT`, default
  `172.28.0.0/16`, port 3128) and routed VM egress. Without the gateway rule,
  `amp orb bootstrap` times out and the orb never connects.
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
