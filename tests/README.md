# mod_audio_fork tests

Two-layer suite. Both layers run against a real FreeSWITCH instance; we
don't try to mock libfreeswitch.

| Layer | File | What it covers | Runtime |
|---|---|---|---|
| Smoke | [smoke.sh](smoke.sh) | Build, .so symbols, module load, API surface, bad-input handling | ~10s |
| Protocol | [protocol_test.sh](protocol_test.sh) | End-to-end wire protocol against a mock WS peer | ~12s |

## Prerequisites

- Docker (for the FS container + isolated builder image)
- `voiceagent-fs:latest` image already built — this gives us a FS with the
  necessary SDK headers and matching `libfreeswitch.so`. Build it with
  `voice-agent/deploy/fs/build.sh` if it's missing.
- `voiceagent-fs` container running — `make fs-up` in voice-agent.
- For the protocol test only: `python3` with the `websockets` package
  (`pip install websockets`).

## Run

```bash
# from this repo root
./tests/smoke.sh
./tests/protocol_test.sh
```

Both exit non-zero on failure and print which assertion was the first
to fail. The protocol test additionally preserves the mock server log
at `/tmp/mod_audio_fork_mock_<pid>.log` on failure for postmortem.

## What `smoke.sh` checks

1. **Build**: `cmake -S . -B build && cmake --build build` produces
   `mod_audio_fork.so` of non-zero size.
2. **Symbols**: `nm -D` shows `mod_audio_fork_module_interface`,
   `mod_audio_fork_load`, `mod_audio_fork_shutdown`. (FreeSWITCH won't
   load a module missing any of these.)
3. **Module load**: `module_exists mod_audio_fork` returns `true`.
4. **API surface**: the USAGE banner advertises every subcommand we
   ship (`start`, `stop`, `send_text`, `pause`, `resume`, `stop_play`,
   `graceful-shutdown`) and the three bidirectional-audio parameters.
5. **Failure modes**: empty args print `-USAGE`; a fabricated UUID
   returns `-ERR Operation Failed`; FS container is still healthy
   after the probes.

## What `protocol_test.sh` checks

A real call is originated against an inline test dialplan (`extension
7900`, installed at start, removed at end). The dialplan answers,
plays a 20-second silence stream so RTP flows, then hangs up. The
test attaches `uuid_audio_fork` to the parked B-leg, pointed at a
Python mock WebSocket server running on the host.

Assertions:

1. **CONNECT** — the WS handshake succeeds with the
   `audio.drachtio.org` subprotocol.
2. **Initial metadata** — the first text frame is the metadata blob
   passed to `start` (here `{}`).
3. **Binary audio flow** — at least N binary frames arrive, each the
   expected 320 bytes (20ms @ 8kHz mono L16).
4. **Server-initiated `killAudio` doesn't crash** — the mock fires a
   `killAudio` at t=2s; the test continues through t=4s receiving
   more frames (implicit crash check).
5. **Clean detach on stop** — after `uuid_audio_fork stop`, at most a
   handful of in-flight frames drain from the lws write buffer, then
   the count is frozen (a 1s settle window with zero new frames).
6. **FS still healthy** — the container's healthcheck still reports
   healthy after the test.

## What the suite does *not* cover

- **Caller-side audio playback** of inbound `playAudio` / binary
  streams — we'd need a real SIP client (Zoiper etc.) with audio
  capture to verify the caller hears what the server sends.
- **`mark` / `clearMarks` event roundtrip** end-to-end — possible to
  add: send `mark` JSON from the mock, wait for the `mark` text frame
  back with `event:"playout"`. Skipped for now because triggering a
  playout requires sending audio via the playAudio path on a call that
  has `SMBF_WRITE_REPLACE` enabled, and our test dialplan doesn't.
- **Resampling correctness** — we don't validate that the resampler
  output is intelligible, only that frames flow.
- **Memory safety under load** — would need a long soak with
  valgrind/ASan; out of scope for a CI-friendly suite.

## Mock server scripting

`mock_ws_server.py --script` accepts pipe-separated `delay:type:json`
stimuli to drive the module:

```bash
python3 tests/mock_ws_server.py \
    --port 9099 \
    --log /tmp/m.log \
    --timeout 30 \
    --script "1.0:playAudio:{\"audioContent\":\"...\",\"audioContentType\":\"raw\",\"sampleRate\":8000}|3.0:killAudio:{}|5.0:mark:{\"name\":\"after-greeting\"}"
```

Each entry is `delay-seconds:type-string:data-json`. The mock wraps
each `{"type": ..., "data": ...}` and sends as a text frame.
