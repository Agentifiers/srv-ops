# srv-gha: ephemeral GitHub Actions runners on srv

Each GitHub Actions job runs in its own srv Firecracker microVM. GARM gets a
`workflow_job` webhook, asks `garm-provider-srv` for a VM, and the runner
registers with GitHub using JIT config. When the job finishes, the VM is
deleted. The VMs are completely separate from the Amp orb setup in
`../srv-orbs`. They use a different image, a different Tailscale tag
(`$SITE_TAG_GHA`, default `tag:gha`, srv's default guest tag), and a separate set of VM names (`gha-*`).

```
GitHub ──webhook──> Funnel :FUNNEL/webhooks ──> garm (HOST_IP:GARM_API)
                                               │ GARM_COMMAND=CreateInstance
                                               v
                               garm-provider-srv ──ssh SRV_HOST new gha-… --image GHA_RUNNER_IMAGE
                                               │ Tailscale SSH root@gha-…: runner install script
                                               v
                       runner VM (SITE_TAG_GHA) ──> metadata/callback :GARM_API, bazel-remote :GRPC
```

Uppercase names refer to `site.env` settings (`GARM_WEBHOOK_FUNNEL_PORT`,
`SITE_HOST_TAILNET_IP`, `GARM_API_PORT`, `BAZEL_REMOTE_GRPC_PORT`, ...).

## Components

| Piece | Where |
|---|---|
| Site settings | `../site.env` (from `../site.env.example`): `SITE_HOST_TAILNET_IP`, `GARM_API_PORT`, `BAZEL_REMOTE_GRPC_PORT`, `BAZEL_REMOTE_HTTP_PORT`, `SITE_HOST_TS_NAME`, `SITE_TAILNET_DNS` |
| Renderer | `install.sh render [DIR]` writes the units and GARM config with `@VAR@` placeholders filled from `site.env`; `sudo ./install.sh install` installs them (creates `/etc/garm/config.toml` only if missing) |
| Runner image builder | `build-image.sh` → `$SRV_IMAGES_DIR/$GHA_RUNNER_IMAGE/` (registered in `/etc/srv/images.json`). Guests get `SRV_GUEST_AUTH_TAGS=$SITE_TAG_GHA` |
| Provider | `garm-provider-srv/` → `/usr/local/lib/garm/garm-provider-srv`, config `garm/provider-srv.toml` (`srv_host = $SRV_HOST`, `default_image = $GHA_RUNNER_IMAGE`) rendered to `/etc/garm/provider-srv.toml` |
| GARM v0.2.1 | `/usr/local/bin/garm{,-cli}`, `systemd/garm.service` (user `garm`), `garm/config.toml.example` → rendered to `/etc/garm/config.toml` (fill in the JWT secret and DB passphrase), DB `/var/lib/garm/garm.db` |
| Webhook ingress | `tailscale funnel` on `:$GARM_WEBHOOK_FUNNEL_PORT`, path `/webhooks` only (the API and UI are not exposed) |
| Bazel cache | bazel-remote v2.6.4, `systemd/bazel-remote.service`, btrfs subvolume `$BAZEL_REMOTE_DIR` (excluded from snapper root snapshots, compression off), max `$BAZEL_REMOTE_MAX_SIZE_GIB` GiB, gRPC `$SITE_HOST_TAILNET_IP:$BAZEL_REMOTE_GRPC_PORT`, HTTP `:$BAZEL_REMOTE_HTTP_PORT` |
| Secrets | Keep the GARM admin credentials, bazel-remote's `ci` password, and the GitHub App private keys (`*.pem`) outside the repo in a 0600 directory of the admin user, e.g. `~/.config/srv-gha/` |

Release checksums (sha256):
- `garm-linux-amd64.tgz`: `11176acb8a725f914b9b947891b4837d374fb616195562cc0ad45a7be8b6c746`
- `garm-cli-linux-amd64.tgz`: `983fa54557f3f5ce3aa1eeb2387499f5f823d14512a0559ba888667bc3b3e88e`
- `bazel-remote-2.6.4-linux-amd64`: `6a6b64666c2238ec6b49b7b29f5e41e4149de09417a0028897c9bffe40376876` (the release publishes no checksums; this was recorded at install time)

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
3. Point GARM's URLs at this host and register the credentials and org:

```sh
. ../site.env
garm-cli controller update \
  --webhook-url "https://$SITE_HOST_TS_NAME.$SITE_TAILNET_DNS:$GARM_WEBHOOK_FUNNEL_PORT/webhooks" \
  --metadata-url "http://$SITE_HOST_TAILNET_IP:$GARM_API_PORT/api/v1/metadata" \
  --callback-url "http://$SITE_HOST_TAILNET_IP:$GARM_API_PORT/api/v1/callbacks"
garm-cli github credentials add --name <org>-app --auth-type app \
  --app-id <app-id> --app-installation-id <installation-id> \
  --private-key-path ~/.config/srv-gha/keys/<org>.pem --endpoint github.com \
  --description "<org> GitHub App"
garm-cli org add --name <org> --credentials <org>-app --install-webhook --random-webhook-secret
```

Expose only the webhook path publicly:
`tailscale funnel --bg --https $GARM_WEBHOOK_FUNNEL_PORT --set-path /webhooks http://$SITE_HOST_TAILNET_IP:$GARM_API_PORT/webhooks`.

## Pools

Each org gets one pool, for example:

- Flavor `6c-12g-30g`, image `$GHA_RUNNER_IMAGE`.
- Max 4 runners, 1 warm idle runner.
- Labels `self-hosted, linux, x64, bazel, srv`.

GARM caps each pool separately; orgs cannot share one limit. Size the pools
against srv's memory budget and physical cores: with two orgs at these
settings, CI can reserve 8 × 12 GiB = 96 GiB and 48 vCPUs, and once busy
runners outnumber physical cores CPU-bound steps slow down markedly (~2× was
measured on a 28-core host). Each warm idle runner keeps its memory reserved
even when no jobs are running.

The image mounts `/` with `barrier=0`: runner disks are discarded after each
job, and with barriers every guest fsync cost ~17 ms of host flushing.

```sh
garm-cli pool list
garm-cli pool update <id> --max-runners 4 --min-idle-runners 1 --flavor 6c-12g-30g
garm-cli runner list
```

Workflows target `runs-on: [self-hosted, linux, bazel]`.

## Browsers

The image has Google Chrome stable as `google-chrome` (version in the image
manifest), Arch's `chromium` with `chromedriver`, and `xvfb-run` for headed
tests. `../common/install-google-chrome.sh` installs Chrome from Google's
Debian repository, checking the .deb against the repository's SHA256.
Puppeteer and Playwright download their own browsers unless pointed at
`/usr/bin/google-chrome` or `/usr/bin/chromium`.

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
  // CI VMs only need GARM and bazel-remote on the host.
  {"src": ["tag:gha"], "dst": ["100.64.0.10"], "ip": ["tcp:9997", "tcp:9092"]}
]
```

With the default allow-all grant (`src * → dst *`) instead, `$SITE_TAG_GHA` VMs can
reach every other tailnet node. srv's control plane rejects tagged callers, so
a CI VM cannot drive srv either way, but replacing allow-all with explicit
grants like the one above restricts CI egress to `$SITE_HOST_TAILNET_IP` on
`$GARM_API_PORT` and `$BAZEL_REMOTE_GRPC_PORT`.

## Rebuilding the image

```sh
sudo ./build-image.sh   # reads ../site.env; reflink layer on arch-base; bump the runner version/sha256 at the top
```

Rebuild after rebuilding `arch-base`, or whenever GitHub starts requiring a
newer runner. Running VMs keep their rootfs, but with ephemeral runners every
new job gets the new image. Recycle idle runners after a rebuild with
`garm-cli runner rm <name>`.

## srv

Run upstream srv (`SRV_SRC_DIR` in `site.env`; https://github.com/HeavyHorst/srv)
with project templates that keep an empty `/etc/machine-id`; a missing one
makes every clone run systemd's first-boot presets and stall on
`systemd-networkd-wait-online`. When upgrading srv:

1. Disable the pools and remove the idle runners.
2. Back up `/var/lib/srv/state`, `/etc/srv` and `/srv/jail/.start-receipts`.
3. Run `sudo ./contrib/systemd/install.sh`, then restart `srv-net-helper`,
   `srv-vm-runner` and `srv`.
4. Rebuild and install `srv-orb-dispatch` (see `../srv-orbs`), then re-enable
   the pools.
