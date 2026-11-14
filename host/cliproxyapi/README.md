# CLIProxyAPI (model proxy)

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) pools the Claude and
Codex subscription accounts behind one OpenAI/Anthropic-compatible endpoint. It
runs on `winstons-mac-mini`. Amp (custom provider) and `omp` on every machine
(`tokens` provider) reach it through the Hetzner relay in `../relay`:

```
client ─https─> token-proxy.workinprogress.dev  (Coolify relay, Caddy)
                  ─tailnet─> winstons-mac-mini:8318 (tailscale serve) ─> 127.0.0.1:8318 CLIProxyAPI
client ─https─> tokens.workinprogress.dev       (Cloudflare Tunnel, fallback) ─> 127.0.0.1:8318
```

| Piece | Where (on winstons-mac-mini, user `winston`) |
|---|---|
| Binary | `~/.local/bin/cli-proxy-api` (release asset `CLIProxyAPI_<version>_darwin_aarch64.tar.gz`; v8.0.63 or later for Fable 5.2) |
| Config | `~/.cli-proxy-api/merged-config.yaml`, listening on `127.0.0.1:8318` |
| Credentials | `~/.cli-proxy-api/claude-*.json`, `codex-*.json` (the `auth-dir`; changes load live) |
| Service | LaunchDaemon `system/com.winston.cliproxyapi`, running as `winston`; log `~/.cli-proxy-api/logs/launchd.out.log` |
| Tailnet port | `tailscale --socket=/var/run/tailscaled.socket serve --bg --tcp 8318 tcp://127.0.0.1:8318`. The Mac is on the tailnet through Homebrew's `tailscaled`; without `--socket` the CLI talks to a leftover GUI network extension and reports "Logged out". |
| Cloudflare fallback | LaunchDaemon `system/com.winston.cloudflared-tokens`, `~/.cloudflared/config.yml` |
| Management API | Loopback only (`allow-remote: false`). Bearer key in `~/.config/cli-proxy-api/management-key`; the config holds its bcrypt hash. |
| Client keys | `access.api-keys` in the config. omp hosts read theirs from `~/.config/cliproxyapi/token-proxy-key`. |

The config's comments explain each setting: SSE keep-alives every 15 s, retry
on another credential before the first token, summarized thinking for
`claude-opus-5*`/`claude-fable-5*`, and `172.16.0.0/12` as a trusted proxy so
logs show the relay's real client IPs. Each credential carries a model prefix
(`anthropic` for Claude, `openai` for Codex) so Amp's `anthropic/claude-…` IDs
resolve; bare IDs keep working because `force-model-prefix` is off.

Run only this one proxy with these credentials. omarchy-1 served them until
2026-11-14; its copies are parked in `~/.cli-proxy-api-retired-20261114/` there
and its `cli-proxy-api` and `cloudflared-cliproxyapi` user units are disabled.

## Start at boot

The Mac has no auto-login, so a LaunchAgent only runs once someone logs in.
Both jobs therefore run as LaunchDaemons with `UserName winston`, like
`srv-front`. `install-launchdaemons.sh` converts an existing LaunchAgent, keeps
the agent plist as `<label>.plist.disabled`, and restarts the daemon when re-run:

```sh
scp host/cliproxyapi/install-launchdaemons.sh winston@winstons-mac-mini:
ssh -t winston@winstons-mac-mini sudo ./install-launchdaemons.sh \
  com.winston.cliproxyapi com.winston.cloudflared-tokens
```

Config and credential changes reload live. `server:` settings and a new binary
need a restart, which cuts in-flight streams:

```sh
sudo launchctl kickstart -k system/com.winston.cliproxyapi
```

## Rate limits and cooldowns

When Anthropic answers an account with 429 ("This request would exceed your
account's rate limit"), CLIProxyAPI parks that credential until the reset time
in Anthropic's rate-limit headers and routes to the other accounts. For the
weekly limit that time can be days away. Once every account is parked, requests
fail with:

```
auth unavailable: 3 of 3 candidate(s) for model "claude-opus-5-5" (provider=claude) are in cooldown: [... reason=quota, remaining=37h5m30s], ...
```

The proxy never retries a parked account early, so it doesn't notice a usage
reset you make at Anthropic. Clear the cooldowns yourself afterwards (on
winstons-mac-mini):

```sh
k=$(cat ~/.config/cli-proxy-api/management-key)
M=http://127.0.0.1:8318/v0/management

# state: name, auth_index, status, next_retry_after
curl -s -H "Authorization: Bearer $k" $M/auth-files | /usr/bin/python3 -c '
import json, sys
for f in json.load(sys.stdin)["files"]:
    print(f["name"], f["auth_index"], f["status"], f.get("next_retry_after"))'

# clear every Claude credential
curl -s -H "Authorization: Bearer $k" $M/auth-files \
  | /usr/bin/python3 -c 'import json,sys;[print(f["auth_index"]) for f in json.load(sys.stdin)["files"] if f["name"].startswith("claude")]' \
  | while read -r i; do
      curl -s -X POST -H "Authorization: Bearer $k" -H 'Content-Type: application/json' \
        -d "{\"auth_index\":\"$i\"}" $M/reset-quota; echo
    done
```

Clearing all of them is safe even if you reset only one account. An account
that is still limited fails its next request with a fresh 429 and goes back
into cooldown with Anthropic's real reset time, while the others keep serving.
Restarting the proxy also starts it with no cooldowns (seen with v8.0.63), but
cuts in-flight streams, so prefer `reset-quota`.

To check: `grep -E 'cooldown|429' ~/.cli-proxy-api/logs/launchd.out.log | tail`.

## Adding an account

Sign Chrome on the Mac into the new Claude account first, then:

```sh
ssh -tt winston@winstons-mac-mini \
  '~/.local/bin/cli-proxy-api -claude-login -no-browser -config ~/.cli-proxy-api/merged-config.yaml 2>&1 | tee /tmp/claude-login.log'
# second terminal, within 5 minutes (the login times out):
ssh winston@winstons-mac-mini \
  'open -a "Google Chrome" "$(grep -o "https://claude.ai/oauth/authorize[^[:space:]]*" /tmp/claude-login.log | head -1)"'
```

The OAuth callback goes to `http://localhost:54545` on the Mac. If you approve
in a browser on another machine instead, that browser ends on a failed
`http://localhost:54545/callback?code=…` page; paste that URL at the login's
"Paste the Claude callback URL" prompt before the 5 minutes run out. A code
from an earlier, timed-out login can't be reused.

The new file (`claude-<id>-<email>.json`) loads without a restart. Give it the
model prefix the other credentials have (`$k`/`$M` as above):

```sh
curl -s -X PATCH -H "Authorization: Bearer $k" -H 'Content-Type: application/json' \
  -d '{"name":"claude-<id>-<email>.json","prefix":"anthropic"}' $M/auth-files/fields
```

## Upgrading

On the Mac:

```sh
v=8.0.63
base=https://github.com/router-for-me/CLIProxyAPI/releases/download/v$v
curl -fsSLO $base/CLIProxyAPI_${v}_darwin_aarch64.tar.gz
curl -fsSL $base/checksums.txt | grep darwin_aarch64 | shasum -a 256 -c
tar xzf CLIProxyAPI_${v}_darwin_aarch64.tar.gz cli-proxy-api
cp -p ~/.local/bin/cli-proxy-api ~/.local/bin/cli-proxy-api.prev
install -m 755 cli-proxy-api ~/.local/bin/cli-proxy-api
sudo launchctl kickstart -k system/com.winston.cliproxyapi
```
