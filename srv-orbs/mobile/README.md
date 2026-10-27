# Mobile app development orbs

An srv image (`MOBILE_ORB_IMAGE`, default `amp-orb-mobile`) for Expo / React
Native, Android and iOS work driven by Amp agents. It is served by a separate
Amp orb provider whose per-orb shape is `MOBILE_ORB_CPUS` / `MOBILE_ORB_RAM` /
`MOBILE_ORB_DISK` (default 8 vCPU, 16G RAM, 80G disk). It boots a custom
`-mobile` kernel, which Android in docker (redroid) needs.

All settings below are variables in the repo's `site.env` (see
`site.env.example`); the scripts read it through `common/site-env.sh`.

## Layout

| Path | Purpose |
|---|---|
| `kernel/build-kernel.sh` | Builds the `-mobile` guest kernel into `$SRV_IMAGES_DIR/mobile-kernel/` from the srv checkout in `SRV_SRC_DIR`. |
| `kernel/mobile.config` | Kconfig fragment merged over srv's arch-base kernel config. It adds binder/binderfs, ashmem, dma-buf heaps, and the netfilter, tc and bpf options that Android netd and Tailscale need. |
| `kernel/patches/*.patch` | Kernel patches applied to the work tree in name order. `0001-staging-android-ashmem.patch` restores Android's ashmem driver (removed upstream in 5.18) as built-in `CONFIG_ASHMEM`. |
| `build-mobile-image.sh` | Image builder. It runs the modules below in order. |
| `modules/<name>.sh` | Image modules: `android`, `device-tools`, `ios-toolchain`, `ios-sdk`, `expo-ios`, `iphone-client`, `agent-device-ios`. Helper files live next to them in `modules/<name>/` or `modules/<name>.d/`. |
| `../../srv-mobile-host/` | Host side of the shared iPhone: `pmd3-tunneld` and `iphone-broker`, which the `iphone` CLI (`modules/iphone-client`) calls at `http://$SITE_HOST_TAILNET_IP:$IPHONE_BROKER_PORT` (baked into the image as `IPHONE_BROKER_URL`). See its README. |
| `expo-ios/` | The `expo-ios` build tool and its overlays and patches. See `expo-ios/README.md`. |
| `systemd/srv-orbs-mobile.service` (+ `.service.d-coredump.conf`) | The mobile provider: upstream's `srv-orbs.service` with `EnvironmentFile=/etc/srv-orbs-mobile.env`, plus the same coredump drop-in as `../systemd/`. |
| `srv-orbs-mobile.env.example` | Template for `/etc/srv-orbs-mobile.env` (root, 0600), rendered by `../install.sh` from `SRV_HOST` and `MOBILE_ORB_*`; the provider token is added by hand. Dispatcher state lives in `/var/lib/srv-orbs/dispatch-mobile`, separate from the default provider. |

Outputs:

| Path | Content |
|---|---|
| `$SRV_IMAGES_DIR/mobile-kernel/` | Kernel output: `vmlinux`, `config`, `release` (e.g. `6.12.79-mobile`), `modules/<release>/`, `manifest.txt` (fragment and patch sha256s). `work/` is a reflink copy of srv's kernel tree with `kernel/patches/` applied; srv's own tree is never modified. |
| `$SRV_IMAGES_DIR/$MOBILE_ORB_IMAGE/` | Production image (`--target orb`), layered on `$ORB_IMAGE`. |
| `$SRV_IMAGES_DIR/$MOBILE_TEST_IMAGE/` | Test image (`--target test`, default `mobile-test`), layered on `arch-base`. Its VMs join the tailnet through arch-base's bootstrap, so `ssh root@<vm>` works. |

Both images are registered in `/etc/srv/images.json` (render it with
`host/render.sh images.json`) with kernel `$SRV_IMAGES_DIR/mobile-kernel/vmlinux`.
srv reads that file only at startup, so restart srv after adding an entry.

## Build

```bash
sudo ./kernel/build-kernel.sh                  # after changing kernel/mobile.config or kernel/patches/
sudo ./build-mobile-image.sh --target test     # arch-base  -> $MOBILE_TEST_IMAGE
sudo ./build-mobile-image.sh --target orb      # $ORB_IMAGE -> $MOBILE_ORB_IMAGE
sudo ./build-mobile-image.sh --target test --only android,device-tools
sudo ./build-mobile-image.sh --target test --only kernel,device-tools   # after a kernel rebuild (also --target orb)
sudo ./build-mobile-image.sh --target test --only device-tools,agent-device-ios   # device-tools resets /opt/agent-device; rerun agent-device-ios after it
```

`build-kernel.sh` applies `kernel/patches/*.patch` to its work tree
(`git apply`; a patch that is already applied is skipped, one that neither
applies nor reverses cleanly fails the build). It then starts each run from
srv's `.config`, merges `mobile.config` with `merge_config.sh`, and runs
`make olddefconfig`. It fails if any requested option did not survive, if
any requirement from srv's `validate_kernel_config` is missing, or if
`vmlinux` lacks the ashmem driver. The first build reuses srv's object files.
To change an already-applied patch, reverse the old version
(`git -C <work tree> apply -R old.patch`) or delete `work/` to recopy srv's
tree. After a kernel rebuild, rebuild both images (`--only kernel,device-tools`
is enough) so `/usr/lib/modules/<release>` matches `vmlinux`.

`build-mobile-image.sh` steps:

1. Reflink-copies the base rootfs. With `--only`, it copies the target's
   existing image instead.
2. Grows the copy to `MOBILE_IMAGE_SIZE` (default `60G`, sparse).
3. Applies the uid-1000 ownership fix that `../build-image.sh` also applies.
4. Test target only: installs the packages the orb base already has (sudo,
   base-devel, node and npm/pnpm/yarn, pip and uv, …). It then creates `user`
   (1000:1000, groups wheel and docker, NOPASSWD sudo), so modules see the
   orb's layout.
5. Replaces the base kernel's module tree with
   `/usr/lib/modules/<release>` from the mobile kernel. This runs on every
   build, including `--only`, so `--only kernel` (no modules) refreshes an
   image after a kernel rebuild.
6. Runs the modules in order. A module that does not exist yet is skipped
   with a warning. With `--only`, every named module must exist. If a module
   fails, the build aborts and the previous image stays in place.
7. Dedups the guest manifest, writes `manifest.txt`, clears the pacman cache,
   runs `e2fsck`, and atomically replaces `rootfs-base.img`.

One build per target runs at a time (`flock` on `<output>/.build.lock`).
VMs that already exist keep their own disk.

## Module contract

Each module is an executable `modules/<name>.sh` that runs **on the host as
root** with this environment, plus every `site.env` setting (exported by
`build-mobile-image.sh`; a module checks the ones it needs):

| Variable | Value |
|---|---|
| `MNT` | Mounted rootfs. |
| `CACHE` | `$MOBILE_CACHE_DIR` (shared download cache, default `/var/cache/srv-mobile`). |
| `HERE` | This directory. |
| `TARGET` | `orb` or `test`. |

Rules:

- **Guest commands:** run them with `arch-chroot "$MNT" …`. Use
  `arch-chroot "$MNT" runuser -u user -- …` for installs owned by `user`.
- **Downloads:** pin every download by version and sha256, and cache it in
  `$CACHE`.
- **Idempotent:** `--only` reruns a module on an already-built image.
- **Permissions:** set `umask 022`.
- **Binaries:** expose them as symlinks in `/usr/local/bin`. Do not rewrite
  `PATH`.
- **Environment variables:** write them to both
  `$MNT/etc/systemd/system.conf.d/mobile-<name>.conf`
  (`[Manager]` / `DefaultEnvironment=…`) and
  `$MNT/etc/profile.d/mobile-<name>.sh`.
- **Skills:** put them in
  `$MNT/home/user/.config/agents/skills/<skill>/SKILL.md`. Every directory you
  create there must be owned by 1000:1000.
- **Manifest:** append `key=value` version lines to
  `$MNT/etc/amp-orb-mobile.manifest`. A full build truncates it first. On
  `--only` reruns the last value for each key wins.
- **Failure:** exit non-zero on any verification failure. The build then
  aborts and keeps the previous image.

## Testing modules in a VM

```bash
sudo ./build-mobile-image.sh --target test --only <module>
ssh -o BatchMode=yes "$SRV_HOST" new mt-<agent>-1 --image "$MOBILE_TEST_IMAGE" \
  --cpus "$MOBILE_ORB_CPUS" --ram "$MOBILE_ORB_RAM" --rootfs-size "$MOBILE_ORB_DISK"
ssh root@mt-<agent>-1
ssh "$SRV_HOST" delete mt-<agent>-1
```

The kernel provides:

- `uname -r` ending in `-mobile`.
- binderfs: `mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs`.
- `/dev/ashmem` (built in, mode 0666 from devtmpfs, as redroid's
  `99-redroid.rules` expects).
- `/dev/dma_heap/system`.
- iptables `owner`, `connmark`, `mark`, `bpf`, `quota`, `socket`, `CT`, `NFLOG`
  and `TCPMSS` matches and targets, plus the IPv4 and IPv6 `raw`/`mangle`
  tables. Arch's `iptables` is iptables-nft, which turns `NFLOG`, `limit`,
  `quota` and similar into native nft expressions, so the fragment also
  enables the matching `CONFIG_NFT_*` options.
- `/proc/pressure/*` without a `psi=1` boot argument (srv's boot arguments are
  not per image). redroid's lmkd needs it; without it system_server stalls.

The image pins redroid 16 (`redroid/redroid:16.0.0_64only-250627`, by
digest). Its surfaceflinger crash-loops ("output buffer not gpu writeable",
redroid-doc#934) without `/dev/ashmem`, so `redroid-up` refuses to start
without it. redroid still runs with `androidboot.use_memfd=1`. Fallback on a
kernel without ashmem: `redroid-down --wipe`, then
`REDROID_IMAGE=redroid/redroid:15.0.0_64only-250627@sha256:b51bde9cef80f7bd7581148192f2b2f4d41f23c6344cfe88eceeb8ddd67490ee redroid-up`
(pulled from Docker Hub; not prefetched).

## Provider

```bash
sudo ../install.sh install     # units, drop-ins, /etc/srv-orbs{,-mobile}.env from site.env
# add AMP_ORB_PROVIDER_TOKEN (Amp workspace Settings -> Orbs, the mobile provider) to /etc/srv-orbs-mobile.env
sudo -u srv-orbs env HOME=/var/lib/srv-orbs SRV_ORB_ENDPOINT="$SRV_HOST" \
  SRV_ORB_STATE_DIR=/var/lib/srv-orbs/dispatch-mobile /usr/local/bin/srv-orb-dispatch init
sudo systemctl enable --now srv-orbs-mobile
```

Start it only after `$MOBILE_ORB_IMAGE` is registered in `images.json` and srv
has been restarted: if a spawn reaches srv with an unknown image, the
dispatcher fences that thread's orb as an uncertain create.
