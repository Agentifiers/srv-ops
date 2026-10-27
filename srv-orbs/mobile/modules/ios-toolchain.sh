#!/usr/bin/env bash
# ios-toolchain: everything to build, sign and run iOS apps from the orb except
# Apple's SDK (ios-sdk.sh adds that from the Xcode .xip).
#
#   /opt/swift              swift.org Swift (Ubuntu 24.04 build) + Arch curses aliases
#   /opt/xtool              xtool, omarchy-apple-dev's fork built from source (see XTOOL_*)
#   /opt/pymobiledevice3    venv on Arch's Python 3.14 (TLS-PSK for RemotePairing)
#   /opt/omarchy-apple-dev  pinned checkout + local patches; Linux actool built in
#                           tools/darwin-tools/bin/actool
#   /opt/rcodesign          rcodesign (sign-dev.sh, xtool-free signing)
#   /opt/mobile-shims/bin   xcrun/xcodebuild/plutil/otool/... stand-ins; NOT on PATH.
#                           expo-ios and `with-mobile-shims CMD` prepend it.
#   CocoaPods + xcodeproj   system gems (Ruby 3.4), binstubs in /usr/local/bin
#
# Runs on the host as root with MNT, CACHE and HERE set (see ../README contract).
set -euo pipefail
umask 022
: "${MNT:?}" "${CACHE:?}" "${HERE:?}"

D="$HERE/modules/ios-toolchain.d"
C="$CACHE/ios-toolchain"

SWIFT_VERSION=6.4.1
SWIFT_TARBALL=swift-$SWIFT_VERSION-RELEASE-ubuntu24.04.tar.gz
SWIFT_URL=https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/$SWIFT_TARBALL
# Signature checked against https://swift.org/keys/all-keys.asc (key EF80A866B47A981F) when pinned.
SWIFT_SHA256=7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b

# xtool: omarchy-apple-dev's fork (1.23.0 + unreleased fixes for dynamic package
# products, extension dylibs, swiftbuild dylib runtime search paths and the SDK
# stamp its darwin-tools/OpenAppleMacros expect), the exact commit
# install-toolchain.sh pins, plus upstream's 1.24 Apple ID login fix (#406) as a
# local patch. Upstream's AppImage lacks those fixes, and omarchy's Flutter lane,
# SDK stamp checks and signing flow are tested against this build.
XTOOL_SHA=f300489f3a3fddbd9fb598ba6cf69eb24a494527
XTOOL_SHA256=f2610dc1758534dbc826ddb26035e01dc789947f69aa1ff6d1dd3bdd3a458ef5

OMARCHY_SHA=ceda63aa6ff04fc2e550a7c6a7eb13aa6cacd4de
OMARCHY_SHA256=d72906aa7a5f7f15263bb2bc340bb9aa98c50d7af50cb6c09eb5401f99a03456

RCODESIGN_VERSION=0.29.0
RCODESIGN_SHA256=dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002

PMD3_VERSION=11.45.0          # with every dependency hash-pinned in ios-toolchain.d/pymobiledevice3.requirements.txt
COCOAPODS_VERSION=1.17.0      # closure hash-pinned in ios-toolchain.d/cocoapods.gems.lock
XCODEPROJ_VERSION=1.28.1

PACKAGES=(
	# swift.org toolchain on Arch: libxml2.so.2 (libxml2-legacy), wide curses (patchelf below)
	libxml2-legacy ncurses patchelf python git base-devel
	# xtool build deps (omarchy install-toolchain.sh step 1) and actool's PDF/HEIC paths
	libimobiledevice openssl zip unzip poppler libheif
	# Mach-O tools behind the shims (llvm-otool, llvm-lipo, ...), ld64.lld, file, rsync
	llvm lld file rsync
	# CocoaPods as a metadata tool (pod ipc spec): Arch splits erb and bigdecimal out of ruby
	ruby ruby-erb ruby-bigdecimal
	# omarchy tools that import cryptography under the system python
	python-cryptography
)

log() { echo "[ios-toolchain] $*"; }
die() { echo "[ios-toolchain] ERROR: $*" >&2; exit 1; }
# arch-chroot runs commands in a new PID namespace but leaves the host's /proc
# mounted, so /proc/<own pid> is some other process. Swift's runtime reads it
# and Swift programs (swift-package, xtool) die with SIGILL at random points.
# A nested PID namespace with its own /proc fixes that.
chroot_run() { arch-chroot "$MNT" unshare --fork --pid --mount-proc "$@"; }
# A clean login shell, as an orb shell gets it: /etc/profile.d applies, host env does not leak.
as_user() {
	chroot_run runuser -u user -- env -i HOME=/home/user USER=user LOGNAME=user SHELL=/bin/bash \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/bin bash -lc 'cd ~ && "$@"' as_user "$@"
}

# fetch URL FILE SHA256: download once into $C, verified.
fetch() {
	local url=$1 file=$C/$2 sha=$3
	if [[ -f $file ]] && echo "$sha  $file" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
	log "downloading $url"
	curl -fsSL --retry 3 -o "$file.part" "$url"
	echo "$sha  $file.part" | sha256sum -c --quiet - || die "sha256 mismatch for $url"
	mv "$file.part" "$file"
}

install -d -m 0755 "$C" "$C/gems" "$C/pip"
# One run at a time per cache (orb and test images may build concurrently).
exec 9>"$C/.lock"
flock 9
# The cache is visible inside the chroot here while the module runs.
GUEST_CACHE=/var/tmp/ios-toolchain-cache
GUEST_BUILD=/var/tmp/ios-toolchain-build
cleanup() {
	local status=$?
	if mountpoint -q "$MNT$GUEST_CACHE"; then umount "$MNT$GUEST_CACHE"; fi
	rmdir "$MNT$GUEST_CACHE" 2>/dev/null || true
	rm -rf "$MNT$GUEST_BUILD"
	exit "$status"
}
trap cleanup EXIT
install -d "$MNT$GUEST_CACHE"
mountpoint -q "$MNT$GUEST_CACHE" || mount --bind "$C" "$MNT$GUEST_CACHE"
rm -rf "$MNT$GUEST_BUILD"
install -d "$MNT$GUEST_BUILD"

user_uid=$(chroot_run id -u user) || die "image has no user account"
user_gid=$(chroot_run id -g user)

log "packages"
chroot_run pacman -Sy --needed --noconfirm "${PACKAGES[@]}" >/dev/null 2>&1 || chroot_run pacman -S --needed --noconfirm "${PACKAGES[@]}"

# ---------------------------------------------------------------- Swift
fetch "$SWIFT_URL" "$SWIFT_TARBALL" "$SWIFT_SHA256"
if [[ $(cat "$MNT/opt/swift/.srv-mobile-version" 2>/dev/null) != "$SWIFT_TARBALL $SWIFT_SHA256" ]]; then
	log "Swift $SWIFT_VERSION -> /opt/swift"
	rm -rf "$MNT/opt/swift"
	install -d "$MNT/opt/swift"
	tar -xzf "$C/$SWIFT_TARBALL" -C "$MNT/opt/swift" --strip-components=1 --no-same-owner
	echo "$SWIFT_TARBALL $SWIFT_SHA256" > "$MNT/opt/swift/.srv-mobile-version"
fi
# The Ubuntu build links the narrow curses sonames (libncurses.so.6, libpanel.so.6,
# ...); Arch ships ncurses wide-only (omarchy-apple-dev FINDINGS.md 21). Point the
# toolchain's ELF files at the wide libraries, as Arch's swift-bin package does:
# unlike aliases or LD_LIBRARY_PATH this also holds for swift-build-tool (no
# RUNPATH) and for tools SwiftBuild runs with a scrubbed environment.
# lldb is left alone and unsupported: it needs versioned narrow-curses symbols,
# libedit.so.2 and libpython3.12, none of which Arch packages.
chroot_run bash -euo pipefail -c '
	find /opt/swift/usr -type f \( -perm -u+x -o -name "*.so*" \) ! -name "*lldb*" -print0 |
	while IFS= read -r -d "" f; do
		needed=$(patchelf --print-needed "$f" 2>/dev/null) || continue
		for stem in ncurses form panel menu; do
			if grep -qx "lib$stem.so.6" <<<"$needed"; then
				patchelf --replace-needed "lib$stem.so.6" "lib${stem}w.so.6" "$f"
			fi
		done
	done'
# Every other toolchain binary and library must resolve. lib_InternalSwiftScan.so
# is only ever dlopen()ed by the driver, which has libswiftCore loaded already.
unresolved=$(chroot_run bash -c '
	{ find /opt/swift/usr/bin -type f -perm -u+x; find /opt/swift/usr/lib -name "*.so*" -type f; } |
	grep -v -e lldb -e lib_InternalSwiftScan.so |
	while read -r f; do ldd "$f" 2>&1 | grep -E "not found" | sed "s|^|$f: |" || true; done')
[[ -z $unresolved ]] || die "unresolved toolchain libraries:"$'\n'"$unresolved"
for bin in "$MNT"/opt/swift/usr/bin/swift*; do
	name=$(basename "$bin")
	[[ -x $bin && ! -d $bin ]] || continue
	ln -sfn "/opt/swift/usr/bin/$name" "$MNT/usr/local/bin/$name"
done
ln -sfn /opt/swift/usr/bin/sourcekit-lsp "$MNT/usr/local/bin/sourcekit-lsp"

# guest_swift_build DIR ARGS...: `swift build` in the chroot, logged next to DIR.
guest_swift_build() {
	local dir=$1
	shift
	if ! chroot_run bash -c 'cd "$1" && shift && swift build --cache-path "$0" "$@"' \
		"$GUEST_BUILD/swiftpm-cache" "$dir" "$@" > "$MNT$dir.build.log" 2>&1; then
		grep -E 'error:|Program crashed' "$MNT$dir.build.log" | head -20 >&2 || true
		tail -5 "$MNT$dir.build.log" >&2
		die "swift build in $dir failed"
	fi
}

# ---------------------------------------------------------------- xtool
fetch "https://codeload.github.com/joshuaswarren/xtool/tar.gz/$XTOOL_SHA" "xtool-$XTOOL_SHA.tar.gz" "$XTOOL_SHA256"
xtool_patch_sum=$(cat "$D"/patches/xtool/*.patch | sha256sum | cut -c1-12)
xtool_build=xtool-build-$XTOOL_SHA-p$xtool_patch_sum-swift$SWIFT_VERSION.tar.gz
if [[ ! -f $C/$xtool_build ]]; then
	log "building xtool $XTOOL_SHA (several minutes)"
	src=$MNT$GUEST_BUILD/xtool
	install -d "$src"
	tar -xzf "$C/xtool-$XTOOL_SHA.tar.gz" -C "$src" --strip-components=1 --no-same-owner
	for p in "$D"/patches/xtool/*.patch; do patch -p1 -s -d "$src" < "$p"; done
	guest_swift_build "$GUEST_BUILD/xtool" -c release --product xtool -Xswiftc -no-toolchain-stdlib-rpath
	chroot_run bash -euo pipefail -c "
		cd $GUEST_BUILD/xtool
		bin=\$(swift build -c release --show-bin-path)
		out=$GUEST_BUILD/xtool-out
		install -d \$out
		install -m755 \$bin/xtool \$out/
		# Its Swift runtime libraries go next to it (\$ORIGIN), as omarchy installs it.
		rt=/opt/swift/usr/lib/swift/linux
		LD_LIBRARY_PATH=\$rt ldd \$out/xtool | awk -v rt=\$rt/ 'index(\$3, rt) == 1 { print \$3 }' |
			xargs -r install -m644 -t \$out
		tar -czf $GUEST_CACHE/$xtool_build.part -C \$out .
	"
	mv "$C/$xtool_build.part" "$C/$xtool_build"
fi
rm -rf "$MNT/opt/xtool"
install -d "$MNT/opt/xtool"
tar -xzf "$C/$xtool_build" -C "$MNT/opt/xtool" --no-same-owner
ln -sfn /opt/xtool/xtool "$MNT/usr/local/bin/xtool"

# ---------------------------------------------------------------- omarchy-apple-dev
fetch "https://codeload.github.com/joshuaswarren/omarchy-apple-dev/tar.gz/$OMARCHY_SHA" \
	"omarchy-apple-dev-$OMARCHY_SHA.tar.gz" "$OMARCHY_SHA256"
log "omarchy-apple-dev $OMARCHY_SHA -> /opt/omarchy-apple-dev"
rm -rf "$MNT/opt/omarchy-apple-dev"
install -d "$MNT/opt/omarchy-apple-dev"
tar -xzf "$C/omarchy-apple-dev-$OMARCHY_SHA.tar.gz" -C "$MNT/opt/omarchy-apple-dev" --strip-components=1 --no-same-owner
for p in "$D"/patches/omarchy-apple-dev/*.patch; do
	patch -p1 -s -d "$MNT/opt/omarchy-apple-dev" < "$p" || die "patch $p failed"
done
omarchy_patch_sum=$(cat "$D"/patches/omarchy-apple-dev/*.patch | sha256sum | cut -c1-12)
echo "$OMARCHY_SHA local-patches=$omarchy_patch_sum" > "$MNT/opt/omarchy-apple-dev/.srv-mobile-version"

# Linux actool (AssetKit), built once per omarchy commit and Swift version.
actool_build=omarchy-actool-$OMARCHY_SHA-swift$SWIFT_VERSION.tar.gz
if [[ ! -f $C/$actool_build ]]; then
	log "building omarchy darwin-tools actool"
	cp -a "$MNT/opt/omarchy-apple-dev/tools/darwin-tools" "$MNT$GUEST_BUILD/darwin-tools"
	guest_swift_build "$GUEST_BUILD/darwin-tools" -c release --product actool
	chroot_run bash -euo pipefail -c "
		cd $GUEST_BUILD/darwin-tools
		tar -czf $GUEST_CACHE/$actool_build.part -C \$(swift build -c release --show-bin-path) actool
	"
	mv "$C/$actool_build.part" "$C/$actool_build"
fi
install -d "$MNT/opt/omarchy-apple-dev/tools/darwin-tools/bin"
tar -xzf "$C/$actool_build" -C "$MNT/opt/omarchy-apple-dev/tools/darwin-tools/bin" --no-same-owner

# ---------------------------------------------------------------- rcodesign
rcs=apple-codesign-$RCODESIGN_VERSION-x86_64-unknown-linux-musl
fetch "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F$RCODESIGN_VERSION/$rcs.tar.gz" \
	"$rcs.tar.gz" "$RCODESIGN_SHA256"
install -d "$MNT/opt/rcodesign/bin"
tar -xzf "$C/$rcs.tar.gz" -C "$MNT/opt/rcodesign/bin" --strip-components=1 --no-same-owner "$rcs/rcodesign"
ln -sfn /opt/rcodesign/bin/rcodesign "$MNT/usr/local/bin/rcodesign"

# ---------------------------------------------------------------- pymobiledevice3
# System Python 3.14: RemotePairing needs TLS-PSK, which uv's standalone builds lack.
py_version=$(chroot_run python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
if [[ $(cat "$MNT/opt/pymobiledevice3/.srv-mobile-version" 2>/dev/null) != "$PMD3_VERSION py$py_version $(sha256sum < "$D/pymobiledevice3.requirements.txt" | cut -c1-12)" ]]; then
	log "pymobiledevice3 $PMD3_VERSION -> /opt/pymobiledevice3"
	rm -rf "$MNT/opt/pymobiledevice3"
	install -m644 "$D/pymobiledevice3.requirements.txt" "$MNT$GUEST_BUILD/pmd3.txt"
	chroot_run bash -euo pipefail -c "
		python3 -m venv /opt/pymobiledevice3
		/opt/pymobiledevice3/bin/pip install --quiet --disable-pip-version-check --cache-dir $GUEST_CACHE/pip \
			--require-hashes --no-deps -r $GUEST_BUILD/pmd3.txt
		/opt/pymobiledevice3/bin/python -c 'import ssl, pymobiledevice3; assert hasattr(ssl.SSLContext, \"set_psk_client_callback\"), \"no TLS-PSK\"'
	"
	echo "$PMD3_VERSION py$py_version $(sha256sum < "$D/pymobiledevice3.requirements.txt" | cut -c1-12)" \
		> "$MNT/opt/pymobiledevice3/.srv-mobile-version"
fi
ln -sfn /opt/pymobiledevice3/bin/pymobiledevice3 "$MNT/usr/local/bin/pymobiledevice3"

# Entry points for the omarchy tools. Python tools that import pymobiledevice3
# run on its venv; shell tools find xtool/pymobiledevice3/rcodesign on PATH.
wrapper() { # name command...
	local name=$1
	shift
	printf '#!/bin/sh\nexec %s "$@"\n' "$*" > "$MNT/usr/local/bin/$name"
	chmod 0755 "$MNT/usr/local/bin/$name"
}
O=/opt/omarchy-apple-dev
wrapper tailnet-tunnel /opt/pymobiledevice3/bin/python "$O/tools/tailnet-tunnel.py"
wrapper provision-dev /opt/pymobiledevice3/bin/python "$O/tools/provision-dev.py"
wrapper asc /opt/pymobiledevice3/bin/python "$O/tools/asc.py"
wrapper sign-dev "$O/tools/sign-dev.sh"
wrapper device-run "$O/device-run.sh"
wrapper macho-lint python3 "$O/tools/macho-lint.py"

# ---------------------------------------------------------------- CocoaPods
gems=()
while read -r file sha; do
	[[ -z $file || $file == \#* ]] && continue
	fetch "https://rubygems.org/downloads/$file" "gems/$file" "$sha"
	gems+=("$GUEST_CACHE/gems/$file")
done < "$D/cocoapods.gems.lock"
if ! chroot_run gem list -i cocoapods -v "$COCOAPODS_VERSION" >/dev/null || ! chroot_run gem list -i xcodeproj -v "$XCODEPROJ_VERSION" >/dev/null; then
	log "CocoaPods $COCOAPODS_VERSION, xcodeproj $XCODEPROJ_VERSION"
	# Local .gem files only (hash-checked above); system gem dir, binstubs in /usr/local/bin.
	chroot_run env LANG=C.UTF-8 gem install --local --no-user-install --no-document --ignore-dependencies \
		--bindir /usr/local/bin "${gems[@]}" >/dev/null
fi

# ---------------------------------------------------------------- shims
S=/opt/mobile-shims/bin
rm -rf "$MNT/opt/mobile-shims"
install -d "$MNT$S"
install -m755 "$D"/shims/* "$MNT$S/"
# omarchy's Flutter-lane shims (llvm forwarding + Mach-O layout repair) as they are.
for t in otool lipo strip install_name_tool codesign dsymutil ld; do
	ln -sfn "$O/flutter/shims/$t" "$MNT$S/$t"
done
# Apple's resource compilers' Linux stand-ins.
ln -sfn "$O/tools/darwin-tools/bin/actool" "$MNT$S/actool"
for t in ibtool xcstringstool momc; do ln -sfn "$O/tools/$t" "$MNT$S/$t"; done
install -m755 "$D/with-mobile-shims" "$MNT/usr/local/bin/with-mobile-shims"

# ---------------------------------------------------------------- environment
env_vars=(
	MOBILE_SHIMS_BIN=$S
	DARWIN_SDK_BUNDLE=/opt/swift-sdks/darwin.artifactbundle
	OMARCHY_APPLE_DEV=$O
	XTOOL=/opt/xtool/xtool
	LANG=C.UTF-8
)
install -d "$MNT/etc/systemd/system.conf.d"
printf '[Manager]\nDefaultEnvironment=%s\n' "${env_vars[*]}" > "$MNT/etc/systemd/system.conf.d/mobile-ios-toolchain.conf"
{
	echo "# ios-toolchain (srv-orbs/mobile). LANG: CocoaPods and Swift need a UTF-8 locale."
	for kv in "${env_vars[@]}"; do
		if [[ $kv == LANG=* ]]; then echo ": \"\${LANG:=${kv#LANG=}}\"; export LANG"; else echo "export $kv"; fi
	done
} > "$MNT/etc/profile.d/mobile-ios-toolchain.sh"

# Compatibility with omarchy scripts that hard-code ~/pymobile3-venv (flutter/ship.sh).
ln -sfn /opt/pymobiledevice3 "$MNT/home/user/pymobile3-venv"
chown -h "$user_uid:$user_gid" "$MNT/home/user/pymobile3-venv"

# Skill.
skill_dir=/home/user/.config/agents/skills/ios-toolchain
for dir in /home/user/.config /home/user/.config/agents /home/user/.config/agents/skills "$skill_dir"; do
	install -d -m 0755 -o "$user_uid" -g "$user_gid" "$MNT$dir"
done
install -m 0644 -o "$user_uid" -g "$user_gid" "$D/SKILL.md" "$MNT$skill_dir/SKILL.md"

# ---------------------------------------------------------------- verify (as user)
log "verifying"
# The checks run as user in ~; afterwards drop whatever they left in it (caches).
home_before=$(mktemp)
chroot_run find /home/user -xdev -mindepth 1 | sort > "$home_before"
swift_v=$(as_user swift --version 2>&1 | head -1)
[[ $swift_v == *"Swift version $SWIFT_VERSION"* ]] || die "swift --version: $swift_v"
as_user xtool --help >/dev/null || die "xtool --help failed"
xtool_v=$(as_user xtool --version 2>&1 | head -1)
pmd3_v=$(as_user pymobiledevice3 version 2>/dev/null | tail -1)
[[ $pmd3_v == *"$PMD3_VERSION"* ]] || die "pymobiledevice3 version: $pmd3_v"
pod_v=$(as_user pod --version)
[[ $pod_v == "$COCOAPODS_VERSION" ]] || die "pod --version: $pod_v"
as_user ruby -e "require 'xcodeproj'; exit(Xcodeproj::VERSION == '$XCODEPROJ_VERSION')" || die "xcodeproj gem"
as_user rcodesign --version >/dev/null || die "rcodesign"
as_user /opt/omarchy-apple-dev/tools/darwin-tools/bin/actool --version >/dev/null 2>&1 ||
	as_user /opt/omarchy-apple-dev/tools/darwin-tools/bin/actool --help >/dev/null 2>&1 || die "actool"
as_user tailnet-tunnel --help >/dev/null || die "tailnet-tunnel --help"
as_user with-mobile-shims bash -euo pipefail -c '
	[ "$(command -v xcrun)" = "$MOBILE_SHIMS_BIN/xcrun" ]
	xcodebuild -version | grep -q "^Xcode "
	"$MOBILE_SHIMS_BIN/command" -v sh >/dev/null
	printf "{\"a\":{\"b\":[1,\"x\"]}}" > /tmp/plutil-check.json
	plutil -convert xml1 -o /tmp/plutil-check.plist /tmp/plutil-check.json
	[ "$(plutil -convert json -o - /tmp/plutil-check.plist)" = "{\"a\":{\"b\":[1,\"x\"]}}" ]
	[ "$(plutil -extract a.b.1 raw -o - /tmp/plutil-check.plist)" = x ]
	rm -f /tmp/plutil-check.json /tmp/plutil-check.plist
	xcrun otool --version | grep LLVM >/dev/null
	otool --version >/dev/null
	echo "int f(void){return 1;}" > /tmp/xcrun-check.c
	xcrun clang -dynamiclib -o /tmp/xcrun-check.dylib /tmp/xcrun-check.c
	llvm-otool -hv /tmp/xcrun-check.dylib | grep -q ARM64
	rm -f /tmp/xcrun-check.c /tmp/xcrun-check.dylib
	ibtool --version >/dev/null 2>&1 || ibtool --help >/dev/null 2>&1
' || die "shim checks failed"

chroot_run find /home/user -xdev -mindepth 1 | sort | comm -13 "$home_before" - | while read -r p; do
	[[ ! -e $MNT$p && ! -L $MNT$p ]] || rm -rf "$MNT$p"
done
rm -f "$home_before"

touch "$MNT/etc/amp-orb-mobile.manifest"
sed -i -E '/^(swift|xtool|pymobiledevice3|omarchy_apple_dev|rcodesign|cocoapods|llvm)=/d' "$MNT/etc/amp-orb-mobile.manifest"
{
	echo "swift=$SWIFT_VERSION ($SWIFT_TARBALL)"
	echo "xtool=$xtool_v (joshuaswarren/xtool@$XTOOL_SHA + patches $xtool_patch_sum)"
	echo "pymobiledevice3=$PMD3_VERSION (python $py_version)"
	echo "omarchy_apple_dev=$OMARCHY_SHA (patches $omarchy_patch_sum)"
	echo "rcodesign=$RCODESIGN_VERSION"
	echo "cocoapods=$pod_v xcodeproj=$XCODEPROJ_VERSION ruby=$(chroot_run ruby -e 'print RUBY_VERSION')"
	echo "llvm=$(chroot_run pacman -Q llvm | cut -d' ' -f2)"
} >> "$MNT/etc/amp-orb-mobile.manifest"
log "done"
