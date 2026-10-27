#!/usr/bin/env bash
# Builds a mobile-development srv image as a reflink layer on a base rootfs:
# grows it, installs the -mobile kernel's modules, then runs modules/<name>.sh
# in order (see README.md for the module contract).
#
#   sudo ./kernel/build-kernel.sh                  # once per kernel change
#   sudo ./build-mobile-image.sh --target orb      # $ORB_IMAGE -> $MOBILE_ORB_IMAGE
#   sudo ./build-mobile-image.sh --target test     # arch-base  -> $MOBILE_TEST_IMAGE
#   sudo ./build-mobile-image.sh --target test --only android,device-tools
#   sudo ./build-mobile-image.sh --target test --only kernel   # after build-kernel.sh
#
# --only reruns the named modules on the target's existing image instead of
# rebuilding from the base. Every run reinstalls the kernel's module tree, so
# `--only kernel` (no modules) refreshes an image after a kernel rebuild.
# Settings come from the repo's site.env: SRV_IMAGES_DIR, ORB_IMAGE,
# MOBILE_ORB_IMAGE, MOBILE_TEST_IMAGE, MOBILE_IMAGE_SIZE, MOBILE_CACHE_DIR, and
# for the iphone-client and agent-device-ios modules SITE_HOST_TAILNET_IP,
# IPHONE_BROKER_PORT and APPLE_BUNDLE_PREFIX.
# Register the result in /etc/srv/images.json with kernel
# $SRV_IMAGES_DIR/mobile-kernel/vmlinux.
set -euo pipefail
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/site-env.sh
. "$HERE/../../common/site-env.sh"
site_env_load
KERNEL_DIR="${KERNEL_DIR:-$SRV_IMAGES_DIR/mobile-kernel}"
CACHE="$MOBILE_CACHE_DIR"
ROOTFS_SIZE="$MOBILE_IMAGE_SIZE"
MODULES=(android device-tools ios-toolchain ios-sdk expo-ios iphone-client agent-device-ios)
# Packages the orb base already has; the test image gets them so modules
# see the same userspace as in production.
TEST_PACKAGES=(sudo base-devel nodejs npm pnpm yarn python-pip uv unzip zip wget lsof tmux github-cli)

usage() { echo "usage: $0 --target orb|test [--only kernel|module[,module...]]" >&2; exit 2; }

target="" only=""
ran=()
while (( $# )); do
	case $1 in
		--target) target="${2:-}"; shift 2 ;;
		--only) only="${2:-}"; [[ -n $only ]] || usage; shift 2 ;;
		*) usage ;;
	esac
done
case $target in
	orb) BASE_DIR="$SRV_IMAGES_DIR/$ORB_IMAGE" IMAGE="$MOBILE_ORB_IMAGE" ;;
	test) BASE_DIR="$SRV_IMAGES_DIR/arch-base" IMAGE="$MOBILE_TEST_IMAGE" ;;
	*) usage ;;
esac
OUTPUT_DIR="$SRV_IMAGES_DIR/$IMAGE"

selected=()
if [[ -n $only ]]; then
	IFS=, read -ra names <<< "$only"
	for m in "${names[@]}"; do
		[[ $m == kernel ]] && continue
		[[ -x $HERE/modules/$m.sh ]] || { echo "no executable module $HERE/modules/$m.sh" >&2; exit 1; }
		selected+=("$m")
	done
else
	selected=("${MODULES[@]}")
fi
# Fail before the build, not halfway, when a selected module lacks its settings.
site_vars=()
for m in "${selected[@]}"; do
	case $m in
		iphone-client) site_vars+=(SITE_HOST_TAILNET_IP IPHONE_BROKER_PORT APPLE_BUNDLE_PREFIX) ;;
		agent-device-ios) site_vars+=(APPLE_BUNDLE_PREFIX) ;;
	esac
done
site_env_load "${site_vars[@]}"

[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
release="$(cat "$KERNEL_DIR/release")"
[[ -f $KERNEL_DIR/vmlinux && -d $KERNEL_DIR/modules/$release ]] || { echo "mobile kernel missing; run kernel/build-kernel.sh" >&2; exit 1; }

install -d -m 0755 "$OUTPUT_DIR" "$CACHE"
# One build per target at a time: siblings iterate with --only concurrently.
exec 9> "$OUTPUT_DIR/.build.lock"
flock -n 9 || { echo "another build of $IMAGE is running" >&2; exit 1; }

if [[ -n $only ]]; then
	source_img="$OUTPUT_DIR/rootfs-base.img"
	[[ -f $source_img ]] || { echo "$source_img does not exist; build without --only first" >&2; exit 1; }
else
	source_img="$BASE_DIR/rootfs-base.img"
fi
img="$OUTPUT_DIR/rootfs-base.img.new"
manifest_new="$OUTPUT_DIR/manifest.txt.new"
mnt="$(mktemp -d)"
udev_rule=/run/udev/rules.d/99-srv-image-no-automount.rules

cleanup() {
	local status=$?
	trap - EXIT
	# pacman-key/gpg and module-started daemons can keep the mount busy.
	pkill -f "gpg-agent --homedir $mnt/" 2>/dev/null || true
	if mountpoint -q "$mnt"; then
		umount -R "$mnt" || { echo "failed to unmount $mnt; leaving it in place" >&2; exit 1; }
	fi
	rmdir "$mnt"
	rm -f "$udev_rule"
	udevadm control --reload
	[[ $status == 0 ]] || rm -f "$img" "$manifest_new"
	exit "$status"
}
trap cleanup EXIT

# Keep desktop automounters (udisks) off the loop device while we write to it.
mkdir -p "$(dirname "$udev_rule")"
echo 'KERNEL=="loop*", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"' > "$udev_rule"
udevadm control --reload

cp --reflink=always "$source_img" "$img"
if (( $(stat -c %s "$img") < $(numfmt --from=iec "$ROOTFS_SIZE") )); then
	truncate -s "$ROOTFS_SIZE" "$img"
	e2fsck -fy "$img" >/dev/null || (( $? < 4 ))
	resize2fs "$img" >/dev/null
fi
mount -o loop "$img" "$mnt"

# srv's arch-base build rsyncs its overlay with -a, so / and the overlay files
# inherit the checkout owner's UID (1000). Hand anything owned by an unknown
# uid 1000 back to root (no-op once `user` exists).
chown 0:0 "$mnt"
if ! awk -F: '$3 == 1000 { found = 1 } END { exit !found }' "$mnt/etc/passwd"; then
	find "$mnt" -xdev \( -uid 1000 -o -gid 1000 \) -exec chown -h 0:0 {} +
fi

if [[ $target == test ]]; then
	arch-chroot "$mnt" pacman -Sy --needed --noconfirm "${TEST_PACKAGES[@]}"
	if ! arch-chroot "$mnt" id -u user >/dev/null 2>&1; then
		arch-chroot "$mnt" useradd -m -u 1000 -U -G wheel,docker -s /bin/bash user
	fi
	echo 'user ALL=(ALL) NOPASSWD: ALL' > "$mnt/etc/sudoers.d/amp-user"
	chmod 0440 "$mnt/etc/sudoers.d/amp-user"
	arch-chroot "$mnt" visudo -cq
fi
[[ "$(arch-chroot "$mnt" id -u user):$(arch-chroot "$mnt" id -g user)" == 1000:1000 ]] || { echo "user is not 1000:1000 in $IMAGE" >&2; exit 1; }

# Replace the base kernel's module tree (not owned by any package) with ours.
for dir in "$mnt"/usr/lib/modules/*/; do
	name="$(basename "$dir")"
	[[ $name == "$release" ]] && continue
	arch-chroot "$mnt" pacman -Qqo "/usr/lib/modules/$name" >/dev/null 2>&1 || rm -rf "$dir"
done
rm -rf "$mnt/usr/lib/modules/$release"
cp -a "$KERNEL_DIR/modules/$release" "$mnt/usr/lib/modules/$release"
depmod -b "$mnt" "$release"

guest_manifest="$mnt/etc/amp-orb-mobile.manifest"
[[ -n $only ]] || : > "$guest_manifest"
chmod 0644 "$guest_manifest"
for m in "${selected[@]}"; do
	script="$HERE/modules/$m.sh"
	if [[ ! -x $script ]]; then
		echo "warning: module $m not present ($script); skipping" >&2
		continue
	fi
	echo "==> module $m"
	env MNT="$mnt" CACHE="$CACHE" HERE="$HERE" TARGET="$target" "$script" \
		|| { echo "module $m failed" >&2; exit 1; }
	ran+=("$m")
done
# Modules append key=value lines; keep the last value per key so --only reruns
# replace earlier entries.
tac "$guest_manifest" | awk -F= '!seen[$1]++' | tac > "$guest_manifest.tmp"
mv "$guest_manifest.tmp" "$guest_manifest"
chmod 0644 "$guest_manifest"

{
	echo "image=$IMAGE"
	echo "target=$target"
	echo "base=$BASE_DIR"
	echo "base_built_at=$(sed -n 's/^built_at=//p' "$BASE_DIR/manifest.txt")"
	echo "built_at=$(date --iso-8601=seconds)"
	echo "kernel=$KERNEL_DIR/vmlinux"
	echo "kernel_release=$release"
	echo "rootfs_size=$ROOTFS_SIZE"
	echo "modules_run=$(IFS=,; echo "${ran[*]:-}")"
	[[ -z $only ]] || echo "rerun_only=$only"
	cat "$guest_manifest"
} > "$manifest_new"

rm -rf "$mnt/var/cache/pacman/pkg/"* "$mnt/root/.cache"
pkill -f "gpg-agent --homedir $mnt/" 2>/dev/null || true
umount "$mnt"
e2fsck -fn "$img" >/dev/null || { echo "filesystem check failed on $img" >&2; exit 1; }

mv "$img" "$OUTPUT_DIR/rootfs-base.img"
mv "$manifest_new" "$OUTPUT_DIR/manifest.txt"
echo "built $OUTPUT_DIR/rootfs-base.img"
cat "$OUTPUT_DIR/manifest.txt"
