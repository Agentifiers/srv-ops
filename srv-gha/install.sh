#!/usr/bin/env bash
# Renders srv-gha's host templates from the repo's site.env:
#
#   ./install.sh render [DIR]   write rendered files to DIR (default ./rendered)
#   sudo ./install.sh install   install the systemd units and the provider
#                               config; /etc/garm/config.toml is only created
#                               when missing (fill in its secrets afterwards)
#
# Templates use @VAR@ placeholders for settings from site.env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../common/site-env.sh"
site_env_load SITE_HOST_TAILNET_IP GARM_API_PORT BAZEL_REMOTE_GRPC_PORT BAZEL_REMOTE_HTTP_PORT \
	BAZEL_REMOTE_DIR BAZEL_REMOTE_MAX_SIZE_GIB SRV_HOST GHA_RUNNER_IMAGE

render() { site_env_render "$1" > "$2"; } # render SRC DEST

render_all() { # render_all DIR
	mkdir -p "$1"
	render "$HERE/systemd/bazel-remote.service" "$1/bazel-remote.service"
	render "$HERE/systemd/garm.service" "$1/garm.service"
	render "$HERE/garm/config.toml.example" "$1/config.toml.example"
	render "$HERE/garm/provider-srv.toml" "$1/provider-srv.toml"
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
	render_all "$tmp"
	install -m 0644 "$tmp/bazel-remote.service" "$tmp/garm.service" /etc/systemd/system/
	install -d /etc/garm
	install -m 0640 -o root -g garm "$tmp/provider-srv.toml" /etc/garm/provider-srv.toml
	if [[ ! -e /etc/garm/config.toml ]]; then
		install -m 0640 -o root -g garm "$tmp/config.toml.example" /etc/garm/config.toml
		echo "created /etc/garm/config.toml; set jwt_auth.secret and database.passphrase"
	fi
	systemctl daemon-reload
	echo "installed; restart garm/bazel-remote to apply"
	;;
*)
	echo "usage: $0 render [DIR] | install" >&2
	exit 2
	;;
esac
