# Source this file, then call `site_env_load VAR...` to load the site
# configuration and require the named variables to be non-empty.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../common/site-env.sh"
#   site_env_load SITE_HOST_TAILNET_IP IPHONE_BROKER_PORT
#
# Precedence: environment > site.env > defaults in site.env.example. SITE_ENV
# overrides the site.env path, so `SITE_HOST_TAILNET_IP=... ./script` and
# `SITE_ENV=/etc/srv-ops/site.env ./script` both work.

SRV_OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_site_env_read() { # file -> exports KEY=VALUE lines not already set
	local line key value
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || { echo "$1: bad line: $line" >&2; return 1; }
		key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
		value=${value%\"} value=${value#\"}
		[[ -v $key ]] || export "$key=$value"
	done <"$1"
}

site_env_load() {
	local file="${SITE_ENV:-$SRV_OPS_ROOT/site.env}" var missing=()
	if [[ -f $file ]]; then
		_site_env_read "$file" || return 1
	elif (($#)); then
		echo "missing $file: copy site.env.example to site.env and fill it in" >&2
		return 1
	fi
	_site_env_read "$SRV_OPS_ROOT/site.env.example" || return 1
	for var in "$@"; do
		[[ -n ${!var-} ]] || missing+=("$var")
	done
	if ((${#missing[@]})); then
		echo "site.env: set ${missing[*]} (see site.env.example)" >&2
		return 1
	fi
}

# Replace @VAR@ placeholders in a template with values from the environment.
# A variable that is set but empty renders empty; an unset one is an error.
site_env_render() {
	local template=$1 content var
	content="$(<"$template")"
	while [[ $content =~ @([A-Z_][A-Z0-9_]*)@ ]]; do
		var=${BASH_REMATCH[1]}
		[[ -v $var ]] || { echo "$template: @$var@ is not set (site.env)" >&2; return 1; }
		content=${content//@$var@/${!var}}
	done
	printf '%s\n' "$content"
}
