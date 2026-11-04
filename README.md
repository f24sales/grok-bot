# grok-bot

Tailscale-Watchdog für den Rechner `grok-bot`.

## ts-check.sh

Installiert unter `/usr/local/bin/ts-check.sh` (root, 755), Aufruf: `sudo /usr/local/bin/ts-check.sh`.

- Prüft `tailscaled`: BackendState und ob die Maschine wirklich online ist (`Self.Online`).
- „Eingeloggt“ (gültiger Schlüssel) und „online“ (aktive Verbindung zum Tailscale-Server) sind getrennte Zustände. Eine Maschine kann eingeloggt, aber offline sein, z. B. wenn der Control-Long-Poll wiederholt abläuft.
- Offline: Zähler in `/var/lib/tailscale/offline_count` wird erhöht. Ab `OFFLINE_THRESHOLD` (Standard 1, also sofort) Offline-Checks in Folge wird `tailscaled` neu gestartet und das Ergebnis an OpenClaw gemeldet. Bei `OK` wird der Zähler zurückgesetzt.
- Braucht Tailscale einen Login (`NeedsLogin`): holt die Auth-URL (notfalls per `tailscale up`) und schickt sie an OpenClaw (`$OPENCLAW_URL/mcp/direct`, Bearer-Auth), einmal pro URL.

Ausgaben und Exit-Codes:

| Ausgabe | Exit | Meldung an OpenClaw |
|---|---|---|
| `OK …` | 0 | nein |
| `OFFLINE n/N …` | 0 | nein |
| `RESTARTED_OK …` (+ `HOOK_HTTP <code>`) | 0 | ja |
| `RESTART_FAILED …` (+ `HOOK_HTTP <code>`) | 1 | ja |
| `NEEDS_LOGIN <url>` (+ `HOOK_HTTP <code>` / `HOOK_SKIPPED_ALREADY_SENT`) | 2 | ja, einmal pro URL |

## Hook-Konfiguration

Datei `/home/box/.config/ts-watchdog/env` (600, **nicht im Repo**):

```sh
OPENCLAW_URL='https://…'
OPENCLAW_MCP_BRIDGE_BEARER='…'
```

Fehlt die Datei, wird kein Hook gefeuert. Die zuletzt gesendete Login-URL steht in `/var/lib/tailscale/last_auth_hook_url`.

## Auslöser

Eine Grok-Bot-Routine („Tailscale-Check per Webhook“) ruft das Skript per Webhook auf. Bei `OK` und `OFFLINE n/N` bleibt sie still. Hat die OpenClaw-Meldung geklappt (HTTP 2xx), meldet sie sich auch sonst nicht im Chat, nur bei Fehlern.
