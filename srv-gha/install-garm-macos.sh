#!/bin/bash
# Install or update GARM on winstons-mac-mini as the LaunchDaemon system/garm,
# running as the role account _garm. Run it with sudo from a directory holding:
#
#   garm, garm-provider-srv   darwin/arm64 builds (see README "GARM on the Mac")
#   garm.plist                launchd/garm.plist
#   config.toml               garm/config.toml.example, rendered, secrets filled in
#   provider-srv.toml         garm/provider-srv.toml, rendered
#   known_hosts               srv-front's pinned SSH host key line
#   import/                   optional: garm.db, blob-garm.db (and provider-srv/)
#                             from a stopped GARM; used only when no DB exists yet
#
#   sudo ./install-garm-macos.sh          # refuses to start without a DB
#   sudo ./install-garm-macos.sh --init   # first install: GARM creates a new controller
#
# GARM listens on 127.0.0.1:$GARM_API_PORT (default 9997); `tailscale serve`
# exposes that port on the tailnet for the relay, runners and garm-cli.
# Re-running replaces binaries and config and restarts GARM; the DB, provider
# state and known_hosts are kept.
set -euo pipefail

[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 1; }
init=0
[[ ${1:-} == --init ]] && init=1
cd "$(dirname "$0")"

port=${GARM_API_PORT:-9997}
gid=451 # role-account range; _srvfront is 450
state=/usr/local/var/garm
etc=/usr/local/etc/garm
log=/usr/local/var/log/garm.log
plist=/Library/LaunchDaemons/garm.plist
tailscale=(/opt/homebrew/bin/tailscale --socket=/var/run/tailscaled.socket)

for f in garm garm-provider-srv garm.plist config.toml provider-srv.toml known_hosts; do
	[[ -f $f ]] || { echo "missing $f in $PWD" >&2; exit 1; }
done
plutil -lint garm.plist >/dev/null

if ! dscl . -read /Groups/_garm >/dev/null 2>&1; then
	[[ -z $(dscl . -search /Groups PrimaryGroupID "$gid") ]] || { echo "GID $gid is taken" >&2; exit 1; }
	dscl . -create /Groups/_garm PrimaryGroupID "$gid"
fi
if ! dscl . -read /Users/_garm >/dev/null 2>&1; then
	[[ -z $(dscl . -search /Users UniqueID "$gid") ]] || { echo "UID $gid is taken" >&2; exit 1; }
	dscl . -create /Users/_garm UniqueID "$gid"
	dscl . -create /Users/_garm PrimaryGroupID "$gid"
	dscl . -create /Users/_garm UserShell /usr/bin/false
	dscl . -create /Users/_garm NFSHomeDirectory "$state" # ssh reads ~/.ssh/known_hosts from here
	dscl . -create /Users/_garm IsHidden 1
fi

install -d -o root -g wheel -m 0755 /usr/local/bin /usr/local/lib/garm /usr/local/var/log
install -d -o root -g _garm -m 0750 "$etc"
install -d -o _garm -g _garm -m 0700 "$state" "$state/.ssh" "$state/provider-srv"

if [[ ! -e $state/garm.db ]]; then
	if [[ -f import/garm.db ]]; then
		install -o _garm -g _garm -m 0600 import/garm.db "$state/garm.db"
		[[ ! -f import/blob-garm.db ]] || install -o _garm -g _garm -m 0600 import/blob-garm.db "$state/blob-garm.db"
		if [[ -d import/provider-srv ]]; then
			cp -R import/provider-srv/. "$state/provider-srv/"
			chown -R _garm:_garm "$state/provider-srv"
		fi
		echo "imported GARM database from $PWD/import"
	elif (( ! init )); then
		echo "no $state/garm.db and no import/garm.db; pass --init to start a new controller" >&2
		exit 1
	fi
fi
[[ -f $state/.ssh/known_hosts ]] || install -o _garm -g _garm -m 0600 known_hosts "$state/.ssh/known_hosts"
[[ -f $log ]] || install -o _garm -g _garm -m 0600 /dev/null "$log"

install -o root -g wheel -m 0755 garm /usr/local/bin/garm
install -o root -g wheel -m 0755 garm-provider-srv /usr/local/lib/garm/garm-provider-srv
install -o root -g _garm -m 0640 config.toml provider-srv.toml "$etc/"
install -o root -g wheel -m 0644 garm.plist "$plist"

"${tailscale[@]}" serve --bg --tcp "$port" "tcp://127.0.0.1:$port" >/dev/null

if launchctl print system/garm >/dev/null 2>&1; then
	launchctl kickstart -k system/garm
else
	launchctl bootstrap system "$plist"
fi

for _ in $(seq 30); do
	code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/v1/first-run/" || true)
	[[ $code != 000 ]] && break
	sleep 1
done
launchctl print system/garm | awk '/^\tstate = /{s=$3} /^\tpid = /{p=$3} END{print "garm: state=" s, "pid=" p}'
[[ $code != 000 ]] || { echo "GARM is not answering on 127.0.0.1:$port; see $log" >&2; exit 1; }
echo "GARM answers on 127.0.0.1:$port and on the tailnet via tailscale serve"
