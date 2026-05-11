#!/usr/bin/env python3
"""
Minimal WebSocket server for protocol-level testing of mod_audio_fork.

Listens on a port, accepts the `audio.drachtio.org` subprotocol, then
records every event (connect, text frame, binary frame, disconnect) to a
log file as line-delimited JSON. The orchestrator script asserts against
that log.

Optionally fires test stimuli at the module — `playAudio`, `killAudio`,
`mark` etc. — based on a simple script of (delay_seconds, json_message)
pairs read from `--script`.

Stdlib-only on Python 3.11+ — uses websockets via asyncio, no external
dependencies beyond a `pip install websockets` if not present.

Exits when:
  * Connection closes (either side), OR
  * `--timeout` seconds have passed without a connection, OR
  * SIGTERM
"""

import argparse
import asyncio
import json
import signal
import sys
import time
from pathlib import Path

try:
    import websockets
except ImportError:
    print("ERROR: pip install websockets", file=sys.stderr)
    sys.exit(2)


def log_event(log_path: Path, event_type: str, **fields):
    line = json.dumps({"t": time.time(), "event": event_type, **fields})
    with log_path.open("a") as f:
        f.write(line + "\n")


async def handle_connection(ws, log_path: Path, script: list):
    log_event(log_path, "CONNECT", subprotocol=ws.subprotocol or "")

    async def send_script():
        for delay, payload in script:
            await asyncio.sleep(delay)
            if not ws.open:
                return
            text = json.dumps(payload)
            await ws.send(text)
            log_event(log_path, "SENT_TEXT", payload=payload)

    script_task = asyncio.create_task(send_script())

    try:
        async for message in ws:
            if isinstance(message, bytes):
                log_event(log_path, "RECV_BINARY", bytes=len(message))
            else:
                # text — try to parse as JSON, log the type if so
                try:
                    parsed = json.loads(message)
                    log_event(log_path, "RECV_TEXT",
                              kind=parsed.get("type") if isinstance(parsed, dict) else None,
                              raw=message)
                except json.JSONDecodeError:
                    log_event(log_path, "RECV_TEXT", kind=None, raw=message)
    except websockets.exceptions.ConnectionClosed as e:
        log_event(log_path, "DISCONNECT", code=e.code, reason=str(e.reason) or "")
    finally:
        script_task.cancel()


async def main_async(args):
    log_path = Path(args.log)
    log_path.write_text("")  # truncate

    # Parse --script "1.0:playAudio:{}|2.5:mark:{name:m1}|..." into a list of
    # (delay, json_payload). Empty / missing => no scripted sends.
    script: list = []
    if args.script:
        for entry in args.script.split("|"):
            entry = entry.strip()
            if not entry:
                continue
            delay_s, type_s, data_json = entry.split(":", 2)
            payload = {"type": type_s, "data": json.loads(data_json) if data_json else {}}
            script.append((float(delay_s), payload))

    stop_event = asyncio.Event()

    def shutdown(*_):
        stop_event.set()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    async with websockets.serve(
        lambda ws: handle_connection(ws, log_path, script),
        args.host, args.port,
        subprotocols=["audio.drachtio.org"],
    ):
        log_event(log_path, "LISTEN", host=args.host, port=args.port)
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=args.timeout)
        except asyncio.TimeoutError:
            log_event(log_path, "TIMEOUT", seconds=args.timeout)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=9099)
    p.add_argument("--log", required=True, help="path to event log (NDJSON)")
    p.add_argument("--timeout", type=float, default=30.0,
                   help="auto-exit after this many seconds")
    p.add_argument("--script", default="",
                   help='Pipe-separated test stimuli: "delay:type:json|delay:type:json"')
    args = p.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
