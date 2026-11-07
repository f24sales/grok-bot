#!/usr/bin/env python3
"""Trigger the Grok Bot keepalive routine once or every minute."""
import os
import signal
import sys
import time

import requests

URL = os.environ.get("WEBHOOK_URL")
KEY = os.environ.get("WEBHOOK_KEY")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "60"))
ONCE = "--once" in sys.argv[1:]

if not URL:
    sys.exit("WEBHOOK_URL is not set")

if not KEY:
    sys.exit("WEBHOOK_KEY is not set")

running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

session = requests.Session()
backoff = 0
while running:
    started = time.monotonic()
    try:
        response = session.post(
            URL,
            headers={
                "Authorization": f"Bearer {KEY}",
                "Content-Type": "application/json",
            },
            json={"source": "keepalive"},
            timeout=15,
        )
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        response_text = " ".join(response.text.split())[:200]
        if response.status_code == 200:
            print(f"[{stamp}] HTTP 200 response={response_text!r}", flush=True)
            backoff = 0
        elif response.status_code == 429:
            backoff = min(max(backoff * 2, 60), 900)
            print(f"[{stamp}] HTTP 429 response={response_text!r}; backoff={backoff}s", flush=True)
        else:
            print(f"[{stamp}] HTTP {response.status_code} response={response_text!r}", flush=True)
            if response.status_code in (401, 403, 404):
                sys.exit(1)
    except requests.RequestException as error:
        print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] network error: {type(error).__name__}", flush=True)
        if ONCE:
            sys.exit(1)

    if ONCE:
        sys.exit(0 if response.status_code == 200 else 1)

    delay = max(0, INTERVAL - (time.monotonic() - started)) + backoff
    deadline = time.monotonic() + delay
    while running and time.monotonic() < deadline:
        time.sleep(0.5)
