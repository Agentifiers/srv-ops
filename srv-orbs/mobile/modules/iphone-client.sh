#!/usr/bin/env bash
# iphone-client: the `iphone` CLI for the shared, USB-attached iPhone on the srv host
# (srv-mobile-host/: pmd3-tunneld + iphone-broker), and the `iphone` skill.
#
#   /opt/iphone-client/iphone        Python stdlib only
#   /usr/local/bin/iphone            -> /opt/iphone-client/iphone
#   IPHONE_BROKER_URL                http://$SITE_HOST_TAILNET_IP:$IPHONE_BROKER_PORT
#   IPHONE_BUNDLE_PREFIX             $APPLE_BUNDLE_PREFIX (both: systemd + profile.d)
#   ~user/.config/agents/skills/iphone/SKILL.md
#
# The broker identifies the orb by its tailnet node (ORB_TAILSCALE_TAGS); nothing secret
# is installed. Runs on the host as root with MNT, CACHE and HERE set, plus the site.env
# settings above, which build-mobile-image.sh exports (see ../README.md).
set -euo pipefail
umask 022
: "${MNT:?}" "${CACHE:?}" "${HERE:?}"
: "${SITE_HOST_TAILNET_IP:?set SITE_HOST_TAILNET_IP in site.env}" "${IPHONE_BROKER_PORT:?set IPHONE_BROKER_PORT in site.env}"
: "${APPLE_BUNDLE_PREFIX:?set APPLE_BUNDLE_PREFIX in site.env}"

SRC="$HERE/modules/iphone-client"
BROKER_URL="http://$SITE_HOST_TAILNET_IP:$IPHONE_BROKER_PORT"

die() { echo "iphone-client.sh: $*" >&2; exit 1; }

arch-chroot "$MNT" pacman -S --needed --noconfirm python >/dev/null

install -d -m 0755 "$MNT/opt/iphone-client"
install -m 0755 "$SRC/iphone" "$MNT/opt/iphone-client/iphone"
ln -sfn /opt/iphone-client/iphone "$MNT/usr/local/bin/iphone"

install -d -m 0755 "$MNT/etc/systemd/system.conf.d" "$MNT/etc/profile.d"
printf '[Manager]\nDefaultEnvironment=IPHONE_BROKER_URL=%s IPHONE_BUNDLE_PREFIX=%s\n' "$BROKER_URL" "$APPLE_BUNDLE_PREFIX" \
	> "$MNT/etc/systemd/system.conf.d/mobile-iphone-client.conf"
printf 'export IPHONE_BROKER_URL=%s\nexport IPHONE_BUNDLE_PREFIX=%s\n' "$BROKER_URL" "$APPLE_BUNDLE_PREFIX" \
	> "$MNT/etc/profile.d/mobile-iphone-client.sh"

uid="$(arch-chroot "$MNT" id -u user)"
gid="$(arch-chroot "$MNT" id -g user)"
skill=/home/user/.config/agents/skills/iphone
for dir in /home/user/.config /home/user/.config/agents /home/user/.config/agents/skills "$skill"; do
	install -d -m 0755 -o "$uid" -g "$gid" "$MNT$dir"
done
install -m 0644 -o "$uid" -g "$gid" "$SRC/SKILL.md" "$MNT$skill/SKILL.md"

# Verify: the CLI parses and its help lists the commands the skill documents.
help="$(arch-chroot "$MNT" runuser -u user -- /usr/local/bin/iphone --help)" || die "iphone --help failed"
for c in lease screenshot install launch tap sign forward; do
	grep -q "$c" <<< "$help" || die "iphone --help lacks $c"
done

version="$(sha256sum "$SRC/iphone" "$SRC/SKILL.md" | sha256sum | cut -c1-12)"
touch "$MNT/etc/amp-orb-mobile.manifest"
sed -i -E '/^iphone_client=/d' "$MNT/etc/amp-orb-mobile.manifest"
echo "iphone_client=$version broker=$BROKER_URL" >> "$MNT/etc/amp-orb-mobile.manifest"
echo "[iphone-client] installed /usr/local/bin/iphone ($version), broker $BROKER_URL"
