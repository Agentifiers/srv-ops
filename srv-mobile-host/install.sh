#!/usr/bin/env bash
# Installs (or updates) the host side of the shared iPhone: pmd3-tunneld + iphone-broker.
#   sudo ./install.sh              # keeps an existing /etc/srv-mobile/iphone-broker.env
#   sudo ./install.sh --render-env # rewrites it from site.env (the old one is kept as .bak-<time>)
#   ./install.sh --print-env       # prints the rendered env file and exits (no root needed)
# Needs: the repo's site.env (SITE_HOST_TAILNET_IP, IPHONE_BROKER_PORT, ORB_TAILSCALE_TAGS,
# SITE_ADMIN_LOGINS, APPLE_BUNDLE_PREFIX) when the env file is rendered, /opt/pymobiledevice3
# (venv with pymobiledevice3 11.45.0), usbmuxd, tailscaled, the iPhone USB-paired (see
# README.md), /etc/srv-mobile/asc.env for signing (optional).
# Idempotent: rerun after changing anything in this directory.
set -euo pipefail
umask 022
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../common/site-env.sh"
ENV_VARS=(SITE_HOST_TAILNET_IP IPHONE_BROKER_PORT ORB_TAILSCALE_TAGS SITE_ADMIN_LOGINS APPLE_BUNDLE_PREFIX)

render_env=0
case "${1-}" in
"") ;;
--render-env) render_env=1 ;;
--print-env)
	site_env_load "${ENV_VARS[@]}"
	site_env_render "$HERE/iphone-broker.env.example"
	exit
	;;
*) echo "usage: $0 [--render-env | --print-env]" >&2; exit 2 ;;
esac
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
site_env_load # MOBILE_CACHE_DIR (defaults apply without site.env)

PMD3_VERSION=11.45.0
RCODESIGN_VERSION=0.29.0 # same pin as srv-orbs/mobile/modules/ios-toolchain.sh
RCODESIGN_SHA256=dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002
CACHE=$MOBILE_CACHE_DIR/ios-toolchain
USER_NAME=iphone-broker
STATE=/var/lib/iphone-broker
ASC_ENV=/etc/srv-mobile/asc.env
BROKER_ENV=/etc/srv-mobile/iphone-broker.env

die() { echo "install.sh: $*" >&2; exit 1; }

have="$(/opt/pymobiledevice3/bin/python -c 'import pymobiledevice3._version as v; print(v.__version__)' 2>/dev/null)" \
	|| die "/opt/pymobiledevice3 is missing"
[[ $have == "$PMD3_VERSION" ]] || echo "install.sh: warning: pymobiledevice3 $have, tested with $PMD3_VERSION" >&2

# --- rcodesign (signing for /v1/sign)
rcs=apple-codesign-$RCODESIGN_VERSION-x86_64-unknown-linux-musl
if [[ "$(/opt/rcodesign/bin/rcodesign --version 2>/dev/null)" != "apple-codesign $RCODESIGN_VERSION" ]]; then
	install -d "$CACHE"
	if ! echo "$RCODESIGN_SHA256  $CACHE/$rcs.tar.gz" | sha256sum -c --quiet - 2>/dev/null; then
		curl -fL --retry 3 -o "$CACHE/$rcs.tar.gz.part" \
			"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F$RCODESIGN_VERSION/$rcs.tar.gz"
		mv "$CACHE/$rcs.tar.gz.part" "$CACHE/$rcs.tar.gz"
	fi
	echo "$RCODESIGN_SHA256  $CACHE/$rcs.tar.gz" | sha256sum -c --quiet - || die "rcodesign sha256 mismatch"
	install -d /opt/rcodesign/bin
	tar -xzf "$CACHE/$rcs.tar.gz" -C /opt/rcodesign/bin --strip-components=1 --no-same-owner "$rcs/rcodesign"
fi

# --- system user and state
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
	useradd --system --home-dir "$STATE" --no-create-home --shell /usr/bin/nologin \
		--comment "iPhone broker" "$USER_NAME"
fi
install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$STATE"
# The personalized DDI (iOS 17+ cryptex) that `mounter auto-mount` would otherwise
# download: copied from the admin's pymobiledevice3 cache when present.
ddi_src=""
for home in /root "$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"; do
	[[ -d $home/.local/share/pymobiledevice3/Xcode_iOS_DDI_Cryptex ]] && ddi_src=$home/.local/share/pymobiledevice3/Xcode_iOS_DDI_Cryptex
done
if [[ -n $ddi_src ]]; then
	install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$STATE/.local" "$STATE/.local/share" "$STATE/.local/share/pymobiledevice3"
	rsync -a --delete --chown="$USER_NAME:$USER_NAME" "$ddi_src/" "$STATE/.local/share/pymobiledevice3/Xcode_iOS_DDI_Cryptex/"
fi

# --- code
rm -rf /opt/iphone-broker.new
install -d -m 0755 /opt/iphone-broker.new
install -m 0755 "$HERE/broker/iphone_broker.py" "$HERE/broker/pmd3_helper.py" /opt/iphone-broker.new/
install -m 0644 "$HERE/broker/signer.py" /opt/iphone-broker.new/
rm -rf /opt/iphone-broker && mv /opt/iphone-broker.new /opt/iphone-broker
/opt/pymobiledevice3/bin/python -m py_compile /opt/iphone-broker/*.py
rm -rf /opt/iphone-broker/__pycache__

# --- config
install -d -m 0755 /etc/srv-mobile
if [[ ! -f $BROKER_ENV ]] || ((render_env)); then
	site_env_load "${ENV_VARS[@]}"
	site_env_render "$HERE/iphone-broker.env.example" > "$BROKER_ENV.new"
	if [[ -f $BROKER_ENV ]]; then cp -p "$BROKER_ENV" "$BROKER_ENV.bak-$(date +%Y%m%d%H%M%S)"; fi
	chmod 0644 "$BROKER_ENV.new"
	mv "$BROKER_ENV.new" "$BROKER_ENV"
	echo "install.sh: wrote $BROKER_ENV from site.env" >&2
fi

# --- units
install -m 0644 "$HERE/systemd/pmd3-tunneld.service" "$HERE/systemd/iphone-broker.service" /etc/systemd/system/
dropin=/etc/systemd/system/iphone-broker.service.d
install -d -m 0755 "$dropin"
if [[ -f $ASC_ENV ]]; then
	key="$(sed -n 's/^ASC_KEY_PATH=//p' "$ASC_ENV" | tr -d '"'"'"' ')"
	[[ -f $key ]] || die "ASC_KEY_PATH in $ASC_ENV does not exist: $key"
	cat > "$dropin/asc-credentials.conf" <<-EOF
	# Generated by srv-mobile-host/install.sh from $ASC_ENV: systemd (as root) copies
	# these into \$CREDENTIALS_DIRECTORY for this service only; the files stay root 0600.
	[Service]
	LoadCredential=asc.env:$ASC_ENV
	LoadCredential=asc.p8:$key
	EOF
else
	rm -f "$dropin/asc-credentials.conf"
	echo "install.sh: $ASC_ENV missing: /v1/sign disabled" >&2
fi

systemctl daemon-reload
systemctl enable --now pmd3-tunneld.service
systemctl enable iphone-broker.service
systemctl restart iphone-broker.service
sleep 3
systemctl --no-pager --lines=5 status iphone-broker.service || die "iphone-broker failed to start"
