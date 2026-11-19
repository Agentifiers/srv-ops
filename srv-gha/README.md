# srv-gha: ephemeral GitHub Actions runners on srv

Each GitHub Actions job runs in its own srv Firecracker microVM. GARM gets a
`workflow_job` webhook, asks `garm-provider-srv` for a VM, and the runner
registers with GitHub using JIT config. When the job finishes, the VM is
deleted. The VMs are completely separate from the Amp orb setup in
`../srv-orbs`. They use a different image, a different Tailscale tag
(`$SITE_TAG_GHA`, default `tag:gha`, srv's default guest tag), and a separate set of VM names (`gha-*`).

```
GitHub ──webhook──> relay (host/relay) /webhooks ──tailnet──> garm on winstons-mac-mini (GARM_IP:GARM_API)
                                               │ GARM_COMMAND=CreateInstance
                                               v
                               garm-provider-srv ──ssh SRV_FRONT_HOST new gha-… --image GHA_RUNNER_IMAGE (srv-front places it)
                                               │ Tailscale SSH root@gha-…: runner install script
                                               v
                       runner VM (SITE_TAG_GHA) ──> metadata/callback GARM_IP:GARM_API, bazel-remote HOST_IP:GRPC
```

Uppercase names refer to `site.env` settings (`GARM_WEBHOOK_BASE_URL`,
`GARM_TAILNET_IP`, `SITE_HOST_TAILNET_IP`, `GARM_API_PORT`, `BAZEL_REMOTE_GRPC_PORT`, ...).
GARM runs on winstons-mac-mini; bazel-remote, the image builder and garm-cli
stay on the srv host omarchy-1.

## Components

| Piece | Where |
|---|---|
| Site settings | `../site.env` (from `../site.env.example`): `GARM_TAILNET_IP`, `GARM_API_PORT`, `SITE_HOST_TAILNET_IP`, `BAZEL_REMOTE_GRPC_PORT`, `BAZEL_REMOTE_HTTP_PORT`, `SITE_HOST_TS_NAME`, `SITE_TAILNET_DNS` |
| Renderer | `install.sh render [DIR]` writes the bazel-remote unit, the GARM config, provider config and `garm.plist` with `@VAR@` placeholders filled from `site.env`; `sudo ./install.sh install` installs only bazel-remote's unit on the srv host. GARM is installed on the Mac with `install-garm-macos.sh` ("GARM on the Mac") |
| Runner image builder | `build-image.sh` → `$SRV_IMAGES_DIR/$GHA_RUNNER_IMAGE/` (registered in `/etc/srv/images.json`). Guests get `SRV_GUEST_AUTH_TAGS=$SITE_TAG_GHA` |
| Provider | `garm-provider-srv/` → `/usr/local/lib/garm/garm-provider-srv` on the Mac (darwin/arm64), config `garm/provider-srv.toml` (`srv_host = $SRV_FRONT_HOST`, `default_image = $GHA_RUNNER_IMAGE`) rendered to `/usr/local/etc/garm/provider-srv.toml`. `_garm`'s `known_hosts` pins the frontend's host key. |
| GARM v0.2.1 | LaunchDaemon `system/garm` on winstons-mac-mini (role account `_garm`), `garm/config.toml.example` → rendered to `/usr/local/etc/garm/config.toml` (fill in the JWT secret and DB passphrase), DB `/usr/local/var/garm/garm.db`. `garm-cli` runs on omarchy-1 (`/usr/local/bin/garm-cli`) |
| Webhook ingress | `../host/relay`: a public HTTPS relay that forwards only `/webhooks/*` over Tailscale to GARM on the Mac (`$GARM_TAILNET_IP:$GARM_API_PORT`; the API and UI are not exposed publicly). GitHub gives up on a delivery after 10 s, and GARM creates runners only from `queued` deliveries; Tailscale Funnel took 7–8 s per delivery and lost jobs, so it is no longer used. |
| Bazel cache | bazel-remote v2.6.4, `systemd/bazel-remote.service`, btrfs subvolume `$BAZEL_REMOTE_DIR` (excluded from snapper root snapshots, compression off), max `$BAZEL_REMOTE_MAX_SIZE_GIB` GiB, gRPC `$SITE_HOST_TAILNET_IP:$BAZEL_REMOTE_GRPC_PORT`, HTTP `:$BAZEL_REMOTE_HTTP_PORT` |
| Secrets | Keep the GARM admin credentials, bazel-remote's `ci` password, and the GitHub App private keys (`*.pem`) outside the repo in a 0600 directory of the admin user, e.g. `~/.config/srv-gha/` |

Release checksums (sha256):
- `garm-cli-linux-amd64.tgz`: `983fa54557f3f5ce3aa1eeb2387499f5f823d14512a0559ba888667bc3b3e88e` (garm-cli on omarchy-1)
- `garm-linux-amd64.tgz`: `11176acb8a725f914b9b947891b4837d374fb616195562cc0ad45a7be8b6c746` (not installed anywhere; the release's linux build of the commit the Mac's `garm` is built from)
- `bazel-remote-2.6.4-linux-amd64`: `6a6b64666c2238ec6b49b7b29f5e41e4149de09417a0028897c9bffe40376876` (the release publishes no checksums; this was recorded at install time)

## GARM on the Mac

| Piece | Where |
|---|---|
| Binary | `/usr/local/bin/garm` (darwin/arm64, built from tag v0.2.1) |
| Provider | `/usr/local/lib/garm/garm-provider-srv` |
| Config | `/usr/local/etc/garm/config.toml`, `/usr/local/etc/garm/provider-srv.toml` (0640 `root:_garm`) |
| State | `/usr/local/var/garm` (0700 `_garm`, also its home): `garm.db`, `blob-garm.db`, `provider-srv/`, `.ssh/known_hosts` (pins srv-front's host key; guest keys are added with accept-new) |
| Log | `/usr/local/var/log/garm.log` |
| launchd | LaunchDaemon `system/garm` (label `garm`, plist `launchd/garm.plist`) |
| Role account | `_garm`, UID/GID 451 (`_srvfront` is 450) |
| Listen | `127.0.0.1:$GARM_API_PORT` only; `tailscale --socket=/var/run/tailscaled.socket serve --bg --tcp 9997 tcp://127.0.0.1:9997` exposes it on the tailnet (Homebrew `tailscaled`, hence `--socket`), like CLIProxyAPI on 8318 |

Upstream v0.2.1 ships no darwin server build, so build `garm` on the Mac
(Homebrew Go and Xcode; cgo is needed for sqlite). Tag v0.2.1 is commit
154638445c, the same as the linux release asset:

```sh
git clone --branch v0.2.1 --depth 1 https://github.com/cloudbase/garm.git && cd garm
GOTOOLCHAIN=auto CGO_ENABLED=1 go build -trimpath -tags osusergo,netgo,sqlite_omit_load_extension \
  -ldflags "-s -w -X github.com/cloudbase/garm/util/appdefaults.Version=v0.2.1" -o garm ./cmd/garm
```

Cross-build the provider on Linux, in `garm-provider-srv/`:

```sh
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath
```

Stage a directory on the Mac with `garm`, `garm-provider-srv`, `garm.plist`,
`config.toml` (the rendered `config.toml.example`, secrets filled in),
`provider-srv.toml` (all three from `./install.sh render`), `known_hosts`
(srv-front's pinned host key line), `install-garm-macos.sh` and, to migrate an
existing controller, `import/` with `garm.db`, `blob-garm.db` (and
`provider-srv/`) from a stopped GARM. Then:

```sh
sudo ./install-garm-macos.sh          # refuses to start without a DB (existing or import/)
sudo ./install-garm-macos.sh --init   # only for a brand-new controller
```

The script creates `_garm`, installs binaries, config and plist, runs
`tailscale serve`, (re)starts `system/garm` and checks that GARM answers.

To upgrade, rebuild the binaries (or change the config), re-stage them and
re-run `sudo ./install-garm-macos.sh`; it replaces binaries and config and
restarts GARM, keeping the DB, provider state and `known_hosts`.

## GitHub

Create one GitHub App per org. Apps are owned by the org, private, and have no
app webhook; GARM installs its own org webhooks.

1. Org settings → Developer settings → GitHub Apps → New. Name it e.g.
   `garm-<host>-<org>`, uncheck **Webhook → Active**, and grant Organization
   **Self-hosted runners: R/W**, **Webhooks: R/W**; Repository **Metadata: R**.
   Restrict installation to this org.
2. Generate a private key and note the **App ID**; install the app on the org
   and note the **Installation ID** (the number at the end of the installation
   settings URL).
3. Point GARM's URLs at the Mac and register the credentials and org. garm-cli
   runs on omarchy-1; its profile `omarchy` (`~/.local/share/garm-cli/config.toml`)
   points at `http://$GARM_TAILNET_IP:$GARM_API_PORT`. Another machine needs
   `garm-cli profile add --name <name> --url "http://$GARM_TAILNET_IP:$GARM_API_PORT"
   --username <admin> --password <password>` (the GARM admin login); a brand-new
   controller is created with `garm-cli init` and the same `--url`:

```sh
. ../site.env
garm-cli controller update \
  --webhook-url "$GARM_WEBHOOK_BASE_URL" \
  --metadata-url "http://$GARM_TAILNET_IP:$GARM_API_PORT/api/v1/metadata" \
  --callback-url "http://$GARM_TAILNET_IP:$GARM_API_PORT/api/v1/callbacks" \
  --agent-url "http://$GARM_TAILNET_IP:$GARM_API_PORT/agent"
garm-cli github credentials add --name <org>-app --auth-type app \
  --app-id <app-id> --app-installation-id <installation-id> \
  --private-key-path ~/.config/srv-gha/keys/<org>.pem --endpoint github.com \
  --description "<org> GitHub App"
garm-cli org add --name <org> --credentials <org>-app --install-webhook --random-webhook-secret
```

GitHub reaches GARM only through the relay (`../host/relay`), which serves
`/webhooks/*` and nothing else. A job whose `queued` delivery failed stays queued
until that delivery is redelivered (org or repo **Settings → Webhooks → Recent
Deliveries → Redeliver**); GARM does not poll GitHub for queued jobs.

GARM registers org runners in the org's `Default` runner group (id 1), which
by default refuses jobs from public repositories. If a repo is public, or is made public later,
turn on **Settings → Actions → Runner groups → Default → Allow public
repositories** (API: `PATCH /orgs/<org>/actions/runner-groups/1` with
`{"allows_public_repositories": true}`, which the org's App can do). If you don't, its jobs stay
queued while runners boot, sit idle, and are scaled down; GARM gives up on the
jobs after about 10 minutes, so redeliver their `queued` deliveries once the
setting is on. Before allowing this, make sure no public repo's workflow runs
fork pull requests on `[self-hosted, srv]`.

### Repositories owned by a user account

GARM can only register organizations as orgs, so a repo owned by a personal
account is registered as a repo, with its own App owned by that account:

1. Account settings → Developer settings → GitHub Apps → New, with
   **Webhook → Active** unchecked and Repository **Administration: R/W**
   (repo-level self-hosted runners), **Webhooks: R/W** and **Metadata: R**.
   Install it on the account with **Only select repositories** set to the
   repo, and note the App ID and Installation ID as above.
2. Register it:

```sh
garm-cli github credentials add --name <user>-app --auth-type app \
  --app-id <app-id> --app-installation-id <installation-id> \
  --private-key-path ~/.config/srv-gha/keys/<user>.pem --endpoint github.com \
  --description "<user> GitHub App"
garm-cli repo add --owner <user> --name <repo> --credentials <user>-app \
  --install-webhook --random-webhook-secret
garm-cli pool add --repo <repo-id> --provider-name srv --image "$GHA_RUNNER_IMAGE" \
  --flavor 6c-24g-30g --os-type linux --os-arch amd64 --runner-prefix gha \
  --tags self-hosted,linux,x64,bazel,srv --max-runners 2 --min-idle-runners 0 --enabled
```

More repos under the same account need only another `repo add` and pool, after
adding them to the App installation.

## Pools

Each org or repo gets one pool, for example:

- Flavor `6c-24g-30g` (24 GiB RAM since 2026-11-18), image `$GHA_RUNNER_IMAGE`.
- Max runners 1000 (all four pools since 2026-11-18), no warm idle runner
  (`--min-idle-runners 0`): a runner VM starts when a job is queued, so each
  job waits for one VM boot.
- Labels `self-hosted, linux, x64, bazel, srv`.

GARM caps each pool separately and has no "unlimited" value (0 blocks every
runner), so 1000 means effectively uncapped. What bounds CI is srv's RAM
budget, enforced at admission on each backend (omarchy-1 and omarchy-2 behind
srv-front, about 503 GiB each, so roughly 20 concurrent 24 GiB runners per
host minus what orbs reserve). Two risks remain: CI can fill both hosts'
budgets so orb spawns fail, and once busy runners outnumber a host's 28
physical cores, CPU-bound steps slow down markedly (~2× was measured). A warm
idle runner (`--min-idle-runners 1`) saves the boot but keeps its memory
reserved even when no jobs are running.

The image mounts `/` with `barrier=0`: runner disks are discarded after each
job, and with barriers every guest fsync cost ~17 ms of host flushing.

```sh
garm-cli pool list
garm-cli pool update <id> --max-runners 1000 --min-idle-runners 0 --flavor 6c-24g-30g
garm-cli runner list
```

Workflows target `runs-on: [self-hosted, srv]`.

## Browsers

The image has Google Chrome stable as `google-chrome` (version in the image
manifest), Arch's `chromium` with `chromedriver`, and `xvfb-run` for headed
tests. `../common/install-google-chrome.sh` installs Chrome from Google's
Debian repository, checking the .deb against the repository's SHA256.
Puppeteer and Playwright download their own browsers unless pointed at
`/usr/bin/google-chrome` or `/usr/bin/chromium`. Drop `--with-deps` from
`playwright install`: it installs libraries with `apt-get`, which Arch lacks,
and the image already has them.

## Docker and arm64 images

Docker runs with the `docker-buildx` plugin, which `docker/setup-buildx-action`
requires. The guest kernel has `binfmt_misc`, so `docker/setup-qemu-action`
registers QEMU and Buildx builds `linux/arm64` images on the x64 runners. The
Deployments platform's arm64 release images build here in about 2 minutes
under emulation; GitHub's arm64 runner took about 4½.

## Tool cache

`build-image.sh` pre-seeds the runner's tool cache
(`/home/runner/actions-runner/_work/_tool/<tool>/<version>/x64`):

- **Node:** each exact version in `GHA_NODE_VERSIONS`, from nodejs.org's
  official tarballs checked against its `SHASUMS256.txt`. `actions/setup-node`
  then finds the requested version locally and skips the download. Each runner
  VM starts from a clean image, so without this every job downloads Node from
  GitHub's CDN, and a stalled download can hang the step until the job times
  out: `@actions/http-client` half-closes a timed-out socket and the process
  waits on it. Keep the list in step with the repos' `.node-version` files and
  rebuild the image after a bump; an unlisted version still works, it just
  downloads again.
- **Python:** each exact version in `GHA_PYTHON_VERSIONS`, from
  [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
  (release `PYTHON_STANDALONE_RELEASE` in `build-image.sh`) checked against the
  release's `SHA256SUMS`. `actions/setup-python` only downloads builds for
  Ubuntu, macOS and Windows, so on these runners a `python-version` the cache
  doesn't hold fails the step. Add the version a workflow requests (any
  `3.12.x` satisfies `python-version: "3.12"`) and rebuild the image.

## Bazel remote cache

`/etc/bazel.bazelrc` in the image sets the cache to read-only. Jobs that should
populate it pass the credentials explicitly. Store `base64("ci:<password>")`
from `bazel-remote.env` as an Actions secret, scoped to trusted branches or
environments only:

```yaml
- run: bazel build //... --remote_upload_local_results --remote_header="Authorization=Basic ${{ secrets.BAZEL_REMOTE_AUTH }}"
```

Never give PR builds from forks the write secret.

## Tailscale policy

srv's OAuth client must be able to create auth keys tagged `$SITE_TAG_GHA`, and
`/etc/srv/srv.env` sets `SRV_GUEST_AUTH_TAGS=$SITE_TAG_GHA`. Orbs never use
srv-created keys; they join as `$ORB_TAILSCALE_TAGS` themselves (see `../srv-orbs`).
That makes `$SITE_TAG_GHA` the default for every non-orb VM, including VMs you create
by hand. Example policy fragment with the default tags (`SITE_TAG_SRV=tag:srv`,
`SITE_TAG_GHA=tag:gha`, `ORB_TAILSCALE_TAGS=tag:amp-orb`) and default ports:

```jsonc
"tagOwners": {
  "tag:gha": ["tag:srv", "autogroup:admin"]
},
"ssh": [
  {"action": "accept", "src": ["you@example.com"], "dst": ["tag:gha", "tag:amp-orb"], "users": ["root"]}
],
"grants": [
  // CI VMs only need GARM on the Mac (GARM_TAILNET_IP, here 100.64.0.20) and
  // bazel-remote on the srv host (SITE_HOST_TAILNET_IP, here 100.64.0.10).
  {"src": ["tag:gha"], "dst": ["100.64.0.20"], "ip": ["tcp:9997"]},
  {"src": ["tag:gha"], "dst": ["100.64.0.10"], "ip": ["tcp:9092"]}
]
```

The tailnet currently uses the default allow-all grant (`src * → dst *`), so
`$SITE_TAG_GHA` VMs can reach every other tailnet node. srv's control plane
rejects tagged callers, so a CI VM cannot drive srv either way, but replacing
allow-all with explicit grants like the ones above restricts CI egress to
`$GARM_TAILNET_IP` on `$GARM_API_PORT` and `$SITE_HOST_TAILNET_IP` on
`$BAZEL_REMOTE_GRPC_PORT`.

## Rebuilding the image

```sh
sudo ./build-image.sh   # reads ../site.env; reflink layer on arch-base; bump the runner version/sha256 at the top
```

Rebuild after rebuilding `arch-base`, whenever GitHub starts requiring a
newer runner, or after changing `GHA_NODE_VERSIONS` or `GHA_PYTHON_VERSIONS`.
Running VMs keep their rootfs, but with ephemeral runners every new job gets
the new image. Recycle idle runners after a rebuild with
`garm-cli runner rm <name>`.

## srv

Run upstream srv (`SRV_SRC_DIR` in `site.env`; https://github.com/HeavyHorst/srv)
at or after the revision named in the top-level README ("srv version"), plus
the patches in `../host/srv/patches/` ("srv patches" there).
When upgrading srv:

1. Disable the pools and remove the idle runners.
2. Back up `/var/lib/srv/state`, `/etc/srv` and `/srv/jail/.start-receipts`.
3. Update `SRV_SRC_DIR` to the new upstream revision, run
   `../host/srv/apply-patches.sh`, then `sudo ./contrib/systemd/install.sh` in
   `SRV_SRC_DIR`, and restart `srv-net-helper`, `srv-vm-runner` and `srv`.
4. Rebuild and install `srv-orb-dispatch` (see `../srv-orbs`), then re-enable
   the pools.
