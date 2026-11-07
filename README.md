# grok-bot

Tailscale watchdog for the machine `grok-bot`, plus a host-side webhook keepalive.

- On the Grok Bot machine: [`ts-check.sh`](#ts-checksh) checks Tailscale and forwards login links when needed.
- On the always-on host: [`webhook_ping.py`](#host-keepalive-webhook_pingpy) triggers the Grok Bot routine once or every minute.

## ts-check.sh

Installed at `/usr/local/bin/ts-check.sh` (root, 755). Invocation: `sudo /usr/local/bin/ts-check.sh`.

The script checks `tailscaled`, installs the pinned static binaries when either one is missing, starts the daemon, and posts Tailscale login URLs to the configured OpenClaw hook. It does not call Telegram. It does not enable a boot service. Binaries copied to `/usr/local/bin` and the state file path remain on disk; a `nohup` process is not a guarantee that the daemon is still running later.

### Prerequisites

Run it as root. The script does not check the user id. Install and startup write `/usr/local/bin`, `/var/lib/tailscale`, `/var/run/tailscale`, `/var/log/tailscaled.log`, and a temporary directory under `/tmp`. The script does not create the state or socket directories.

Commands it calls: `curl`, `tar`, `sha256sum`, `awk`, `python3`, `stdbuf`, `mktemp`, `readlink`, `dirname`, `uname`, `cp`, `chmod`, `nohup`, `pgrep`, `pkill`, `grep`, `head`, `cat`, and `seq`. `tailscale status` and `tailscale up` are invoked by name, so `/usr/local/bin` has to be on `PATH`.

### Install

The script requires both `/usr/local/bin/tailscale` and `/usr/local/bin/tailscaled` to be executable. If either file is missing or not executable, it installs both, then re-executes itself once (`TS_CHECK_REEXEC`). If that next run still does not see both binaries, it prints `INSTALL_FAILED` and exits 1. It does not retry the download in a loop.

The install is the official static tarball pinned to `1.104.5` (`TS_STATIC_VER`). This script does not use apt or Tailscale's `install.sh`. Publishing a newer stable build does not move the pin; change `TS_STATIC_VER` in the script deliberately to upgrade. The checksum is not stored in the script. Each attempt downloads the official `.sha256` file for that exact tarball.

Architecture comes from `uname -m`:

| `uname -m` | tarball arch |
|---|---|
| `x86_64`, `amd64` | `amd64` |
| `aarch64`, `arm64` | `arm64` |
| `armv7l`, `armv6l` | `arm` |
| `i386`, `i686` | `386` |

Any other machine prints `INSTALL_FAILED unsupported_arch=<machine>` and stops.

The script downloads:

- `https://pkgs.tailscale.com/stable/tailscale_1.104.5_<arch>.tgz` (connect timeout 30s, max 180s)
- `https://pkgs.tailscale.com/stable/tailscale_1.104.5_<arch>.tgz.sha256` (connect timeout 30s, max 60s)

It compares `sha256sum` of the tarball with the first field of the official checksum file. An empty or different value prints `INSTALL_FAILED sha256_mismatch` and stops. The temporary directory is removed when the install function returns.

On a matching checksum it extracts the archive, requires `tailscale` and `tailscaled` inside it to be executable, copies both to `/usr/local/bin`, and sets mode 755. It stops unless both installed paths are executable. `unsupported_arch` and `sha256_mismatch` are each followed by a second line, `INSTALL_FAILED`, from the caller. A download, extract, or copy failure prints only that caller line. Nothing is posted to OpenClaw.

### Daemon start

After both binaries are present, the script starts `/usr/local/bin/tailscaled` only when `pgrep -x tailscaled` finds no process. That start happens once per run (`TS_CHECK_STARTED`):

```sh
nohup /usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >> /var/log/tailscaled.log 2>&1 &
```

It waits up to 10 seconds for the process name to appear, then re-executes the script. It does not start another daemon in that same run.

### Checks

Status comes from `tailscale status --json`: BackendState, `Self.Online`, and `AuthURL`. "Logged in" (valid key) and "online" (active connection to the Tailscale server) are separate states. A machine can be logged in but offline, for example when the control long-poll expires repeatedly.

The script then does one of the following, in this order:

1. If BackendState is `NeedsLogin`, it runs `tailscale up --ssh` and waits until that command exits. It does not kill `up` and it does not add a timeout of its own. While `up` is running, every `https://login.tailscale.com/…` URL that differs from `/var/lib/tailscale/last_auth_hook_url` is posted immediately to the configured OpenClaw hook. After `up` exits, status is read once. `tailscaled` running with `Running` and online resets `/var/lib/tailscale/offline_count`, prints `OK`, and exits 0. Otherwise it prints `NEEDS_LOGIN` and exits 2. It does not start `tailscale up` a second time on this path, and it does not increment the offline counter.
2. If `tailscaled` is running and status is `Running` with `Self.Online` true, it resets the same counter, prints `OK`, and exits 0.
3. Otherwise it increments the counter. While the new count is below `OFFLINE_THRESHOLD`, it prints `OFFLINE n/N` and exits 0, with no restart and no OpenClaw message. The default threshold is 1, so this exit is used only when `OFFLINE_THRESHOLD` is set above that count. At the threshold it sends `SIGTERM` to `tailscaled`, waits up to 10 seconds for it to exit, starts `/usr/local/bin/tailscaled` again, and polls status up to 25 times, one second apart. `Running` and online prints `RESTARTED_OK` and exits 0. A poll that reports `NeedsLogin` stops the polling and uses the same `tailscale up --ssh` wait as step 1, then prints `OK` or `NEEDS_LOGIN`. A restart is not posted to OpenClaw. If the polls end on any other state, the script prints `RESTART_FAILED` and exits 1.

A URL already stored after HTTP 2xx is skipped (`HOOK_SKIPPED_ALREADY_SENT`). A post that does not get 2xx does not update the saved URL, so a later line with the same URL can be posted again. That is not a fixed pair of auth prompts.

Stdout from the `tailscale up --ssh` wait, including `NEEDS_LOGIN`, `HOOK_HTTP`, and `HOOK_SKIPPED_ALREADY_SENT`, is collected by the caller. On `OK` that collected text is not printed. On a still-needed login, the `NEEDS_LOGIN` status includes it.

### Outputs and exit codes

| Output | Exit | Message to OpenClaw |
|---|---|---|
| `OK …` | 0 | no |
| `OFFLINE n/N …` | 0 | no |
| `RESTARTED_OK …` | 0 | no |
| `RESTART_FAILED …` | 1 | no |
| `INSTALL_FAILED` (also `unsupported_arch=<machine>` or `sha256_mismatch`) | 1 | no |
| `NEEDS_LOGIN <url>` | 2 | yes, for a URL that is not the last saved URL; the saved URL changes only after HTTP 2xx |

## Hook configuration

Copy `ts-check_example.env` to `ts-check.env` (next to `ts-check.sh`, `chmod 600`) and fill it in. `ts-check.env` is listed in `.gitignore` and never enters the repo.

```sh
OPENCLAW_URL='https://…'
OPENCLAW_MCP_BRIDGE_BEARER='…'
```

The script looks for `ts-check.env` in its own directory (symlinks are resolved); the fallback is `/home/box/.config/ts-watchdog/env`. If neither file can be read, or `OPENCLAW_URL` or `OPENCLAW_MCP_BRIDGE_BEARER` is empty, no hook is fired. A post is JSON `{"text": …}` to `$OPENCLAW_URL/mcp/direct` with `Authorization: Bearer` and a 15-second limit. The text is the fixed notice in the script, `Tailscale auf grok-bot braucht Login: <url>`. The URL is written to `/var/lib/tailscale/last_auth_hook_url` only after a 2xx response. Any other result prints `HOOK_HTTP <code>` and leaves the saved URL unchanged, so a later attempt can try that URL again.

## Trigger

A Grok Bot routine ("Tailscale check via webhook") calls the script via webhook. Only a login URL is sent to OpenClaw, and only from `NeedsLogin`. On `OK`, `OFFLINE n/N`, and `RESTARTED_OK` the routine stays silent; in chat it reports only if the login link could not be delivered or a restart fails twice.

## Host keepalive: webhook_ping.py

The host calls the **Grok Bot keepalive/Tailscale routine webhook** with an authenticated POST:

```json
{"source": "keepalive"}
```

The minute ping is used in this setup to keep the Grok Bot cloud machine (the operator's AWS machine) awake by regularly triggering work, including the Tailscale check. Run this sender on an always-on host outside the Grok Bot machine, so the trigger continues when that machine is sleeping. Continued availability depends on the host, network and Grok Bot accepting and executing the routine; the ping cannot guarantee the cloud machine's lifetime or prevent a provider reset.

This is a separate webhook from `litellm-free-cursor.service`, which sends a published model YAML URL and scan timestamp. It also differs from the OpenClaw hook that receives a Tailscale login URL from `ts-check.sh`. Use the **keepalive routine's own URL and bearer key** here.

### Install on the sending host

Requirements: Python 3, the Python `requests` package (commonly packaged as `python3-requests`), and a running systemd user manager. Check that the same interpreter used by the service can import the dependency:

```sh
/usr/bin/python3 -c 'import requests'
```

Run the following from this repository's root as the host user who will run the timer:

```sh
install -m 700 webhook_ping.py "$HOME/webhook_ping.py"
install -d -m 700 "$HOME/.config/grok-bot"
install -d "$HOME/.config/systemd/user"
install -m 644 webhook-ping.service webhook-ping.timer "$HOME/.config/systemd/user/"
# Create the local config only if it does not already exist.
if [ ! -e "$HOME/.config/grok-bot/webhook-ping.env" ]; then
    install -m 600 webhook-ping_example.env "$HOME/.config/grok-bot/webhook-ping.env"
fi
```

Edit `~/.config/grok-bot/webhook-ping.env` and replace both placeholders with the URL and bearer key from the Grok Bot keepalive routine. Keep mode `600`. The service reads this file directly, so credentials do not need to be imported into the systemd manager environment. No real webhook address or key is included in this repository. Local `webhook-ping.env` files are gitignored.

```sh
systemctl --user daemon-reload
```

### One-shot: send exactly one ping

Stop an existing minute timer first if you want only one request:

```sh
systemctl --user stop webhook-ping.timer
systemctl --user start webhook-ping.service
```

The service executes `webhook_ping.py --once`, then exits. Successful one-shot services normally return to `inactive (dead)`; check `Result=success`, exit status and the log. Starting the service does not start the timer.

```sh
systemctl --user show webhook-ping.service -p Result -p ExecMainStatus
journalctl --user -u webhook-ping.service -n 10 --no-pager
```

HTTP 200 confirms the webhook request was accepted; it does not itself prove that the remote Tailscale check finished. The response may include `success` and a run ID to correlate with the Grok Bot routine.

### Every minute: keep the Grok Bot machine active

```sh
# Start the schedule. The first scheduled ping runs at the next minute boundary.
systemctl --user start webhook-ping.timer

# Optional: send a first ping immediately as well.
systemctl --user start webhook-ping.service

systemctl --user list-timers webhook-ping.timer --all --no-pager
journalctl --user -u webhook-ping.service -f
```

`OnCalendar=*-*-* *:*:00` triggers once each minute with one-second accuracy. Each activation sends one request and finishes. `Persistent=false` avoids replaying missed pings after downtime. The same service cannot run twice concurrently.

The timer deliberately has no `[Install]` section: these commands start it for the current user-manager lifetime and do **not** enable boot autostart. It must be started again after that manager stops or the host reboots. A user manager must remain running for the minute pings to continue.

### Stop the minute pings

```sh
systemctl --user stop webhook-ping.timer webhook-ping.service
```

Stopping both prevents future timer runs and ends an active sender. A webhook already accepted by Grok Bot cannot be recalled by stopping the local service.

### Standalone script behavior

The packaged systemd service always passes `--once`. The script also retains the original standalone loop: without `--once`, it sends a ping every `INTERVAL_SECONDS` seconds (default 60) while running. Supply `WEBHOOK_URL` and `WEBHOOK_KEY` in that process's environment. Do not run this loop alongside the timer unless you intentionally want two senders.

- Each POST uses `Authorization: Bearer <WEBHOOK_KEY>`, JSON content type and a 15-second request timeout.
- Missing URL or key exits before any request. In one-shot mode, non-200 responses and network errors exit nonzero.
- In standalone loop mode, HTTP 401, 403 or 404 ends the process. HTTP 429 adds an exponential backoff from 60 to 900 seconds; HTTP 200 resets it. The systemd timer instead makes a fresh one-shot attempt each minute.
- `SIGINT` or `SIGTERM` stops the standalone loop. Changing `INTERVAL_SECONDS` does not change the systemd timer's calendar.

