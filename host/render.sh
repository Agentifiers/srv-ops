#!/usr/bin/env bash
# Prints srv's config rendered from the repo's site.env:
#   host/render.sh srv.env     # /etc/srv/srv.env without the Tailscale secrets (fill those in)
#   host/render.sh images.json # /etc/srv/images.json
# Install with e.g. `host/render.sh images.json | sudo tee /etc/srv/images.json`, or diff
# against what is installed. srv reads both only at startup.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../common/site-env.sh"

case "${1-}" in
srv.env) site_env_load SITE_TAILNET SITE_ADMIN_LOGINS ;;
images.json) site_env_load ;;
*) echo "usage: $0 srv.env|images.json" >&2; exit 2 ;;
esac
site_env_render "$HERE/srv/$1.example"
