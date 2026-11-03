#!/bin/bash
# Check tailscaled; restart if not running/online. Prints one status line.
# On NEEDS_LOGIN: POST the auth URL to OpenClaw (once per URL) if env file exists.
STATE=/var/lib/tailscale/tailscaled.state
SOCK=/var/run/tailscale/tailscaled.sock
LOG=/var/log/tailscaled.log
HOOK_ENV=/home/box/.config/ts-watchdog/env
HOOK_LAST=/var/lib/tailscale/last_auth_hook_url
st() { tailscale status --json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('BackendState'),d['Self'].get('Online'),d.get('AuthURL') or '-')" 2>/dev/null; }
notify() { # $1 = auth url
  local url="$1"; [ -n "$url" ] && [ "$url" != "-" ] && [ "$url" != "unknown" ] || return 0
  [ -r "$HOOK_ENV" ] || return 0
  [ "$(cat "$HOOK_LAST" 2>/dev/null)" = "$url" ] && { echo "HOOK_SKIPPED_ALREADY_SENT"; return 0; }
  ( set -a; . "$HOOK_ENV"; set +a
    [ -n "$OPENCLAW_URL" ] && [ -n "$OPENCLAW_MCP_BRIDGE_BEARER" ] || exit 0
    body=$(python3 -c 'import json,sys;print(json.dumps({"text":"Tailscale auf grok-bot braucht Login: "+sys.argv[1]}))' "$url")
    code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$OPENCLAW_URL/mcp/direct" \
      -H "Authorization: Bearer $OPENCLAW_MCP_BRIDGE_BEARER" -H 'Content-Type: application/json' -d "$body")
    echo "HOOK_HTTP $code"
    [ "${code:0:1}" = "2" ] && echo "$url" > "$HOOK_LAST" )
}
s=$(st)
if [ "${s%% *}" = "NeedsLogin" ]; then echo "NEEDS_LOGIN ${s##* }"; notify "${s##* }"; exit 2; fi
if pgrep -x tailscaled >/dev/null && [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ]; then echo "OK $s"; exit 0; fi
pkill -TERM -x tailscaled; for i in $(seq 1 10); do pgrep -x tailscaled >/dev/null || break; sleep 1; done
nohup /usr/local/bin/tailscaled --state=$STATE --socket=$SOCK >> $LOG 2>&1 &
for i in $(seq 1 25); do s=$(st); [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ] && { echo "RESTARTED_OK $s"; exit 0; }; [ "${s%% *}" = "NeedsLogin" ] && break; sleep 1; done
if [ "${s%% *}" = "NeedsLogin" ]; then
  url=$(timeout 15 tailscale up --ssh --hostname=grok-bot 2>&1 | grep -oE 'https://login.tailscale.com/[^ ]+' | head -1)
  echo "NEEDS_LOGIN ${url:-unknown}"; notify "${url:-unknown}"; exit 2
fi
echo "RESTART_FAILED $s"; exit 1
