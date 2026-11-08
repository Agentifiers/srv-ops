#!/usr/bin/env bash
# Applies host/srv/patches/*.patch to the srv checkout in SRV_SRC_DIR (site.env),
# in name order. Idempotent: a patch that is already applied is skipped; one that
# neither applies nor reverses cleanly stops the script.
#
#   host/srv/apply-patches.sh           # apply
#   host/srv/apply-patches.sh --check   # report only, change nothing
#
# Then build and install srv from SRV_SRC_DIR as usual
# (sudo ./contrib/systemd/install.sh). Drop a patch once upstream has it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../common/site-env.sh"
site_env_load SRV_SRC_DIR

check=0
case "${1-}" in
--check) check=1 ;;
"") ;;
*) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

git -C "$SRV_SRC_DIR" rev-parse --git-dir >/dev/null
shopt -s nullglob
for patch in "$HERE"/patches/*.patch; do
	name="$(basename "$patch")"
	if git -C "$SRV_SRC_DIR" apply --check -R "$patch" 2>/dev/null; then
		echo "already applied: $name"
	elif git -C "$SRV_SRC_DIR" apply --check "$patch" 2>/dev/null; then
		if ((check)); then
			echo "would apply: $name"
		else
			git -C "$SRV_SRC_DIR" apply "$patch"
			echo "applied: $name"
		fi
	else
		echo "does not apply (upstream changed or merged it?): $name" >&2
		exit 1
	fi
done
