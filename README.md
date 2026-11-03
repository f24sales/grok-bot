# grok-bot

Tailscale-Watchdog für den Rechner `grok-bot`.

## ts-check.sh

Installiert unter `/usr/local/bin/ts-check.sh` (root, 755), Aufruf: `sudo /usr/local/bin/ts-check.sh`.

- Prüft `tailscaled` (BackendState + Online).
- Läuft er nicht oder ist offline: Neustart, danach erneute Prüfung.
- Braucht Tailscale einen Login (`NeedsLogin`): holt die Auth-URL und schickt sie per Webhook an OpenClaw (`$OPENCLAW_URL/mcp/direct`, Bearer-Auth), einmal pro URL.

Ausgaben (eine Zeile) und Exit-Codes:

| Ausgabe | Exit |
|---|---|
| `OK …` | 0 |
| `RESTARTED_OK …` | 0 |
| `NEEDS_LOGIN <url>` (+ `HOOK_HTTP <code>` / `HOOK_SKIPPED_ALREADY_SENT`) | 2 |
| `RESTART_FAILED …` | 1 |

## Hook-Konfiguration

Datei `/home/box/.config/ts-watchdog/env` (600, **nicht im Repo**):

```sh
OPENCLAW_URL='https://…'
OPENCLAW_MCP_BRIDGE_BEARER='…'
```

Fehlt die Datei, wird kein Hook gefeuert. Die zuletzt gesendete URL steht in `/var/lib/tailscale/last_auth_hook_url`.

## Auslöser

Eine Grok-Bot-Routine ("Tailscale-Check per Webhook") ruft das Skript per Webhook auf. Bei `OK` bleibt sie still, damit keine LLM-Tokens verbraucht werden.
