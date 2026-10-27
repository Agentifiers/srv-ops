# srv-ops

Host setup for running [srv](https://github.com/HeavyHorst/srv) (Firecracker
microVMs over Tailscale) on one Linux machine as:

- a pool of **[Amp](https://ampcode.com) self-hosted orbs** (general-purpose
  and mobile-development), and
- **ephemeral GitHub Actions runners** (one microVM per job, via GARM), with a
  shared Bazel remote cache.

The two workloads share srv but use separate images, Tailscale tags and VM
name prefixes, so neither can disturb the other.

| Directory | What |
|---|---|
| `srv-orbs/` | Amp orbs using srv's upstream `srv-orb-dispatch` and native orb image, plus a thin image layer that puts every orb on your tailnet (Amp workload identity → Tailscale OIDC) and adds common tooling. See `srv-orbs/README.md`. |
| `srv-orbs/mobile/` | `amp-orb-mobile` and its provider: a `-mobile` guest kernel (binder, ashmem, dma-buf heaps, extra netfilter, PSI) and an image with Android (SDK, redroid, expo-device-hub, agent-device) and iOS (Swift 6.4, xtool, Darwin SDK from your Xcode .xip, pymobiledevice3, `expo-ios`) tooling. Expo/React Native iOS apps build in the orb on Linux. See `srv-orbs/mobile/README.md`. |
| `srv-mobile-host/` | A USB-attached iPhone shared by mobile orbs: `pmd3-tunneld` and `iphone-broker` (exclusive leases over the tailnet, development signing, install, launch, screenshots, HID input, logs, port forwards). See `srv-mobile-host/README.md`. |
| `srv-gha/` | Ephemeral GitHub Actions runners: GARM config, the `garm-provider-srv` adapter, the `gha-runner` image builder, and the GARM and bazel-remote units. See `srv-gha/README.md`. |
| `host/` | srv's `images.json`, an `srv.env` template, local srv patches and host sysctl settings. |

## Configure

All site-specific values (tailnet IP and names, admin logins, Amp workspace,
Tailscale OIDC client, Apple bundle-id prefix, ports) live in one file:

```sh
cp site.env.example site.env    # gitignored
$EDITOR site.env
```

Image builders and installers source `site.env` and stop with a clear message
if a value they need is missing. Secrets never go in `site.env` or the repo.

## Host settings srv depends on

- **`SRV_JAILER_BASE_DIR=/srv/jail`** (same filesystem as `/var/lib/srv`).
  Orb VM names are long, and the default jailer path pushes Firecracker's API
  socket past the 108-byte Unix socket limit; launches then time out and stay
  quarantined until the host reboots.
- **`SRV_GUEST_AUTH_TAGS=tag:gha`.** Orbs don't use srv-minted keys, so this
  default tag applies only to CI and hand-made VMs.
- **Firewall** (ufw example; srv's default VM network is `172.28.0.0/16`):
  ```sh
  sudo ufw allow proto tcp from 172.28.0.0/16 to 172.28.0.0/16 port 3128   # Amp CONNECT gateway (orb bootstrap)
  sudo ufw route allow from 172.28.0.0/16                                   # VM egress, matches srv's FORWARD accept
  ```
- **Dirty-page caps:** `host/sysctl/99-srv-dirty.conf` → `/etc/sysctl.d/`
  (1 GiB background / 4 GiB). Small desktop defaults throttle Firecracker I/O
  when several VMs write at once.
- **LUKS on NVMe:** consider disabling dm-crypt workqueues for lower I/O
  latency:
  `sudo cryptsetup refresh --perf-no_read_workqueue --perf-no_write_workqueue --persistent <mapping>`

## srv patches

`host/srv/patches/` holds fixes this setup needs that upstream srv doesn't
have yet. Apply them to the checkout in `SRV_SRC_DIR` before building srv:

```sh
host/srv/apply-patches.sh --check   # already applied / would apply / does not apply
host/srv/apply-patches.sh
cd "$SRV_SRC_DIR" && sudo ./contrib/systemd/install.sh
```

| Patch | Why | Upstream |
|---|---|---|
| `0001-keep-empty-machine-id-in-project-templates.patch` | srv's project-template sanitizer deletes `/etc/machine-id`, so every Orb cloned from a project snapshot boots as a systemd "first boot", enables `systemd-networkd-wait-online`, stalls up to two minutes and misses its first bootstrap. The patch leaves an empty, root-owned 0444 file instead (fresh transient ID per boot, no first-boot semantics). | [HeavyHorst/srv#8](https://github.com/HeavyHorst/srv/pull/8) |

Delete a patch once upstream has merged it; `apply-patches.sh` then reports
it as not applying (or already applied) on the new revision.

## Backups

Back these up together: `/var/lib/srv/state`, `/srv/jail/.start-receipts`,
`/etc/srv`, `/var/lib/srv-orbs/dispatch*`, `/var/lib/garm` and
`/var/lib/iphone-broker` (lease state, broker-installed apps, signing key and
certificate).

## Secrets

Where they live on the host (never in this repo):

- `/etc/srv/srv.env`: Tailscale OAuth client and auth key.
- `/etc/srv-orbs*.env`: Amp orb provider tokens.
- `/etc/garm/config.toml`: JWT secret and DB passphrase.
- GARM admin login, bazel-remote credentials and GitHub App private keys:
  root- or admin-only files you choose (see `srv-gha/README.md`).
- `/etc/srv-mobile/asc.env` and the `.p8` it names: App Store Connect API key,
  passed to `iphone-broker` as systemd credentials.
  `/var/lib/iphone-broker/signing/key.pem` is the broker's development
  signing key.

## License

MIT (see `LICENSE`); a few vendored or derived files keep their own licenses,
listed in `NOTICE.md`.
