#!/usr/bin/env bash
# Builds the `-mobile` Firecracker guest kernel: srv's arch-base kernel (source
# tree + .config from its last build) plus patches/*.patch (built-in ashmem)
# and mobile.config (binderfs, dma-buf heaps, ashmem, netfilter for Android
# netd and Tailscale).
#
#   sudo ./build-kernel.sh
#
# Outputs (root-owned, world-readable) in $OUTPUT_DIR:
#   vmlinux             the guest kernel srv boots
#   config              its final .config
#   release             `uname -r` of the kernel, e.g. 6.12.79-mobile
#   modules/<release>/  module tree that build-mobile-image.sh installs as
#                       /usr/lib/modules/<release> in the rootfs
#   manifest.txt
# srv's work tree is copied (reflink) to $OUTPUT_DIR/work and never modified.
set -euo pipefail
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# srv's checkout and image directory: SRV_SRC_DIR and SRV_IMAGES_DIR in the
# repo's site.env.
# shellcheck source=../../../common/site-env.sh
. "$HERE/../../../common/site-env.sh"
site_env_load SRV_SRC_DIR
SRV_BUILD="$SRV_SRC_DIR/images/arch-base/build.sh"
BASE_SOURCE_DIR="${BASE_SOURCE_DIR:-$SRV_IMAGES_DIR/arch-base/work/linux-6.12.79}"
OUTPUT_DIR="${OUTPUT_DIR:-$SRV_IMAGES_DIR/mobile-kernel}"
FRAGMENT="$HERE/mobile.config"
PATCH_DIR="$HERE/patches"
LOCALVERSION_SUFFIX=-mobile

[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f $BASE_SOURCE_DIR/.config && -f $BASE_SOURCE_DIR/Makefile ]] || { echo "$BASE_SOURCE_DIR is not a configured kernel tree" >&2; exit 1; }
[[ -f $SRV_BUILD ]] || { echo "srv build script not found at $SRV_BUILD (set SRV_SRC_DIR in site.env)" >&2; exit 1; }

src="$OUTPUT_DIR/work/$(basename "$BASE_SOURCE_DIR")"
config="$src/.config"
install -d -m 0755 "$OUTPUT_DIR" "$OUTPUT_DIR/work"
if [[ ! -f $src/Makefile ]]; then
	rm -rf "$src"
	# Reflink keeps srv's built objects, so the first build is incremental.
	cp -a --reflink=auto "$BASE_SOURCE_DIR" "$src.tmp"
	mv "$src.tmp" "$src"
fi

# Apply patches/*.patch to the work tree. Reruns find them already applied;
# a patch that neither applies nor reverses cleanly fails the build.
mapfile -t patches < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -type f | sort)
for p in "${patches[@]}"; do
	if git -C "$src" apply --check -R "$p" 2>/dev/null; then
		echo "patch already applied: $(basename "$p")"
	elif git -C "$src" apply --check "$p"; then
		git -C "$src" apply "$p"
		echo "applied patch: $(basename "$p")"
	else
		echo "patch $(basename "$p") neither applies nor is already applied to $src" >&2
		exit 1
	fi
done

# Same parallelism rule as srv: one job per ~2 GiB of available RAM, capped at nproc.
jobs="${KERNEL_JOBS:-}"
if [[ -z $jobs ]]; then
	mem_jobs=$(( $(awk '/MemAvailable:/ { print $2; exit }' /proc/meminfo) / 2097152 ))
	jobs=$(nproc)
	(( mem_jobs >= 1 && mem_jobs < jobs )) && jobs=$mem_jobs
fi

# Always start from srv's config so reruns are reproducible.
cp "$BASE_SOURCE_DIR/.config" "$src/.config.srv"
KCONFIG_CONFIG="$config" "$src/scripts/kconfig/merge_config.sh" -m -O "$src" "$src/.config.srv" "$FRAGMENT"
make -C "$src" KCONFIG_CONFIG="$config" olddefconfig

# Every option the fragment requests must survive olddefconfig.
failed=0
while IFS= read -r line; do
	if [[ $line =~ ^(CONFIG_[A-Za-z0-9_]+)= ]] || [[ $line =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
		if ! grep -qxF -- "$line" "$config"; then
			echo "kernel config lost '$line' (have: $(grep -E "(^|# )${BASH_REMATCH[1]}[= ]" "$config" || echo unset))" >&2
			failed=1
		fi
	fi
done < "$FRAGMENT"
# srv's own requirements (validate_kernel_config in its build.sh) still hold.
mapfile -t srv_required < <(grep -oP "require_kernel_config \"\\$\\{kernel_config\\}\" '\\K[^']+" "$SRV_BUILD")
(( ${#srv_required[@]} > 20 )) || { echo "could not parse srv's validate_kernel_config list from $SRV_BUILD" >&2; exit 1; }
for pattern in "${srv_required[@]}"; do
	grep -Eq "^${pattern}$" "$config" || { echo "kernel config is missing srv requirement $pattern" >&2; failed=1; }
done
(( failed == 0 )) || exit 1

# kernelrelease reads include/config/kernel.release, which may still hold srv's value.
make -s -C "$src" KCONFIG_CONFIG="$config" include/config/kernel.release
release="$(make -s -C "$src" KCONFIG_CONFIG="$config" kernelrelease)"
[[ $release == *"$LOCALVERSION_SUFFIX" ]] || { echo "kernel release $release does not end in $LOCALVERSION_SUFFIX" >&2; exit 1; }
echo "building $release with $jobs job(s)"
make -C "$src" KCONFIG_CONFIG="$config" -j"$jobs" vmlinux modules
# The built-in ashmem driver (patches/0001) must be linked into vmlinux.
grep -qw ashmem_init "$src/System.map" || { echo "vmlinux lacks the ashmem driver (ashmem_init not in System.map)" >&2; exit 1; }

staging="$OUTPUT_DIR/modules.new"
rm -rf "$staging"
make -C "$src" KCONFIG_CONFIG="$config" INSTALL_MOD_PATH="$staging" INSTALL_MOD_STRIP=1 modules_install
depmod -b "$staging" "$release"
mod_tree="$staging/lib/modules/$release"
rm -f "$mod_tree/build" "$mod_tree/source"
[[ -n "$(find "$mod_tree" -type f -name '*.ko*' -print -quit)" ]] || { echo "no modules built for $release" >&2; exit 1; }
# Docker's modules-load.d (overlay, br_netfilter) must be loadable.
for mod in overlay br_netfilter veth bridge; do
	modinfo -b "$staging" -k "$release" "$mod" >/dev/null || { echo "module $mod missing from $release" >&2; exit 1; }
done

install -m 0644 "$src/vmlinux" "$OUTPUT_DIR/vmlinux.new"
install -m 0644 "$config" "$OUTPUT_DIR/config.new"
rm -rf "$OUTPUT_DIR/modules.old"
[[ -d $OUTPUT_DIR/modules ]] && mv "$OUTPUT_DIR/modules" "$OUTPUT_DIR/modules.old"
install -d -m 0755 "$OUTPUT_DIR/modules"
mv "$mod_tree" "$OUTPUT_DIR/modules/$release"
rm -rf "$staging" "$OUTPUT_DIR/modules.old"
chown -R 0:0 "$OUTPUT_DIR/modules"
chmod -R u=rwX,go=rX "$OUTPUT_DIR/modules"
mv "$OUTPUT_DIR/vmlinux.new" "$OUTPUT_DIR/vmlinux"
mv "$OUTPUT_DIR/config.new" "$OUTPUT_DIR/config"
echo "$release" > "$OUTPUT_DIR/release"
{
	echo "built_at=$(date --iso-8601=seconds)"
	echo "kernel_release=$release"
	echo "base_source=$BASE_SOURCE_DIR"
	echo "fragment_sha256=$(sha256sum "$FRAGMENT" | cut -d' ' -f1)"
	for p in "${patches[@]}"; do
		echo "patch=$(basename "$p") sha256=$(sha256sum "$p" | cut -d' ' -f1)"
	done
} > "$OUTPUT_DIR/manifest.txt"
chmod 0644 "$OUTPUT_DIR/release" "$OUTPUT_DIR/manifest.txt"
echo "built $OUTPUT_DIR/vmlinux ($release)"
