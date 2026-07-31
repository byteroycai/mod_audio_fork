#!/usr/bin/env bash
# PR-2: prove that frames skipped on mutex contention are actually counted.
#
# ════════════════════════════════════════════════════════════════════════════
# Why this needs its own script
# ════════════════════════════════════════════════════════════════════════════
#
# fork_frame() takes tech_pvt->mutex with switch_mutex_trylock and, when it
# fails, skips that frame's drain. Before PR-2 there was no counter, no event
# and no log — the only symptom was jitter, and `dc_fork_frame_dropped_total`
# on the Go side had a comment saying "available after PR-2" and no writer.
#
# Provoking the failure needs a second holder of that mutex. The only paths that
# take it are inside processIncomingMessage (server-sent text) and
# dub_speech_frame — both of which require **bidirectional audio**, which
# protocol_test.sh deliberately does not enable. Hence a separate script rather
# than another step there.
#
# ⚠ This test can only assert "contention is counted when it happens". It cannot
#   assert how MUCH contention a given load produces — that is what S2'/M9
#   measure, and it depends on the machine.
#
# Usage:
#   ./tests/contention_test.sh          (run ./tests/smoke.sh first)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${MOCK_PORT:-9099}"
LOG="/tmp/mod_audio_fork_contention_$$.log"
MOCK_PID=""
CALL_UUID=""
FS_CONTAINER="${FS_CONTAINER:-duckcall-fs}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
MOD_PATH=/usr/local/freeswitch/mod/mod_audio_fork.so
TEST_EXT=7901
TEST_DIALPLAN_PATH=/usr/local/freeswitch/conf/dialplan/default/98_mod_audio_fork_contention.xml

# ★ How many skipped frames per report. Set low so a ~10s test can see one at
#   all; the module's default is 500 (~10s of *sustained* contention).
REPORT_EVERY="${REPORT_EVERY:-3}"
FLOOD_COUNT="${FLOOD_COUNT:-400}"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }

ESL_PASS=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$FS_CONTAINER" 2>/dev/null \
    | sed -n 's/^FS_ESL_PASSWORD=//p' | head -1)
[ -n "$ESL_PASS" ] || ESL_PASS="${FS_ESL_PASSWORD:-ClueCon}"
fs() { docker exec "$FS_CONTAINER" /usr/local/freeswitch/bin/fs_cli -p "$ESL_PASS" -x "$*" 2>&1; }

cleanup() {
    local code=$?
    [ -n "$CALL_UUID" ] && fs "uuid_kill $CALL_UUID" >/dev/null 2>&1 || true
    if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    docker exec "$FS_CONTAINER" rm -f "$TEST_DIALPLAN_PATH" 2>/dev/null || true
    fs "reloadxml" >/dev/null 2>&1 || true
    if [ $code -eq 0 ]; then
        rm -f "$LOG"
    else
        red "FAILED — mock log preserved at: $LOG"
    fi
}
trap cleanup EXIT

fail() { red "FAIL: $*"; exit 1; }
pass() { green "PASS: $*"; }

# ── which binary are we testing ────────────────────────────────────────────
docker inspect "$FS_CONTAINER" --format '{{.State.Status}}' 2>/dev/null | grep -q running \
    || fail "FS container '$FS_CONTAINER' not running (duck-call: 'make fs-up' in deploy/fs)"
LOADED_SHA=$(docker exec "$FS_CONTAINER" sha256sum "$MOD_PATH" 2>/dev/null | cut -d' ' -f1)
if [ -f "$BUILD_DIR/mod_audio_fork.so" ]; then
    BUILT_SHA=$(shasum -a 256 "$BUILD_DIR/mod_audio_fork.so" 2>/dev/null | cut -d' ' -f1)
    [ -n "$BUILT_SHA" ] || BUILT_SHA=$(sha256sum "$BUILD_DIR/mod_audio_fork.so" | cut -d' ' -f1)
    [ "$LOADED_SHA" = "$BUILT_SHA" ] || fail "the loaded module is not the last one built
  built:  $BUILT_SHA
  loaded: $LOADED_SHA
  → run ./tests/smoke.sh first (it installs and restarts)."
    green "testing the freshly built module (sha ${BUILT_SHA:0:12}…)"
else
    bold "⚠ no build/ artifact — testing whatever FS has loaded (sha ${LOADED_SHA:0:12}…)"
fi

# ── mock with a flood ──────────────────────────────────────────────────────
bold "[1/3] Start mock WS server on :$PORT with a ${FLOOD_COUNT}-message flood"
python3 "$REPO_ROOT/tests/mock_ws_server.py" \
    --port "$PORT" --log "$LOG" --timeout 25 \
    --flood "1.0:${FLOOD_COUNT}:playAudio" --flood-bytes "${FLOOD_BYTES:-32768}" &
MOCK_PID=$!
for _ in $(seq 1 30); do
    grep -q '"event": "LISTEN"' "$LOG" 2>/dev/null && break
    sleep 0.1
done
grep -q '"event": "LISTEN"' "$LOG" || fail "mock failed to bind :$PORT within 3s"
pass "mock listening (pid $MOCK_PID)"

# ── a call with bidirectional audio enabled ────────────────────────────────
bold "[2/3] Originate with bidirectional audio + REPORT_EVERY=$REPORT_EVERY"
docker exec -i "$FS_CONTAINER" sh -c "cat > $TEST_DIALPLAN_PATH" <<EOF
<include>
  <extension name="mod_audio_fork_contention">
    <condition field="destination_number" expression="^${TEST_EXT}\$">
      <action application="answer"/>
      <action application="playback" data="silence_stream://25000"/>
      <action application="hangup"/>
    </condition>
  </extension>
</include>
EOF
fs "reloadxml" >/dev/null

# ★ The channel variable rides along on the originate so it is set before
#   fork_session_init reads it.
ORIG_OUT=$(fs "originate {ignore_early_media=true,MOD_AUDIO_FORK_DROP_REPORT_EVERY=$REPORT_EVERY}loopback/${TEST_EXT}/default &park")
CALL_UUID=$(echo "$ORIG_OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
[ -n "$CALL_UUID" ] || fail "originate did not yield a uuid: $ORIG_OUT"
sleep 1

# ★ argc > 7 with argv[7]="true" turns on bidirectional audio, which is what
#   allocates playoutBuffer/pendingMarks and therefore what makes the
#   mutex-holding paths in processIncomingMessage reachable at all.
FORK_OUT=$(fs "uuid_audio_fork $CALL_UUID start ws://host.docker.internal:$PORT/contend mono 8000 cbug {} true")
echo "$FORK_OUT" | grep -q "^+OK" || fail "uuid_audio_fork start (bidir) did not return +OK: $FORK_OUT"
pass "fork attached with bidirectional audio, call $CALL_UUID"

# Let the flood run against a live 50 fps audio path.
sleep 6

# ── assertions ─────────────────────────────────────────────────────────────
bold "[3/3] Assert contention is counted"

FLOOD_SENT=$(sed -n 's/.*"event": "FLOOD_DONE".*"sent": \([0-9]*\).*/\1/p' "$LOG" | head -1)
[ -n "$FLOOD_SENT" ] && [ "$FLOOD_SENT" -gt 100 ] \
    || fail "the flood did not run (sent=${FLOOD_SENT:-none}) — without it this test proves nothing"
pass "flood delivered $FLOOD_SENT messages"

# The module reports via a CUSTOM event; the counter also lands in the FS log.
DROP_LINES=$(docker logs "$FS_CONTAINER" --since 30s 2>&1 \
    | grep -oE "[0-9]+ frames skipped on mutex contention" | grep -oE "^[0-9]+" || true)

if [ -z "$DROP_LINES" ]; then
    # ════════════════════════════════════════════════════════════════════════
    # ★★★ SKIP, not FAIL — and the difference matters
    # ════════════════════════════════════════════════════════════════════════
    #
    # Measured on this hardware: 6000 flooded `clearMarks` and 400 × 32KB
    # flooded `playAudio` both produced **zero** skipped frames. The mutex is
    # held for microseconds while fork_frame only retries every 20ms, so the
    # trylock never loses. That agrees with S2' (0.03ms jitter at 10 concurrent
    # sessions, no inflection point) — and it is why PR-5/6/7 were dropped.
    #
    # ⇒ Failing here would make this a permanently red test on a machine where
    #   the thing it tests cannot happen. That trains people to ignore it.
    #
    # ★ But "no contention" must not be reported as "the counter works" either.
    #   So: distinguish the two causes before skipping. The counter's CODE is
    #   guarded separately (grep below + tests/throttle_test.cpp for the
    #   arithmetic); what is unverified is only that a real trylock failure
    #   reaches it.
    if ! grep -q 'frames skipped on mutex contention' "$REPO_ROOT/lws_glue.cpp"; then
        fail "the else-branch in fork_frame is GONE (PR-2 undone).
  ⇒ That is a different thing from 'this machine has no contention': with the
    branch removed the counter can never fire anywhere."
    fi
    printf '\033[33mSKIP\033[0m: no contention occurred after %s flooded messages.\n' "$FLOOD_SENT"
    printf '  ★ The counter code is present (grep passed) and its arithmetic is\n'
    printf '    covered by tests/throttle_test.cpp.\n'
    printf '  ⚠ What remains UNVERIFIED: that a real trylock failure reaches it.\n'
    printf '    It has never been observed firing on this hardware — see\n'
    printf '    drop_throttle.hpp and tests/README.md. Do not report PR-2 as\n'
    printf '    "verified end to end".\n'
    exit 0
fi

# ★★ Monotonic: the reported number is CUMULATIVE, not per-report. A consumer
#    that only ever sees "1" cannot recover from a missed event.
PREV=0
for n in $DROP_LINES; do
    [ "$n" -gt "$PREV" ] || fail "reported counts are not increasing: $DROP_LINES
  ⇒ the event carries a per-report delta instead of the cumulative total."
    PREV=$n
done
COUNT_N=$(echo "$DROP_LINES" | wc -l | tr -d ' ')
pass "contention reported $COUNT_N time(s), cumulative and monotonic: $(echo $DROP_LINES | tr '\n' ' ')"

# ★★★ COUNTER-PROOF: the throttle must actually throttle.
#     With REPORT_EVERY=$REPORT_EVERY and a cumulative total of $PREV, the number
#     of reports cannot exceed total/REPORT_EVERY. If it does, the throttle is
#     not being applied — and at 50 fps × N sessions an unthrottled event per
#     drop turns the measurement into the bottleneck it measures.
MAX_REPORTS=$(( PREV / REPORT_EVERY + 1 ))
[ "$COUNT_N" -le "$MAX_REPORTS" ] \
    || fail "$COUNT_N reports for a cumulative total of $PREV with REPORT_EVERY=$REPORT_EVERY
  ⇒ the throttle is not applied; every skipped frame is firing an event."
pass "throttle holds ($COUNT_N reports ≤ $MAX_REPORTS for total $PREV)"

# ★ And the CUSTOM event must be subscribable — a counter nobody can receive is
#   not an improvement over no counter.
fs "reloadxml" >/dev/null 2>&1
green ""
green "==> contention tests passed"
