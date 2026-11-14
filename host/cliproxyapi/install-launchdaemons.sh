#!/bin/bash
# Turn the invoking user's LaunchAgents into LaunchDaemons that run as that
# user, so they start at boot without a GUI login (winstons-mac-mini has no
# auto-login). Re-running restarts the daemons.
#
#   sudo ./install-launchdaemons.sh com.winston.cliproxyapi com.winston.cloudflared-tokens
#
# The agent plist is kept as <label>.plist.disabled so it doesn't also start at
# login and fight the daemon for its port.
set -euo pipefail

user=${SUDO_USER:?run with sudo from the account that owns the LaunchAgents}
uid=$(id -u "$user")
group=$(id -gn "$user")
home=$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')

for label in "$@"; do
	agent="$home/Library/LaunchAgents/$label.plist"
	daemon="/Library/LaunchDaemons/$label.plist"
	if [[ -f $agent ]]; then
		tmp=$(mktemp)
		cp "$agent" "$tmp"
		plutil -replace UserName -string "$user" "$tmp"
		plutil -replace GroupName -string "$group" "$tmp"
		plutil -replace Umask -integer 63 "$tmp" # 0077: credentials the job writes stay private
		plutil -lint "$tmp" >/dev/null
		install -o root -g wheel -m 0644 "$tmp" "$daemon"
		rm -f "$tmp"
		launchctl bootout "gui/$uid/$label" 2>/dev/null || true
		mv "$agent" "$agent.disabled"
	fi
	[[ -f $daemon ]] || { echo "$label: neither $agent nor $daemon exists" >&2; exit 1; }
	if launchctl print "system/$label" >/dev/null 2>&1; then
		launchctl kickstart -k "system/$label"
	else
		launchctl bootstrap system "$daemon"
	fi
	sleep 2
	printf '%s: ' "$label"
	launchctl print "system/$label" | awk '/^\tstate = /{s=$3} /^\tpid = /{p=$3} END{print "state=" s, "pid=" p}'
done
