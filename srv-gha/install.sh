#!/usr/bin/env bash
# Renders srv-gha's host templates from the repo's site.env:
#
#   ./install.sh render [DIR]   write rendered files to DIR (default ./rendered)
#   sudo ./install.sh install   install bazel-remote's systemd unit (srv host)
#
# GARM runs on winstons-mac-mini: copy the rendered config.toml.example (as
# config.toml, secrets filled in), provider-srv.toml and garm.plist next to
# the binaries and run install-garm-macos.sh there (README "GARM on the Mac").
#
# Templates use @VAR@ placeholders for settings from site.env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../common/site-env.sh"
site_env_load SITE_HOST_TAILNET_IP GARM_API_PORT BAZEL_REMOTE_GRPC_PORT BAZEL_REMOTE_HTTP_PORT \
	BAZEL_REMOTE_DIR BAZEL_REMOTE_MAX_SIZE_GIB SRV_FRONT_HOST GHA_RUNNER_IMAGE

render() { site_env_render "$1" > "$2"; } # render SRC DEST

render_all() { # render_all DIR
	mkdir -p "$1"
	render "$HERE/systemd/bazel-remote.service" "$1/bazel-remote.service"
	render "$HERE/garm/config.toml.example" "$1/config.toml.example"
	render "$HERE/garm/provider-srv.toml" "$1/provider-srv.toml"
	cp "$HERE/launchd/garm.plist" "$1/garm.plist"
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
	install -m 0644 "$tmp/bazel-remote.service" /etc/systemd/system/
	systemctl daemon-reload
	echo "installed; restart bazel-remote to apply"
	;;
*)
	echo "usage: $0 render [DIR] | install" >&2
	exit 2
	;;
esac
