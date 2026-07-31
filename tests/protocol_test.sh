#!/usr/bin/env bash
# Protocol-level test for mod_audio_fork.
#
# Exercises the actual wire protocol end-to-end:
#   1. mock WS server starts on a free port
#   2. originate a parked loopback call that plays silence (so RTP flows)
#   3. attach uuid_audio_fork at the mock server
#   4. assert the mock saw: CONNECT, initial metadata frame, ≥N binary
#      audio frames, then DISCONNECT after stop
#   5. send a `killAudio` from mock mid-call, assert FS didn't crash
#
# Requires:
#   - voiceagent-fs container running (we hit it via fs_cli)
#   - python3 + websockets package on the host
#   - sip-side test: no Zoiper needed, all originated internally
#
# Usage:
#   ./tests/protocol_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${MOCK_PORT:-9099}"
LOG="/tmp/mod_audio_fork_mock_$$.log"
MOCK_PID=""
CALL_UUID=""
# The FS container. Default is duck-call's (4th-gen); older generations used
# `voiceagent-fs`. Override with FS_CONTAINER=<name>.
FS_CONTAINER="${FS_CONTAINER:-duckcall-fs}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
MOD_PATH=/usr/local/freeswitch/mod/mod_audio_fork.so
# The ESL password comes from the container's own env — hardcoding ClueCon only
# works on a factory-default FS, and a wrong password fails as a wall of -ERR
# whose root cause is invisible.
ESL_PASS=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$FS_CONTAINER" 2>/dev/null \
    | sed -n 's/^FS_ESL_PASSWORD=//p' | head -1)
[ -n "$ESL_PASS" ] || ESL_PASS="${FS_ESL_PASSWORD:-ClueCon}"
TEST_EXT=7900   # dialplan extension we install for the duration of the test
TEST_DIALPLAN_PATH=/usr/local/freeswitch/conf/dialplan/default/99_mod_audio_fork_test.xml

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }

cleanup() {
    local code=$?
    if [ -n "$CALL_UUID" ]; then
        docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x "uuid_kill $CALL_UUID" >/dev/null 2>&1 || true
    fi
    if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    # Remove the test-only dialplan we installed.
    docker exec "$FS_CONTAINER" rm -f "$TEST_DIALPLAN_PATH" 2>/dev/null || true
    docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x "reloadxml" >/dev/null 2>&1 || true
    if [ $code -ne 0 ]; then
        red "FAILED — mock log preserved at: $LOG"
    else
        rm -f "$LOG"
    fi
}
trap cleanup EXIT

fail() { red "FAIL: $*"; exit 1; }
pass() { green "PASS: $*"; }

# Count NDJSON events of a given type.
count_event() {
    grep -c "\"event\": \"$1\"" "$LOG" 2>/dev/null || true
}

# Sum a numeric field across events of a given type.
sum_event_field() {
    local event="$1" field="$2"
    python3 -c "
import json, sys
total = 0
for line in open('$LOG'):
    try:
        d = json.loads(line)
        if d.get('event') == '$event':
            total += d.get('$field', 0)
    except json.JSONDecodeError:
        pass
print(total)
"
}

# ----------------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------------
docker inspect "$FS_CONTAINER" --format '{{.State.Status}}' 2>/dev/null | grep -q running \
    || fail "FS container '$FS_CONTAINER' not running.
  Running: $(docker ps --format '{{.Names}}' | tr '\n' ' ')
  → start one (duck-call: 'make fs-up') or set FS_CONTAINER=<name>."

# ════════════════════════════════════════════════════════════════════════════
# ★★★ Say WHICH binary this run exercises — do not leave it implied
# ════════════════════════════════════════════════════════════════════════════
#
# This script probes whatever module the running FS currently has loaded. It
# does not build anything, so on its own it cannot tell you that your change is
# being tested. That is exactly how the sibling smoke.sh silently validated a
# two-month-old module for months.
#
#   · smoke.sh ran first  ⇒ build/mod_audio_fork.so exists ⇒ assert they match
#   · it did not          ⇒ say so loudly rather than imply freshness
LOADED_SHA=$(docker exec "$FS_CONTAINER" sha256sum "$MOD_PATH" 2>/dev/null | cut -d' ' -f1)
if [ -f "$BUILD_DIR/mod_audio_fork.so" ]; then
    BUILT_SHA=$(shasum -a 256 "$BUILD_DIR/mod_audio_fork.so" 2>/dev/null | cut -d' ' -f1)
    [ -n "$BUILT_SHA" ] || BUILT_SHA=$(sha256sum "$BUILD_DIR/mod_audio_fork.so" | cut -d' ' -f1)
    if [ "$LOADED_SHA" != "$BUILT_SHA" ]; then
        fail "the loaded module is NOT the last one built
  built (build/):  $BUILT_SHA
  loaded in FS:    $LOADED_SHA
  ⇒ this run would exercise a different binary than the one you just built.
    → run ./tests/smoke.sh first (it installs + reloads the fresh module)."
    fi
    green "testing the freshly built module (sha ${BUILT_SHA:0:12}…)"
else
    bold "⚠ no build/ artifact — testing whatever FS has loaded (sha ${LOADED_SHA:0:12}…)"
    bold "  run ./tests/smoke.sh first if you want your change under test."
fi

python3 -c "import websockets" 2>/dev/null \
    || fail "python websockets package missing — pip install websockets"

# ----------------------------------------------------------------------------
# 1. Start mock with a small script: at t=2s send killAudio (forces module
#    to clear its playout buffer and signal upstream — exercises the
#    code path even though we never sent it any playAudio).
# ----------------------------------------------------------------------------
bold "[1/4] Start mock WS server on :$PORT"

python3 "$REPO_ROOT/tests/mock_ws_server.py" \
    --port "$PORT" \
    --log "$LOG" \
    --timeout 15 \
    --script "2.0:killAudio:{}" &
MOCK_PID=$!

# Wait for the mock to actually be listening.
for _ in $(seq 1 30); do
    if grep -q "\"event\": \"LISTEN\"" "$LOG" 2>/dev/null; then break; fi
    sleep 0.1
done
grep -q "\"event\": \"LISTEN\"" "$LOG" || fail "mock failed to bind :$PORT within 3s"
pass "mock listening (pid $MOCK_PID)"

# ----------------------------------------------------------------------------
# 2. Install a test-only dialplan extension that answers + plays silence
#    so RTP flows (mod_audio_fork has actual frames to forward), then
#    originate into it. Synchronous `originate` returns "+OK <uuid>" with
#    the B-leg UUID we'll attach the fork to.
# ----------------------------------------------------------------------------
bold "[2/4] Install test dialplan + originate"

docker exec -i "$FS_CONTAINER" sh -c "cat > $TEST_DIALPLAN_PATH" <<EOF
<include>
  <extension name="mod_audio_fork_test_silence">
    <condition field="destination_number" expression="^$TEST_EXT\$">
      <action application="answer"/>
      <action application="playback" data="silence_stream://20000"/>
      <action application="hangup"/>
    </condition>
  </extension>
</include>
EOF
docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x "reloadxml" >/dev/null

ORIG_OUT=$(docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x \
    "originate loopback/$TEST_EXT/default &park" 2>&1)
echo "$ORIG_OUT" | grep -q "^+OK" || fail "originate failed: $ORIG_OUT"
CALL_UUID=$(echo "$ORIG_OUT" | awk '/^\+OK/ {print $2; exit}')
[ -n "$CALL_UUID" ] || fail "could not extract UUID from: $ORIG_OUT"
pass "call answered: $CALL_UUID"

# ----------------------------------------------------------------------------
# 3. Attach the fork. host.docker.internal lets the container reach the
#    mock running on the host. mono / 8000 / bugname / metadata{} / no
#    bidirectional (one-way uplink).
# ----------------------------------------------------------------------------
# ════════════════════════════════════════════════════════════════════════════
# ★★★ [2b] A rejected URI must not leave a media bug attached (PR-1)
# ════════════════════════════════════════════════════════════════════════════
#
# mod_audio_fork.c used to log a parse failure and call start_capture() anyway.
# start_capture attaches the media bug BEFORE it connects:
#
#     fork_session_init(...)          <- accepts the garbage host
#     switch_core_media_bug_add(...)  <- bug is now on the live channel
#     switch_channel_set_private(...)
#     fork_session_connect(...)       <- fails, returns FALSE, bug NOT removed
#
# ⇒ The real consequence of the missing guard is a **dangling media bug on a
#   live call**: the audio path runs through capture_callback with a broken
#   AudioPipe, and `-ERR` is all the operator sees.
#
# ★★★ MEASURED, not reasoned: without the guard a bad URI returns **+OK**.
#
#     I first assumed it would return -ERR either way (fork_session_connect
#     failing on a garbage host). It does not — the lws connect is asynchronous,
#     so start_capture runs to the end and reports success.
#
#     ⇒ The operator gets "+OK Success" — a confirmation that streaming
#       started — and nothing ever streams. That is worse than the dangling
#       bug: there is no error anywhere to go looking for.
#
# ★ So there are two assertions, and they fail in different worlds:
#     · "+OK for a bad URI"      catches the fall-through directly
#     · "the NEXT good start fails" catches the leaked media bug, which is what
#       remains if someone ever makes the bad path return -ERR without also
#       stopping before switch_core_media_bug_add
#
# ⚠ Verified by mutation: putting the fall-through back makes exactly this
#   assertion red, and nothing else in either test script notices.
bold "[2b] rejected URI leaves no media bug"

BAD_OUT=$(docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x \
    "uuid_audio_fork $CALL_UUID start ws://h:99999/test mono 8000 testbug {}" 2>&1)
echo "$BAD_OUT" | grep -q "^+OK" \
    && fail "an out-of-range port was accepted: $BAD_OUT"

# The sample-rate gate, with two layers of assertion.
#
# ★ MEASURED: deleting `sampling % 8000 != 0` makes an illegal rate return
#   **+OK Success**. The resampler does NOT refuse 7000 — so this is the same
#   shape as the URI bug: silently accepted, nothing streams correctly.
#   ⇒ The response check below is what kills that mutation.
#
# ⚠ I got here after being wrong twice. First I assumed the resampler would
#   refuse and the response could not distinguish (it can). Before that I ran
#   two mutations written as `else if (0) { } else if (...)`, which the compiler
#   folds away entirely — the .so came out **byte-identical** and the "surviving"
#   mutation had never landed. The sha256 in smoke.sh is what exposed that.
#   ★ Lesson worth keeping: a mutation is only evidence once you have seen the
#     artifact change. Reasoning about what a compiler or a downstream library
#     will do is not measurement.
#
# ★★ The log assertion stays as a second layer: it pins that start_capture is
#    never ENTERED with an illegal rate (its first statement logs
#    "streaming <rate> sampling to ..."). Without it, a future change that
#    returns -ERR *after* handing 7000 to the resampler would pass.
BAD_RATE_OUT=$(docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x \
    "uuid_audio_fork $CALL_UUID start ws://host.docker.internal:$PORT/test mono 7000 testbug {}" 2>&1)
echo "$BAD_RATE_OUT" | grep -q "^+OK" \
    && fail "a sample rate that is not a multiple of 8000 was accepted: $BAD_RATE_OUT"
sleep 0.5
if docker logs "$FS_CONTAINER" --since 15s 2>&1 | grep -q "streaming 7000 sampling"; then
    fail "start_capture was entered with sampling=7000
  ⇒ the 'sampling % 8000' guard did not stop it. Even if the API happened to
    return -ERR, the illegal rate reached the resampler — the failure is then
    two layers away from the bad argument, and which layer refuses is an
    accident rather than a decision."
fi

# ★ The load-bearing assertion: neither rejection may have attached anything.
PROBE=$(docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x \
    "uuid_audio_fork $CALL_UUID start ws://host.docker.internal:$PORT/test mono 8000 testbug {}" 2>&1)
if ! echo "$PROBE" | grep -q "^+OK"; then
    fail "a good start after two rejected ones failed: $PROBE
  ⇒ one of the rejected attempts left a media bug named 'testbug' attached to
    the live channel (start_capture refuses an already-attached bugname).
    That is the fall-through this guard removes — see mod_audio_fork.c."
fi
# Detach it again so step 3 starts from a clean channel.
docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x \
    "uuid_audio_fork $CALL_UUID stop testbug" >/dev/null 2>&1
sleep 0.5
pass "bad port + bad sample rate both refused, and neither leaked a bug"

bold "[3/4] uuid_audio_fork start"

FORK_OUT=$(docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x \
    "uuid_audio_fork $CALL_UUID start ws://host.docker.internal:$PORT/test mono 8000 testbug {}" 2>&1)
echo "$FORK_OUT" | grep -q "^+OK" || fail "uuid_audio_fork start did not return +OK: $FORK_OUT"
pass "uuid_audio_fork start -> +OK"

# Give the WS connect + a few audio packetisation cycles to happen,
# and let our scripted killAudio fire at t=2.
sleep 4

# Stop the fork and verify the media bug is detached cleanly — concretely,
# that no further binary frames arrive after the stop command returns.
FRAMES_BEFORE_STOP=$(count_event RECV_BINARY)
STOP_OUT=$(docker exec "$FS_CONTAINER" fs_cli -p "$ESL_PASS" -x \
    "uuid_audio_fork $CALL_UUID stop testbug" 2>&1)
echo "$STOP_OUT" | grep -q "^+OK" || fail "uuid_audio_fork stop did not return +OK: $STOP_OUT"

# After stop, the bug is detached but lws may still flush a handful of
# in-flight binary frames that were already queued in its write buffer.
# Wait, then verify the frame count has settled — i.e., no new frames in
# a sampling window after the initial drain.
sleep 1.0
FRAMES_AFTER_DRAIN=$(count_event RECV_BINARY)
sleep 1.0
FRAMES_FINAL=$(count_event RECV_BINARY)
DRAINED_AFTER_STOP=$((FRAMES_AFTER_DRAIN - FRAMES_BEFORE_STOP))
DRIFT_AFTER_DRAIN=$((FRAMES_FINAL - FRAMES_AFTER_DRAIN))

# ----------------------------------------------------------------------------
# 4. Assertions against mock log.
# ----------------------------------------------------------------------------
bold "[4/4] Assert protocol events"

CONNECT=$(count_event CONNECT)
[ "$CONNECT" -ge 1 ] || fail "expected CONNECT >= 1, got $CONNECT"
pass "CONNECT seen ($CONNECT)"

# initial metadata: mod sends our {} metadata as the first text frame on connect.
META=$(grep "\"event\": \"RECV_TEXT\"" "$LOG" | head -1 || true)
[ -n "$META" ] || fail "expected an initial RECV_TEXT (metadata) frame"
pass "initial metadata frame received"

BIN_BYTES=$(sum_event_field RECV_BINARY bytes)
[ "$FRAMES_BEFORE_STOP" -ge 5 ] || fail "expected >=5 binary audio frames before stop, got $FRAMES_BEFORE_STOP"
pass "binary audio frames flowed (${FRAMES_BEFORE_STOP} frames, ${BIN_BYTES} bytes total)"

# Module survived the scripted killAudio at t=2 — implicit in the frame
# count: if killAudio had crashed the module we'd never have gotten the
# later frames.

# Bug detached cleanly: a small lws-side drain is OK, but the count must
# be frozen by the second sampling window (i.e., no new frames after the
# initial drain).
[ "$DRIFT_AFTER_DRAIN" -eq 0 ] || fail "binary frames still flowing 1s after stop drain (drift=$DRIFT_AFTER_DRAIN)"
pass "media bug detached cleanly (${DRAINED_AFTER_STOP} drain frame(s), then frozen)"

# Module + FS still alive — module didn't crash the container.
HEALTH=$(docker inspect "$FS_CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
[ "$HEALTH" = "healthy" ] || fail "FS unhealthy after test ($HEALTH)"
pass "FS still healthy"

echo ""
green "==> protocol tests passed"
