#!/usr/bin/env bash
# Renders the Amp orb providers' host files from the repo's site.env:
#
#   ./install.sh render [DIR]   write rendered files to DIR (default ./rendered);
#                               env files there carry no provider token
#   sudo ./install.sh install   install the units, drop-ins and env files of the
#                               default (srv-orbs) and mobile (srv-orbs-mobile)
#                               providers, the keep-alive dispatch wrapper and
#                               its reap timers; an existing env file keeps its
#                               AMP_ORB_PROVIDER_TOKEN line
#
# srv-orbs.service itself is upstream's contrib/amp/orbs/srv-orbs.service from
# SRV_SRC_DIR. Nothing is enabled or restarted.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/site-env.sh
. "$HERE/../common/site-env.sh"
site_env_load SRV_SRC_DIR SRV_HOST ORB_IMAGE ORB_CPUS ORB_RAM ORB_DISK \
	MOBILE_ORB_IMAGE MOBILE_ORB_CPUS MOBILE_ORB_RAM MOBILE_ORB_DISK ORB_KEEPALIVE_HOURS

UPSTREAM_UNIT="$SRV_SRC_DIR/contrib/amp/orbs/srv-orbs.service"

# render_env TEMPLATE [EXISTING]: the template's settings without comments,
# preceded by EXISTING's AMP_ORB_PROVIDER_TOKEN line when there is one.
render_env() {
	local body
	body="$(site_env_render "$1")"
	if [[ -n ${2:-} && -r $2 ]]; then
		grep -m1 '^AMP_ORB_PROVIDER_TOKEN=' "$2" || true
	fi
	grep -v '^#' <<<"$body"
}

render_all() { # render_all DIR [ETC]
	local dir=$1 etc=${2:-}
	[[ -f $UPSTREAM_UNIT ]] || { echo "upstream unit not found at $UPSTREAM_UNIT (SRV_SRC_DIR)" >&2; return 1; }
	mkdir -p "$dir"
	install -m 0644 "$UPSTREAM_UNIT" "$dir/srv-orbs.service"
	install -m 0644 "$HERE/systemd/srv-orbs.service.d-coredump.conf" "$dir/srv-orbs.coredump.conf"
	install -m 0644 "$HERE/systemd/srv-orbs.service.d-keepalive.conf" "$dir/srv-orbs.keepalive.conf"
	install -m 0755 "$HERE/keepalive/srv-orb-keepalive" "$dir/srv-orb-keepalive"
	install -m 0644 "$HERE/keepalive/srv-orb-keepalive-reap@.service" "$HERE/keepalive/srv-orb-keepalive-reap@.timer" "$dir/"
	install -m 0644 "$HERE/mobile/systemd/srv-orbs-mobile.service" "$dir/srv-orbs-mobile.service"
	install -m 0644 "$HERE/mobile/systemd/srv-orbs-mobile.service.d-coredump.conf" "$dir/srv-orbs-mobile.coredump.conf"
	(
		umask 077
		render_env "$HERE/srv-orbs.env.example" ${etc:+"$etc/srv-orbs.env"} > "$dir/srv-orbs.env"
		render_env "$HERE/mobile/srv-orbs-mobile.env.example" ${etc:+"$etc/srv-orbs-mobile.env"} > "$dir/srv-orbs-mobile.env"
	)
}

case "${1:-}" in
render)
	render_all "${2:-$HERE/rendered}"
	echo "rendered into ${2:-$HERE/rendered}"
	;;
install)
	[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	render_all "$tmp" /etc
	install -m 0644 "$tmp/srv-orbs.service" "$tmp/srv-orbs-mobile.service" \
		"$tmp/srv-orb-keepalive-reap@.service" "$tmp/srv-orb-keepalive-reap@.timer" /etc/systemd/system/
	install -D -m 0644 "$tmp/srv-orbs.coredump.conf" /etc/systemd/system/srv-orbs.service.d/coredump.conf
	install -D -m 0644 "$tmp/srv-orbs.keepalive.conf" /etc/systemd/system/srv-orbs.service.d/keepalive.conf
	install -D -m 0644 "$tmp/srv-orbs-mobile.coredump.conf" /etc/systemd/system/srv-orbs-mobile.service.d/coredump.conf
	install -m 0755 "$tmp/srv-orb-keepalive" /usr/local/bin/srv-orb-keepalive
	for env in srv-orbs srv-orbs-mobile; do
		install -m 0600 -o root -g root "$tmp/$env.env" "/etc/$env.env"
		grep -q '^AMP_ORB_PROVIDER_TOKEN=' "/etc/$env.env" || echo "add AMP_ORB_PROVIDER_TOKEN to /etc/$env.env"
	done
	systemctl daemon-reload
	echo "installed; restart srv-orbs/srv-orbs-mobile to apply, and enable"
	echo "srv-orb-keepalive-reap@srv-orbs.timer and srv-orb-keepalive-reap@srv-orbs-mobile.timer"
	;;
*)
	echo "usage: $0 render [DIR] | install" >&2
	exit 2
	;;
esac
