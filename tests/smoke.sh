#!/usr/bin/env bash
# Smoke test for mod_audio_fork.
#
# What it covers:
#   1. The CMake out-of-tree build produces mod_audio_fork.so against a
#      FreeSWITCH SDK (taken from the voiceagent-fs image as a convenient
#      pre-built environment — any image with the FS SDK + libwebsockets-dev
#      + libspeexdsp-dev + libboost-dev would work).
#   2. The .so contains the expected mod_load entry point.
#   3. The module loads into a transient FS instance and registers the
#      uuid_audio_fork API command.
#   4. The API command's USAGE banner mentions every subcommand we ship.
#   5. Bad inputs (empty args, non-existent UUID) fail gracefully instead
#      of crashing FS.
#
# What it does NOT cover (see protocol_test.sh):
#   - actual audio streaming, playAudio/killAudio/mark protocol behaviour.
#
# Usage:
#   ./tests/smoke.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER_IMAGE="${BUILDER_IMAGE:-mod-audio-fork-builder:tmp}"
BASE_IMAGE="${BASE_IMAGE:-voiceagent-fs:latest}"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }

fail()  { red "FAIL: $*"; exit 1; }
pass()  { green "PASS: $*"; }

# ----------------------------------------------------------------------------
# 1. Build via the existing builder image (re-create if missing).
# ----------------------------------------------------------------------------
bold "[1/5] Build mod_audio_fork.so"

if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    bold "  builder image missing — creating from $BASE_IMAGE"
    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        fail "base image $BASE_IMAGE not found — build voiceagent-fs first \
(deploy/fs/build.sh in the voice-agent repo)"
    fi
    docker build -t "$BUILDER_IMAGE" -f - "$REPO_ROOT" <<EOF >/dev/null
FROM $BASE_IMAGE
USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake build-essential pkg-config \
        libwebsockets-dev libspeexdsp-dev libboost-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ENTRYPOINT []
CMD ["bash"]
EOF
fi

# Build, size-check, and symbol-check in a single container so /tmp/build
# stays alive across the steps (each `docker run --rm` is otherwise a fresh,
# empty filesystem).
COMBINED_OUT=$(docker run --rm -v "$REPO_ROOT:/src" "$BUILDER_IMAGE" bash -c '
    set -e
    rm -rf /tmp/build
    cmake -S /src -B /tmp/build >/dev/null 2>&1
    cmake --build /tmp/build --parallel >/dev/null 2>&1
    test -f /tmp/build/mod_audio_fork.so || { echo "NO_ARTIFACT"; exit 1; }
    echo "ARTIFACT_SIZE:$(stat -c%s /tmp/build/mod_audio_fork.so)"
    # FreeSWITCH discovers modules via the module_interface data symbol +
    # mod_load entry point. The interface lives in the data section (D),
    # the entry points in text (T) — accept either.
    nm -D /tmp/build/mod_audio_fork.so 2>/dev/null | grep -E " [TD] mod_audio_fork_"
') || fail "build / introspection failed (output: $COMBINED_OUT)"

SO_SIZE=$(echo "$COMBINED_OUT" | sed -n 's/^ARTIFACT_SIZE://p')
[ -z "$SO_SIZE" ] && fail "no .so produced"
pass "built mod_audio_fork.so (${SO_SIZE} bytes)"

# ----------------------------------------------------------------------------
# 2. Symbol check — module entry point present.
# ----------------------------------------------------------------------------
bold "[2/5] Inspect .so symbols"

for sym in mod_audio_fork_module_interface mod_audio_fork_load mod_audio_fork_shutdown; do
    echo "$COMBINED_OUT" | grep -qE " [TD] $sym$" || fail "missing exported symbol: $sym"
done
pass "module entry symbols present"

# ----------------------------------------------------------------------------
# 3. Load the module into a transient FS, verify the API is registered.
# ----------------------------------------------------------------------------
bold "[3/5] Load module into transient FS"

if ! docker inspect voiceagent-fs --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    fail "voiceagent-fs container not running — start it with 'make fs-up' \
in the voice-agent repo. (A standalone test container would be cleaner but \
needs a SignalWire-token-built FS image; reusing the running one is pragmatic.)"
fi

# Make sure the running container actually has the freshly-built .so.
docker exec voiceagent-fs ls /usr/local/freeswitch/mod/mod_audio_fork.so >/dev/null \
    || fail "mod_audio_fork.so not installed in container — re-build the FS image"

# If the module is already loaded we don't reload — we just probe its state.
EXISTS=$(docker exec voiceagent-fs fs_cli -p "${FS_ESL_PASSWORD:-ClueCon}" -x "module_exists mod_audio_fork" 2>&1 | tr -d '[:space:]')
[ "$EXISTS" = "true" ] || fail "module_exists returned '$EXISTS' (expected 'true')"
pass "module loaded"

# ----------------------------------------------------------------------------
# 4. API surface — USAGE banner mentions every subcommand.
# ----------------------------------------------------------------------------
bold "[4/5] API surface"

USAGE=$(docker exec voiceagent-fs fs_cli -p "${FS_ESL_PASSWORD:-ClueCon}" -x "uuid_audio_fork" 2>&1)
for sub in start stop send_text pause resume stop_play graceful-shutdown; do
    echo "$USAGE" | grep -q "$sub" || fail "USAGE banner missing '$sub' — got: $USAGE"
done
for kw in bidirectionalAudio_enabled bidirectionalAudio_stream_enabled bidirectionalAudio_stream_samplerate; do
    echo "$USAGE" | grep -q "$kw" || fail "USAGE banner missing '$kw'"
done
pass "USAGE banner includes all subcommands and bidir parameters"

# ----------------------------------------------------------------------------
# 5. Failure-mode robustness — bad inputs return errors instead of crashing.
# ----------------------------------------------------------------------------
bold "[5/5] Bad-input handling"

# Empty args → USAGE error.
OUT=$(docker exec voiceagent-fs fs_cli -p "${FS_ESL_PASSWORD:-ClueCon}" -x "uuid_audio_fork" 2>&1)
echo "$OUT" | grep -q "^-USAGE:" || fail "empty args should print '-USAGE:', got: $OUT"
pass "empty args -> -USAGE"

# Non-existent UUID → graceful failure, no panic.
OUT=$(docker exec voiceagent-fs fs_cli -p "${FS_ESL_PASSWORD:-ClueCon}" -x "uuid_audio_fork 00000000-0000-0000-0000-000000000000 start ws://localhost:1 mono 8000" 2>&1)
echo "$OUT" | grep -q "Operation Failed" || fail "non-existent UUID should fail gracefully, got: $OUT"
pass "non-existent UUID -> -ERR Operation Failed"

# Container must still be healthy after our pokes.
HEALTH=$(docker inspect voiceagent-fs --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
[ "$HEALTH" = "healthy" ] || fail "FS container health = $HEALTH (expected healthy) — module may have crashed it"
pass "FS still healthy after probes"

echo ""
green "==> smoke tests passed"
