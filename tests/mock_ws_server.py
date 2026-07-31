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


async def handle_connection(ws, log_path: Path, script: list, flood=None,
                            flood_bytes: int = 32768):
    log_event(log_path, "CONNECT", subprotocol=ws.subprotocol or "")

    async def send_script():
      try:
        for delay, payload in script:
            await asyncio.sleep(delay)
            # ⚠ `ws.open` is gone in websockets >= 14 — see send_flood.
            text = json.dumps(payload)
            await ws.send(text)
            log_event(log_path, "SENT_TEXT", payload=payload)
      except websockets.exceptions.ConnectionClosed:
        pass
      except Exception as e:            # noqa: BLE001 - must never be silent
        log_event(log_path, "SCRIPT_ERROR", error=f"{type(e).__name__}: {e}")

    async def send_flood():
        """Hammer the module with text messages to provoke mutex contention.

        ★ Why this exists: fork_frame() takes tech_pvt->mutex with trylock and
          skips the frame on failure. Producing that failure needs someone else
          holding the mutex, and the only paths that do are inside
          processIncomingMessage — i.e. server-sent text. A `sleep` in the mock
          would not contend for anything.

        ⚠ `clearMarks` is the cheapest of them: it takes the lock, flushes an
          (empty) queue and releases. No base64, no allocation — so the flood is
          bounded by how fast we can send, which is the point.
        """
        if not flood:
            return
        start, count, kind = flood
        if kind == "playAudio":
            # ★ playAudio is the realistic contention source: processIncomingMessage
            #   holds tech_pvt->mutex across the base64 decode AND the insert into
            #   the playout circular buffer. `clearMarks` only flushes an empty
            #   queue — measured: 6000 of those provoked zero trylock failures,
            #   because the hold is far shorter than the 20ms frame interval.
            import base64
            blob = base64.b64encode(b"\x00\x01" * (flood_bytes // 2)).decode()
            payload = json.dumps({"type": "playAudio", "data": {
                "audioContent": blob, "audioContentType": "raw",
                "sampleRate": 8000}})
        else:
            payload = json.dumps({"type": kind, "data": {}})
        sent = 0
        # ⚠ No `ws.open` check: websockets >= 14 removed that attribute, and an
        #   AttributeError inside an asyncio task is SWALLOWED — the flood simply
        #   never happened and the log said nothing. (Measured: first run of this
        #   test reported "the flood did not run (sent=none)" with no clue why.)
        #   ⇒ Rely on ConnectionClosed instead, and report every failure.
        try:
            await asyncio.sleep(start)
            for _ in range(count):
                await ws.send(payload)
                sent += 1
        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as e:          # noqa: BLE001 - must never be silent
            log_event(log_path, "FLOOD_ERROR", kind=kind, sent=sent,
                      error=f"{type(e).__name__}: {e}")
            return
        log_event(log_path, "FLOOD_DONE", kind=kind, sent=sent)

    script_task = asyncio.create_task(send_script())
    flood_task = asyncio.create_task(send_flood())

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
        flood_task.cancel()


async def main_async(args):
    log_path = Path(args.log)
    log_path.write_text("")  # truncate

    # Parse --script "1.0:playAudio:{}|2.5:mark:{name:m1}|..." into a list of
    # (delay, json_payload). Empty / missing => no scripted sends.
    script: list = []
    flood = None
    if args.flood:
        parts = args.flood.split(":", 2)
        if len(parts) != 3:
            raise SystemExit("--flood wants START_SECS:COUNT:TYPE")
        flood = (float(parts[0]), int(parts[1]), parts[2])

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
        lambda ws: handle_connection(ws, log_path, script, flood, args.flood_bytes),
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
    p.add_argument("--flood-bytes", type=int, default=32768,
                   help="playAudio payload size in raw PCM bytes (default 32768)")
    p.add_argument("--flood", default="",
                   help="provoke mutex contention: START_SECS:COUNT:TYPE, "
                        "e.g. 1.0:3000:clearMarks (see send_flood)")
    p.add_argument("--script", default="",
                   help='Pipe-separated test stimuli: "delay:type:json|delay:type:json"')
    args = p.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
