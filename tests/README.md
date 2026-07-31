# mod_audio_fork tests

Two-layer suite. Both layers run against a real FreeSWITCH instance; we
don't try to mock libfreeswitch.

| Layer | File | What it covers | Runtime |
|---|---|---|---|
| Unit | [ws_uri_test.cpp](ws_uri_test.cpp) | URI parsing, 44 table-driven cases. No FS dependency — run by smoke.sh step 1b | ~1s |
| Unit | [throttle_test.cpp](throttle_test.cpp) | PR-2 drop-report throttle arithmetic, 16 cases. Header-only, links nothing | <1s |
| Contention | [contention_test.sh](contention_test.sh) | PR-2: provoke mutex contention and assert it is counted. ⚠ **SKIPs on this hardware** — see below | ~15s |
| Smoke | [smoke.sh](smoke.sh) | Build, unit tests, .so symbols, module install + load, API surface, bad-input handling | ~40s |
| Protocol | [protocol_test.sh](protocol_test.sh) | End-to-end wire protocol against a mock WS peer | ~15s |

## ★★★ Three ways this suite used to lie — read before trusting a green run

All three were found in one sitting while writing PR-1, and all three produce
**all-PASS output while testing something other than what you changed.**

**① The build artifact was thrown away.** `smoke.sh` compiled the module inside
a `docker run --rm` container and extracted only its size and `nm` output. Steps
3-5 then `docker exec`'d into a running FS and probed the module **baked into
that image**. Measured: the container's .so was 239,120 bytes dated May 25 while
step 1 had just produced 323,008 bytes. Two different binaries, two months apart.
⇒ Fixed: the build lands on the host, is installed into the container, and a
sha256 comparison is asserted.

**② `reload mod_audio_fork` reports success while failing.** Its real output is

    +OK Reloading XML
    -ERR unloading module [Module in use.]

The first line is about XML. The old assertion grepped for `/\+OK|Reload/i` and
matched it, so the new .so sat on disk, the sha256 check said "that is the file I
built", and FreeSWITCH kept executing the OLD code from memory. A file-level sha
proves the FILE, never the RUNNING CODE.
⇒ Fixed: the container is **restarted**, not reloaded. `unload` fails with
"Module in use." whenever any channel holds a media bug, which is most of the
time. Until PR-3 lands (`audio_fork_version`, a module that reports its own
identity), the restart is what makes "is FS running my build?" answerable.

**③ The builder image was a different FreeSWITCH than the target.** `BASE_IMAGE`
defaulted to `voiceagent-fs:latest` (1st generation) while the module was
installed into `duckcall-fs` (4th generation) — two FS builds, two different
`libfreeswitch.so.1`. The symptom is a message that sends you looking in
completely the wrong place:

    Error Loading module /usr/local/freeswitch/mod/mod_audio_fork.so
    cannot open shared object file: No such file or directory

for a file that is present, owned correctly, with every NEEDED library
resolvable.
⇒ Fixed: `BASE_IMAGE` is derived from `FS_CONTAINER`'s image so "compiled
against" and "loaded into" cannot drift apart, and `BUILDER_IMAGE` carries the
base in its tag so switching bases cannot reuse the wrong builder.

## ⚠⚠ PR-2's drop counter is verified by construction, NOT by observation

`contention_test.sh` **cannot provoke contention on this hardware.** Measured:
6000 flooded `clearMarks` → 0 skipped frames; 400 × 32KB flooded `playAudio` →
0 skipped frames. The mutex is held for microseconds while `fork_frame` only
retries every 20ms, so the trylock never loses. That agrees with S2' (0.03ms
jitter at 10 concurrent sessions, no inflection point) — and it is exactly why
PR-5/6/7 were dropped from the roadmap.

⇒ The script **SKIPs** rather than fails, because a permanently-red test trains
people to ignore it. But it distinguishes the two causes first: if the
else-branch in `fork_frame` is gone it **FAILs** (grep on `lws_glue.cpp`), since
"the counter was deleted" is a different thing from "this machine has no
contention". Verified by mutation: changing that log string turns the SKIP into
a FAIL.

**What is covered**: the throttle arithmetic (`throttle_test.cpp`, 16 cases
including the `every == 0` guard that must fall back rather than fire on every
frame) and the presence of the counting branch.

**What is NOT covered**: that a real trylock failure reaches the counter. It has
never been observed firing. ⇒ Do not report PR-2 as "verified end to end".

**★ And a fourth, about mutation testing rather than the harness:** two
mutations written as `else if (0) { } else if (...)` were folded away by the
compiler — the .so came out byte-identical and the mutations appeared to
"survive". The sha256 from ① is what exposed it. A mutation is only evidence
once the artifact has been seen to change.

## Prerequisites

- Docker (for the FS container + isolated builder image)
- **A running FreeSWITCH container with mod_audio_fork registered.** Defaults to
  `duckcall-fs` (duck-call: `make fs-up` in `deploy/fs`); override with
  `FS_CONTAINER=<name>`. Older generations used `voiceagent-fs`.
- The builder image is created automatically **from that container's image**, so
  the SDK headers and `libfreeswitch.so` match what you load into. Override with
  `BASE_IMAGE=<image>` only if you know why (see ③ above).
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
1b. **Unit tests**: `ws_uri_test` runs its 44-case table. It refuses to report
   success under 40 checks, and smoke.sh independently requires the
   "N checks passed" line — neither side can go vacuous alone.
3. **Module install + load**: the freshly built .so is copied in, the container
   is **restarted**, `module_exists mod_audio_fork` returns `true`, and the
   in-container sha256 matches what was just built. See ① ② ③ above for why each
   of those three steps is load-bearing.
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

0. **Rejected arguments leave no media bug** (step 2b) — an out-of-range port
   and a sample rate that is not a multiple of 8000 must both be refused, and a
   subsequent *good* start must still succeed. `start_capture` attaches the
   media bug **before** it connects, so a validation failure that falls through
   leaves a dangling bug on a live call. ★ Measured: without the guards both
   bad inputs return **+OK Success** — see PR-1.
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
