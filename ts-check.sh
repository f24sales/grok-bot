#!/bin/bash
# Check tailscaled. Prints one status line.
# NeedsLogin            -> NEEDS_LOGIN, POST auth URL to OpenClaw (once per URL), exit 2
# Running + Online      -> OK, offline counter reset, exit 0
# not Online / no daemon-> counter+1; below OFFLINE_THRESHOLD: OFFLINE n/N exit 0 (no restart)
#                          at threshold: restart tailscaled (no OpenClaw message; only login URLs are posted)
STATE=/var/lib/tailscale/tailscaled.state
SOCK=/var/run/tailscale/tailscaled.sock
LOG=/var/log/tailscaled.log
HOOK_ENV=/home/box/.config/ts-watchdog/env
HOOK_LAST=/var/lib/tailscale/last_auth_hook_url
OFF_CNT=/var/lib/tailscale/offline_count
OFFLINE_THRESHOLD=${OFFLINE_THRESHOLD:-1}
st() { tailscale status --json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('BackendState'),d['Self'].get('Online'),d.get('AuthURL') or '-')" 2>/dev/null; }
post() { # $1 = text
  [ -r "$HOOK_ENV" ] || return 1
  ( set -a; . "$HOOK_ENV"; set +a
    [ -n "$OPENCLAW_URL" ] && [ -n "$OPENCLAW_MCP_BRIDGE_BEARER" ] || exit 1
    body=$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1]}))' "$1")
    code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$OPENCLAW_URL/mcp/direct" \
      -H "Authorization: Bearer $OPENCLAW_MCP_BRIDGE_BEARER" -H 'Content-Type: application/json' -d "$body")
    echo "HOOK_HTTP $code"; [ "${code:0:1}" = "2" ] )
}
notify_login() { # $1 = auth url, sent once per URL
  local url="$1"; [ -n "$url" ] && [ "$url" != "-" ] && [ "$url" != "unknown" ] || return 0
  [ "$(cat "$HOOK_LAST" 2>/dev/null)" = "$url" ] && { echo "HOOK_SKIPPED_ALREADY_SENT"; return 0; }
  post "Tailscale auf grok-bot braucht Login: $url" && echo "$url" > "$HOOK_LAST"
}
s=$(st)
if [ "${s%% *}" = "NeedsLogin" ]; then
  url="${s##* }"
  [ "$url" = "-" ] && url=$(timeout 15 tailscale up --ssh --hostname=grok-bot 2>&1 | grep -oE 'https://login.tailscale.com/[^ ]+' | head -1)
  echo "NEEDS_LOGIN ${url:-unknown}"; notify_login "${url:-unknown}"; exit 2
fi
if pgrep -x tailscaled >/dev/null && [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ]; then
  echo 0 > "$OFF_CNT"; echo "OK $s"; exit 0
fi
n=$(( $(cat "$OFF_CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$OFF_CNT"
if [ "$n" -lt "$OFFLINE_THRESHOLD" ]; then echo "OFFLINE $n/$OFFLINE_THRESHOLD ${s:-no-daemon}"; exit 0; fi
pkill -TERM -x tailscaled; for i in $(seq 1 10); do pgrep -x tailscaled >/dev/null || break; sleep 1; done
nohup /usr/local/bin/tailscaled --state=$STATE --socket=$SOCK >> $LOG 2>&1 &
for i in $(seq 1 25); do
  s=$(st)
  if [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ]; then
    echo 0 > "$OFF_CNT"; echo "RESTARTED_OK $s" exit 0
  fi
  [ "${s%% *}" = "NeedsLogin" ] && break; sleep 1
done
if [ "${s%% *}" = "NeedsLogin" ]; then
  url=$(timeout 15 tailscale up --ssh --hostname=grok-bot 2>&1 | grep -oE 'https://login.tailscale.com/[^ ]+' | head -1)
  echo "NEEDS_LOGIN ${url:-unknown}"; notify_login "${url:-unknown}"; exit 2
fi
echo "RESTART_FAILED $s"; exit 1
