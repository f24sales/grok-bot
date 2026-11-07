#!/bin/bash
# Check tailscaled. Prints one status line.
# NeedsLogin            -> stream `tailscale up --ssh`, POST each distinct auth URL to OpenClaw
#                          (once per URL), WAIT until up exits, then re-check / exit 2 if still needed
# Running + Online      -> OK, offline counter reset, exit 0
# not Online / no daemon-> counter+1; below OFFLINE_THRESHOLD: OFFLINE n/N exit 0 (no restart)
#                          at threshold: restart tailscaled (no OpenClaw message; only login URLs are posted)
# Missing install       -> official static tarball (pinned tested 1.104.5) into /usr/local/bin, then re-exec
STATE=/var/lib/tailscale/tailscaled.state
SOCK=/var/run/tailscale/tailscaled.sock
LOG=/var/log/tailscaled.log
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
HOOK_ENV="$SCRIPT_DIR/ts-check.env"; [ -r "$HOOK_ENV" ] || HOOK_ENV=/home/box/.config/ts-watchdog/env
HOOK_LAST=/var/lib/tailscale/last_auth_hook_url
OFF_CNT=/var/lib/tailscale/offline_count
OFFLINE_THRESHOLD=${OFFLINE_THRESHOLD:-1}
# Prefer /usr/local/bin (static layout used by this script); fall back to apt paths if present
TS_DAEMON=/usr/local/bin/tailscaled
[ -x "$TS_DAEMON" ] || TS_DAEMON=/usr/sbin/tailscaled
[ -x "$TS_DAEMON" ] || TS_DAEMON=$(command -v tailscaled 2>/dev/null || true)
# Pinned to version verified on this host via pkgs.tailscale.com stable static channel.
# Bump deliberately when upgrading; checksum is always fetched from official .sha256 URL.
TS_STATIC_VER=1.104.5
# Single instance across self re-exec and the whole sequential auth wait.
# Lock lives in root-only /var/lib/tailscale (0700). FD 9 is closed for daemon/children.
LOCK=/var/lib/tailscale/ts-check.lock
if [ "${TS_CHECK_LOCKED:-0}" != 1 ]; then
  mkdir -p -m 700 /var/lib/tailscale
  exec 9>"$LOCK" || { echo "LOCK_FAILED"; exit 1; }
  flock -n 9 || { echo "BUSY"; exit 0; }
  export TS_CHECK_LOCKED=1
fi
# Non-executing env parser: only KEY=value / KEY='value' / KEY="value" for the two expected keys.
load_hook_env() {
  local k v
  OPENCLAW_URL=; OPENCLAW_MCP_BRIDGE_BEARER=
  [ -r "$HOOK_ENV" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$v" in \'*\') v=${v#\'}; v=${v%\'} ;; \"*\") v=${v#\"}; v=${v%\"} ;; esac
    case "$k" in
      OPENCLAW_URL) OPENCLAW_URL=$v ;;
      OPENCLAW_MCP_BRIDGE_BEARER) OPENCLAW_MCP_BRIDGE_BEARER=$v ;;
    esac
  done < "$HOOK_ENV"
  [ -n "$OPENCLAW_URL" ] && [ -n "$OPENCLAW_MCP_BRIDGE_BEARER" ]
}
st() { tailscale status --json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('BackendState'),d['Self'].get('Online'),d.get('AuthURL') or '-')" 2>/dev/null; }
post() { # $1 = text
  ( load_hook_env || exit 1
    body=$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1]}))' "$1")
    # Bearer via stdin header (-H @-), not argv
    code=$(printf 'Authorization: Bearer %s\n' "$OPENCLAW_MCP_BRIDGE_BEARER" | \
      curl -sS -m 15 -o /dev/null -w '%{http_code}' "$OPENCLAW_URL/mcp/direct" \
      -H @- -H 'Content-Type: application/json' -d "$body" 9>&-)
    echo "HOOK_HTTP $code"; [ "${code:0:1}" = "2" ] )
}
notify_login() { # $1 = auth url, sent once per URL
  local url="$1"; [ -n "$url" ] && [ "$url" != "-" ] && [ "$url" != "unknown" ] || return 0
  [ "$(cat "$HOOK_LAST" 2>/dev/null)" = "$url" ] && { echo "HOOK_SKIPPED_ALREADY_SENT"; return 0; }
  post "Tailscale auf grok-bot braucht Login: $url" && echo "$url" > "$HOOK_LAST"
}
# Official static install into /usr/local/bin (no apt). Validates official SHA256; cleans temp.
install_static() {
  local arch tgz url tmp expect got dir
  case $(uname -m) in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv6l) arch=arm ;;
    i386|i686) arch=386 ;;
    *) echo "INSTALL_FAILED unsupported_arch=$(uname -m)"; return 1 ;;
  esac
  tgz="tailscale_${TS_STATIC_VER}_${arch}.tgz"
  url="https://pkgs.tailscale.com/stable/${tgz}"
  tmp=$(mktemp -d /tmp/ts-static.XXXXXX) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  curl -fsSL --connect-timeout 30 --max-time 180 -o "$tmp/$tgz" "$url" || return 1
  curl -fsSL --connect-timeout 30 --max-time 60 -o "$tmp/$tgz.sha256" "${url}.sha256" || return 1
  expect=$(awk '{print $1}' "$tmp/$tgz.sha256")
  got=$(sha256sum "$tmp/$tgz" | awk '{print $1}')
  [ -n "$expect" ] && [ "$expect" = "$got" ] || { echo "INSTALL_FAILED sha256_mismatch"; return 1; }
  tar -xzf "$tmp/$tgz" -C "$tmp" || return 1
  dir="$tmp/tailscale_${TS_STATIC_VER}_${arch}"
  [ -x "$dir/tailscale" ] && [ -x "$dir/tailscaled" ] || return 1
  cp -a "$dir/tailscale" /usr/local/bin/tailscale || return 1
  cp -a "$dir/tailscaled" /usr/local/bin/tailscaled || return 1
  chmod 755 /usr/local/bin/tailscale /usr/local/bin/tailscaled
  [ -x /usr/local/bin/tailscale ] && [ -x /usr/local/bin/tailscaled ]
}
# --- install / start precheck (bounded re-exec) ---
if [ ! -x /usr/local/bin/tailscale ] || [ ! -x /usr/local/bin/tailscaled ]; then
  [ "${TS_CHECK_REEXEC:-0}" -ge 1 ] && { echo "INSTALL_FAILED"; exit 1; }
  export TS_CHECK_REEXEC=1
  install_static || { echo "INSTALL_FAILED"; exit 1; }
  TS_DAEMON=/usr/local/bin/tailscaled
  exec "$0" "$@"
fi
TS_DAEMON=/usr/local/bin/tailscaled
if ! pgrep -x tailscaled >/dev/null; then
  if [ "${TS_CHECK_STARTED:-0}" -eq 0 ]; then
    export TS_CHECK_STARTED=1
    nohup "$TS_DAEMON" --state=$STATE --socket=$SOCK >> $LOG 2>&1 9>&- &
    for i in $(seq 1 10); do pgrep -x tailscaled >/dev/null && break; sleep 1; done
    exec "$0" "$@"
  fi
fi
# Stream up --ssh: notify each distinct URL, wait until up completes (no early kill).
wait_up_ssh() {
  local line u url printed=0
  url="-"
  while IFS= read -r line || [ -n "$line" ]; do
    u=$(printf '%s\n' "$line" | grep -oE 'https://login\.tailscale\.com/[^ ]+' | head -1)
    [ -n "$u" ] || continue
    url=$u
    [ "$printed" -eq 0 ] && { echo "NEEDS_LOGIN $url"; printed=1; }
    notify_login "$url"
  done < <(stdbuf -oL -eL tailscale up --ssh 2>&1 9>&-)
  printf '%s\n' "$url"
}
s=$(st)
if [ "${s%% *}" = "NeedsLogin" ]; then
  url=$(wait_up_ssh)
  s=$(st)
  if pgrep -x tailscaled >/dev/null && [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ]; then
    echo 0 > "$OFF_CNT"; echo "OK $s"; exit 0
  fi
  echo "NEEDS_LOGIN ${url:-unknown}"; exit 2
fi
if pgrep -x tailscaled >/dev/null && [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ]; then
  echo 0 > "$OFF_CNT"; echo "OK $s"; exit 0
fi
n=$(( $(cat "$OFF_CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$OFF_CNT"
if [ "$n" -lt "$OFFLINE_THRESHOLD" ]; then echo "OFFLINE $n/$OFFLINE_THRESHOLD ${s:-no-daemon}"; exit 0; fi
pkill -TERM -x tailscaled; for i in $(seq 1 10); do pgrep -x tailscaled >/dev/null || break; sleep 1; done
nohup "$TS_DAEMON" --state=$STATE --socket=$SOCK >> $LOG 2>&1 9>&- &
for i in $(seq 1 25); do
  s=$(st)
  if [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ]; then
    echo 0 > "$OFF_CNT"; echo "RESTARTED_OK $s"; exit 0
  fi
  [ "${s%% *}" = "NeedsLogin" ] && break; sleep 1
done
if [ "${s%% *}" = "NeedsLogin" ]; then
  url=$(wait_up_ssh)
  s=$(st)
  if pgrep -x tailscaled >/dev/null && [ "$(echo $s | cut -d' ' -f1-2)" = "Running True" ]; then
    echo 0 > "$OFF_CNT"; echo "OK $s"; exit 0
  fi
  echo "NEEDS_LOGIN ${url:-unknown}"; exit 2
fi
echo "RESTART_FAILED $s"; exit 1
