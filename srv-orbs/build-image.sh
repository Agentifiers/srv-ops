#!/usr/bin/env bash
# Builds the orb srv image (ORB_IMAGE, default `amp-orb`) as a thin layer on
# srv's native orb image (images/arch-base/build.sh with SRV_AMP_ORB=1): a
# reflink copy of its rootfs plus Tailscale via Amp workload identity (guest/)
# and common agent tooling. Reads AMP_WORKSPACE_ID, ORB_TAILSCALE_*, ORB_IMAGE
# and SRV_IMAGES_DIR from the repo's site.env.
#
#   sudo SRV_AMP_ORB=1 OUTPUT_DIR="$SRV_IMAGES_DIR/$ORB_IMAGE-base" \
#     "$SRV_SRC_DIR"/images/arch-base/build.sh
#   sudo ./build-image.sh
#
# Register the result in /etc/srv/images.json as $ORB_IMAGE with the base's
# vmlinux. Existing orbs keep their own disk; new orbs and snapshots-to-be
# pick up the rebuilt image.
set -euo pipefail
# srv (user srv) must be able to read and reflink the image.
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/site-env.sh
. "$HERE/../common/site-env.sh"
site_env_load AMP_WORKSPACE_ID ORB_TAILSCALE_CLIENT_ID ORB_TAILSCALE_AUDIENCE
tailscale_env="$(site_env_render "$HERE/guest/amp-orb-tailscale.env.example")"
BASE_DIR="${BASE_DIR:-$SRV_IMAGES_DIR/$ORB_IMAGE-base}"
OUTPUT_DIR="${OUTPUT_DIR:-$SRV_IMAGES_DIR/$ORB_IMAGE}"

# The orb base already has Amp, git, gh, Node.js, Python, tmux, ripgrep,
# OpenSSH, docker, go, gcc and the Desktop stack.
PACKAGES=(
	tailscale
	base-devel unzip zip wget lsof fzf
	npm pnpm yarn
	python-pip uv
	aws-cli-v2
	# Google Chrome's runtime libraries (installed by ../common/install-google-chrome.sh)
	# and Xvfb for headed browser tests outside the Wayland Desktop (xvfb-run).
	alsa-lib gtk3 libcups libxss libxtst nss ttf-liberation xdg-utils
	xorg-server-xvfb
)

# AWS SDK for JavaScript v3, installed globally. CommonJS require() finds it
# through NODE_PATH; ES module imports ignore NODE_PATH, so projects using
# import still declare it in package.json (installs then hit the npm cache).
AWS_SDK_PACKAGES=(
	@aws-sdk/client-s3 @aws-sdk/lib-storage @aws-sdk/s3-request-presigner
	@aws-sdk/client-dynamodb @aws-sdk/lib-dynamodb
	@aws-sdk/client-sqs @aws-sdk/client-sns @aws-sdk/client-lambda
	@aws-sdk/client-sts @aws-sdk/client-secrets-manager @aws-sdk/client-ssm
	@aws-sdk/client-cloudwatch-logs @aws-sdk/credential-providers
)

[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
grep -qx 'srv_amp_orb=1' "$BASE_DIR/manifest.txt" || { echo "$BASE_DIR is not an SRV_AMP_ORB=1 build" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
img="$OUTPUT_DIR/rootfs-base.img.new"
mnt="$(mktemp -d)"
udev_rule=/run/udev/rules.d/99-srv-image-no-automount.rules

cleanup() {
	local status=$?
	trap - EXIT
	# pacman-key can leave a gpg-agent running inside the rootfs, which keeps
	# the mount busy and leaves the image's journal unflushed.
	pkill -f "gpg-agent --homedir $mnt/" 2>/dev/null || true
	if mountpoint -q "$mnt"; then
		umount -R "$mnt" || { echo "failed to unmount $mnt; leaving it in place" >&2; exit 1; }
	fi
	rmdir "$mnt"
	rm -f "$udev_rule"
	udevadm control --reload
	[[ $status == 0 ]] || rm -f "$img"
	exit "$status"
}
trap cleanup EXIT

# Keep desktop automounters (udisks) off the loop device while we write to it.
mkdir -p "$(dirname "$udev_rule")"
echo 'KERNEL=="loop*", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"' > "$udev_rule"
udevadm control --reload

cp --reflink=always "$BASE_DIR/rootfs-base.img" "$img"
mount -o loop "$img" "$mnt"

# srv's arch-base build rsyncs its overlay with -a, so / and the overlay files
# inherit the checkout owner's UID (1000), which breaks pacman's tmpfiles hook.
# Hand anything owned by an unknown uid 1000 back to root.
chown 0:0 "$mnt"
if ! awk -F: '$3 == 1000 { found = 1 } END { exit !found }' "$mnt/etc/passwd"; then
	find "$mnt" -xdev \( -uid 1000 -o -gid 1000 \) -exec chown -h 0:0 {} +
fi

arch-chroot "$mnt" pacman -Sy --needed --noconfirm "${PACKAGES[@]}"
arch-chroot "$mnt" npm install -g --no-fund --no-audit "${AWS_SDK_PACKAGES[@]}"
echo 'export NODE_PATH=/usr/lib/node_modules' > "$mnt/etc/profile.d/node-path.sh"
# Also for systemd services such as Amp's bootstrap, which do not read profile.d.
install -d "$mnt/etc/systemd/system.conf.d"
printf '[Manager]\nDefaultEnvironment=NODE_PATH=/usr/lib/node_modules\n' \
	> "$mnt/etc/systemd/system.conf.d/node-path.conf"
arch-chroot "$mnt" bash -c 'curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash'
# Amp's Desktop launches `google-chrome`; Arch only packages Chromium.
chrome_version="$("$HERE/../common/install-google-chrome.sh" "$mnt")"

# srv's base installs agent-browser and its skill for root only; Amp runs as
# `user`. ~/.config/agents/skills is Amp's highest-precedence user skill path.
# Every directory is created as `user`: a root-owned ~/.config stops Chrome
# (and so agent-browser) from starting.
user_owner="$(arch-chroot "$mnt" id -u user):$(arch-chroot "$mnt" id -g user)"
skill_dir=/home/user/.config/agents/skills/agent-browser
for dir in /home/user/.config /home/user/.config/agents /home/user/.config/agents/skills "$skill_dir"; do
	install -d -m 0755 -o "${user_owner%:*}" -g "${user_owner#*:}" "$mnt$dir"
done
install -m 0644 -o "${user_owner%:*}" -g "${user_owner#*:}" \
	"$mnt/root/.agents/skills/agent-browser/SKILL.md" "$mnt$skill_dir/SKILL.md"
# Fail the build if Chrome cannot start for `user`, then drop the doctor's state.
arch-chroot "$mnt" runuser -u user -- bash -c 'cd /tmp && agent-browser doctor' >/dev/null
rm -rf "$mnt/home/user/.agent-browser" "$mnt/home/user/.config/google-chrome"
agent_browser_version="$(arch-chroot "$mnt" runuser -u user -- agent-browser --version)"

# pstack skills for every repository. agents/ mirrors ~/.config/agents/, so the
# skills' relative links to pstack/amp.md resolve in the image.
cp -r --no-preserve=ownership "$HERE/agents/." "$mnt/home/user/.config/agents/"
chown -R "$user_owner" "$mnt/home/user/.config/agents"
# Fail the build if any skill's adapter link does not resolve in the image.
while IFS= read -r skill; do
	link="$(grep -oE '\]\([^)]*amp\.md\)' "$skill" | head -1 || true)"
	link="${link#](}"; link="${link%)}"
	[[ -z $link || -f "$(dirname "$skill")/$link" ]] || { echo "pstack adapter link $link does not resolve from $skill" >&2; exit 1; }
done < <(find "$mnt/home/user/.config/agents/skills/pstack" -name SKILL.md)
pstack_revision="$(grep -oE '[0-9a-f]{40}' "$HERE/agents/skills/pstack/GENERATED.md" | head -1)"

# Tailscale: installed but not started at boot; amp-orb-tailscale.service
# starts tailscaled and logs in once Amp has connected the orb.
install -D -m 0755 "$HERE/guest/amp-orb-tailscale" "$mnt/usr/local/lib/srv/amp-orb-tailscale"
install -D -m 0644 /dev/stdin "$mnt/etc/amp-orb-tailscale.env" <<<"$tailscale_env"
install -D -m 0644 "$HERE/guest/amp-orb-tailscale.service" "$mnt/etc/systemd/system/amp-orb-tailscale.service"
install -D -m 0644 "$HERE/guest/tailscaled-mem-state.conf" "$mnt/etc/systemd/system/tailscaled.service.d/mem-state.conf"
systemctl --root="$mnt" disable tailscaled.service >/dev/null 2>&1 || true
systemctl --root="$mnt" enable amp-orb-tailscale.service >/dev/null

{
	echo "image=$ORB_IMAGE"
	echo "base=$BASE_DIR"
	echo "base_built_at=$(sed -n 's/^built_at=//p' "$BASE_DIR/manifest.txt")"
	echo "built_at=$(date --iso-8601=seconds)"
	echo "amp=$(arch-chroot "$mnt" runuser -u user -- /usr/local/bin/amp --version 2>/dev/null | head -1)"
	echo "tailscale=$(arch-chroot "$mnt" tailscale version 2>/dev/null | head -1)"
	echo "node=$(arch-chroot "$mnt" node --version)"
	echo "bun=$(arch-chroot "$mnt" bun --version)"
	echo "uv=$(arch-chroot "$mnt" uv --version)"
	echo "aws=$(arch-chroot "$mnt" aws --version)"
	echo "chrome=$chrome_version"
	echo "agent_browser=$agent_browser_version"
	echo "pstack=cursor/plugins@$pstack_revision"
	echo "aws_sdk_js=$(arch-chroot "$mnt" npm ls -g --depth=0 @aws-sdk/client-s3 | grep -o 'client-s3@[0-9.]*')"
	echo "packages=$(IFS=,; echo "${PACKAGES[*]}")"
} > "$OUTPUT_DIR/manifest.txt.new"

# Keep /root/.npm: its cache makes project installs of the AWS SDK offline-fast.
rm -rf "$mnt/var/cache/pacman/pkg/"* "$mnt/root/.cache"
pkill -f "gpg-agent --homedir $mnt/" 2>/dev/null || true
umount "$mnt"
e2fsck -fn "$img" >/dev/null || { echo "filesystem check failed on $img" >&2; exit 1; }

mv "$img" "$OUTPUT_DIR/rootfs-base.img"
mv "$OUTPUT_DIR/manifest.txt.new" "$OUTPUT_DIR/manifest.txt"
echo "built $OUTPUT_DIR/rootfs-base.img"
cat "$OUTPUT_DIR/manifest.txt"
