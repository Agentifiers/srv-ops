#!/usr/bin/env bash
# expo-ios: the `expo-ios` build tool (../expo-ios) — Expo SDK 58 / React Native 0.88
# iOS apps built in the orb through Expo's and React Native's SwiftPM path, with
# SwiftBuild and the Darwin SDK from ios-sdk.sh. No Xcode, no EAS.
#
#   /opt/expo-ios                  the tool, its overlays/ and patches/ (local only)
#   /usr/local/bin/expo-ios        -> /opt/expo-ios/bin/expo-ios
#   ~user/.config/agents/skills/expo-ios/SKILL.md
#
# Warm-up: builds the pinned template app in expo-ios.d/warmup (package-lock.json pins
# every npm package by sha512) as `user`, Release and, when the Darwin SDK is installed,
# compiled and assembled; Debug too. That verifies the module end to end and leaves the
# per-SDK caches in the image: npm's cache, React Native's SwiftPM artifacts
# (~/Library/Caches/ReactNative) and expo-ios' Linux prebuilds of @expo/ui, the
# dev-client modules and ExpoModulesJSI (~/.cache/expo-ios). Those caches are also kept
# in $CACHE/expo-ios so image rebuilds do not download them again.
#
# Runs on the host as root with MNT, CACHE and HERE set (see ../README.md contract).
# Needs ios-toolchain (swift, pod, shims, omarchy-apple-dev) first; ios-sdk optional.
set -euo pipefail
umask 022
: "${MNT:?}" "${CACHE:?}" "${HERE:?}"

D="$HERE/modules/expo-ios.d"
C="$CACHE/expo-ios"

log() { echo "[expo-ios] $*"; }
die() { echo "[expo-ios] ERROR: $*" >&2; exit 1; }
# Own PID namespace + /proc: under plain arch-chroot Swift programs read another
# process's /proc entry and die with SIGILL (see ios-toolchain.sh).
chroot_run() { arch-chroot "$MNT" unshare --fork --pid --mount-proc "$@"; }
# A clean login shell, as an orb shell gets it: /etc/profile.d applies, host env does not leak.
as_user() {
	chroot_run runuser -u user -- env -i HOME=/home/user USER=user LOGNAME=user SHELL=/bin/bash \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/bin bash -lc 'cd ~ && "$@"' as_user "$@"
}

PACKAGES=(nodejs npm python zip unzip patch rsync llvm file)

for p in /usr/local/bin/swift /usr/local/bin/pod /opt/omarchy-apple-dev/tools/ibtool; do
	# Checked inside the chroot: these are absolute symlinks into the image.
	chroot_run test -e "$p" || die "$p missing: run ios-toolchain first"
done
chroot_run pacman -S --needed --noconfirm "${PACKAGES[@]}" >/dev/null

# ---------------------------------------------------------------- install
log "installing /opt/expo-ios"
rm -rf "$MNT/opt/expo-ios"
install -d -m 0755 "$MNT/opt/expo-ios"
cp -r --no-preserve=ownership,mode "$HERE/expo-ios/." "$MNT/opt/expo-ios/"
chmod -R u=rwX,go=rX "$MNT/opt/expo-ios"
chmod 0755 "$MNT/opt/expo-ios/bin/expo-ios" "$MNT/opt/expo-ios/lib/"*.py
find "$MNT/opt/expo-ios/hooks" -type f -exec chmod 0755 {} + 2>/dev/null || true
ln -sfn /opt/expo-ios/bin/expo-ios "$MNT/usr/local/bin/expo-ios"
version=$(cd "$HERE/expo-ios" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)

user_uid=$(chroot_run id -u user)
user_gid=$(chroot_run id -g user)
skill_dir=/home/user/.config/agents/skills/expo-ios
for dir in /home/user/.config /home/user/.config/agents /home/user/.config/agents/skills "$skill_dir"; do
	install -d -m 0755 -o "$user_uid" -g "$user_gid" "$MNT$dir"
done
install -m 0644 -o "$user_uid" -g "$user_gid" "$D/SKILL.md" "$MNT$skill_dir/SKILL.md"

# ---------------------------------------------------------------- verify the tool
log "verifying the CLI"
as_user bash -euo pipefail -c '
	for f in /opt/expo-ios/lib/*.mjs; do node --check "$f"; done
	for f in /opt/expo-ios/lib/*.py; do python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$f"; done
	expo-ios stages | grep -qx package
	expo-ios --help | grep -q "expo-ios build"
' || die "expo-ios CLI checks failed"

# ---------------------------------------------------------------- warm-up build
# Caches restored from (and saved back to) $CACHE: user-owned trees in the image.
CACHES=(.npm Library/Caches/ReactNative .cache/expo-ios/precompiled .cache/expo-ios/jsi)
install -d -m 0755 "$C"
exec 9>"$C/.lock"
flock 9
for rel in "${CACHES[@]}"; do
	tarball=$C/$(echo "$rel" | tr / _).tar.zst
	[[ -f $tarball ]] || continue
	install -d -o "$user_uid" -g "$user_gid" "$MNT/home/user/$rel"
	tar --zstd -xf "$tarball" -C "$MNT/home/user/$rel" --same-owner
	chown -R "$user_uid:$user_gid" "$MNT/home/user/$rel"
done
# Parents created as root above stay user-owned.
for dir in /home/user/Library /home/user/Library/Caches /home/user/.cache /home/user/.cache/expo-ios; do
	[[ -d $MNT$dir ]] && chown "$user_uid:$user_gid" "$MNT$dir"
done

# SwiftPM (manifest cache in ~/.cache/org.swift.swiftpm) and npm write under ~/.cache as
# user; earlier root steps can leave it, or parts of it, root-owned.
install -d -o "$user_uid" -g "$user_gid" "$MNT/home/user/.cache"
chown -R "$user_uid:$user_gid" "$MNT/home/user/.cache"

warm=/home/user/.cache/expo-ios-warmup
rm -rf "$MNT$warm"
install -d -o "$user_uid" -g "$user_gid" "$MNT$warm"
cp -r --no-preserve=ownership "$D/warmup/." "$MNT$warm/"
chown -R "$user_uid:$user_gid" "$MNT$warm"
log "warm-up: npm ci"
as_user bash -c "cd $warm && npm ci --no-audit --no-fund" > "$C/warmup-npm.log" 2>&1 || { tail -20 "$C/warmup-npm.log" >&2; die "npm ci failed"; }

sdk=no
[[ -f $MNT/opt/swift-sdks/darwin.artifactbundle/toolset-swb.json ]] && sdk=yes
results=()
# Full builds (compile, link, assemble, closure check, package) for the configurations in
# EXPO_IOS_WARM_COMPILE (default "Release Debug"; "" = none); the others, and every
# configuration when the Darwin SDK is missing, run only the stages that need no compiler.
compile_configs=" ${EXPO_IOS_WARM_COMPILE-Release Debug} "
for configuration in Release Debug; do
	if [[ $sdk == yes && $compile_configs == *" $configuration "* ]]; then
		log "warm-up: expo-ios build --configuration $configuration"
		as_user bash -c "cd $warm && expo-ios build --configuration $configuration" > "$C/warmup-$configuration.log" 2>&1 ||
			{ tail -40 "$C/warmup-$configuration.log" >&2; die "warm-up $configuration build failed (log: $C/warmup-$configuration.log)"; }
		report=$MNT$warm/ios/build/expo-ios/$configuration/build.json
		[[ -f $report ]] || die "no build.json for $configuration"
		results+=("$configuration $(python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); c = r["closure"]; print("%ss, %d frameworks, closure %d images/%d symbols ok" % (r["totalSeconds"], len(r["frameworks"]), c["images"], c["imports"]))' "$report")")
	else
		# No Darwin SDK (no .xip yet): every stage that needs no compiler.
		log "warm-up ($configuration, no Darwin SDK): non-compile stages"
		as_user bash -c "cd $warm && expo-ios build --configuration $configuration --until graph && expo-ios build --configuration $configuration --only js,constants,resources,plist" \
			> "$C/warmup-$configuration.log" 2>&1 || { tail -40 "$C/warmup-$configuration.log" >&2; die "warm-up $configuration (non-compile) failed"; }
		results+=("$configuration non-compile only")
	fi
done

for rel in "${CACHES[@]}"; do
	[[ -d $MNT/home/user/$rel ]] || continue
	tarball=$C/$(echo "$rel" | tr / _).tar.zst
	tar --zstd -cf "$tarball.part" -C "$MNT/home/user/$rel" . && mv "$tarball.part" "$tarball"
done
# The warm-up project and its SwiftPM scratch are app specific; the caches stay.
rm -rf "$MNT$warm" "$MNT/home/user/.cache/expo-ios/scratch" "$MNT/home/user/.cache/expo-ios/prebuild-work" "$MNT/home/user/.cache/expo-ios/jsi-work"

touch "$MNT/etc/amp-orb-mobile.manifest"
sed -i -E '/^expo_ios=/d' "$MNT/etc/amp-orb-mobile.manifest"
echo "expo_ios=$version (expo $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencies"]["expo"])' "$D/warmup/package.json"), warm-up: $(IFS=';'; echo "${results[*]}"))" >> "$MNT/etc/amp-orb-mobile.manifest"
log "done: ${results[*]}"
