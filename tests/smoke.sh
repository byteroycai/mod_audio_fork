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
# The FS container to load the freshly-built module into.
#
#   Default is duck-call's (4th-gen) container; older generations used
#   `voiceagent-fs`. Override with FS_CONTAINER=<name>.
FS_CONTAINER="${FS_CONTAINER:-duckcall-fs}"
# Where the build lands on the host. `build/` is gitignored.
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
MOD_PATH=/usr/local/freeswitch/mod/mod_audio_fork.so

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
# ★★★ The artifact must land on the HOST, not in the --rm container.
#
#   It used to build into the container's /tmp/build and only extract the size
#   plus the `nm` output — the freshly built .so was destroyed when the
#   container exited. Steps 3-5 then `docker exec`'d into a *running* FS and
#   probed the module baked into THAT image.
#
#   ⇒ Steps 3-5 never tested the code you just built. Measured proof: the
#     container's baked .so was 239,120 bytes dated May 25 while step 1 had
#     just produced 323,008 bytes. Two different binaries, two months apart —
#     and an all-PASS run reads as "my change loads and registers fine".
#
#   Now: build into $BUILD_DIR on the host, install it into the container,
#   and verify by sha256 that the module FS loaded is the one we just built.
mkdir -p "$BUILD_DIR"
COMBINED_OUT=$(docker run --rm -v "$REPO_ROOT:/src" -v "$BUILD_DIR:/out" "$BUILDER_IMAGE" bash -c '
    set -e
    rm -rf /tmp/build
    cmake -S /src -B /tmp/build >/dev/null 2>&1
    cmake --build /tmp/build --parallel >/dev/null 2>&1
    test -f /tmp/build/mod_audio_fork.so || { echo "NO_ARTIFACT"; exit 1; }
    cp /tmp/build/mod_audio_fork.so /out/mod_audio_fork.so
    echo "ARTIFACT_SIZE:$(stat -c%s /out/mod_audio_fork.so)"
    echo "ARTIFACT_SHA:$(sha256sum /out/mod_audio_fork.so | cut -d" " -f1)"
    # FreeSWITCH discovers modules via the module_interface data symbol +
    # mod_load entry point. The interface lives in the data section (D),
    # the entry points in text (T) — accept either.
    nm -D /out/mod_audio_fork.so 2>/dev/null | grep -E " [TD] mod_audio_fork_"
') || fail "build / introspection failed (output: $COMBINED_OUT)"

FRESH_SHA=$(echo "$COMBINED_OUT" | sed -n 's/^ARTIFACT_SHA://p')
[ -n "$FRESH_SHA" ] || fail "no sha256 for the built artifact"

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

if ! docker inspect "$FS_CONTAINER" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    fail "FS container '$FS_CONTAINER' not running.
  Running containers: $(docker ps --format '{{.Names}}' | tr '\n' ' ')
  → start one (duck-call: 'make fs-up') or set FS_CONTAINER=<name>.
  (A standalone test container would be cleaner but needs a
   SignalWire-token-built FS image; reusing a running one is pragmatic.)"
fi

# The ESL password comes from the container's own env — hardcoding ClueCon
# only works on a factory-default FS, and a wrong password fails as a wall of
# -ERR whose root cause is invisible.
ESL_PW=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$FS_CONTAINER" \
    | sed -n 's/^FS_ESL_PASSWORD=//p' | head -1)
[ -n "$ESL_PW" ] || ESL_PW="${FS_ESL_PASSWORD:-ClueCon}"
fs() { docker exec "$FS_CONTAINER" /usr/local/freeswitch/bin/fs_cli -p "$ESL_PW" -x "$*" 2>&1; }

# ★★★ Install the freshly built module, then reload it.
#
#   Without this, everything below probes whatever was baked into the image.
docker cp "$BUILD_DIR/mod_audio_fork.so" "$FS_CONTAINER:$MOD_PATH" \
    || fail "could not install the built .so into $FS_CONTAINER"

# `reload` unloads + loads. On a module that is not currently loaded it still
# loads it, so this covers both states.
RELOAD=$(fs "reload mod_audio_fork")
echo "$RELOAD" | grep -qiE '\+OK|Reload|success' \
    || fail "reload mod_audio_fork failed: $RELOAD"

EXISTS=$(fs "module_exists mod_audio_fork" | tr -d '[:space:]')
[ "$EXISTS" = "true" ] || fail "module_exists returned '$EXISTS' (expected 'true')"

# ★★★ COUNTER-PROOF: the module FS just loaded must be the one we built.
#
#   Without this assertion "PASS: module loaded" cannot distinguish
#   "my change loaded" from "the stale baked-in module loaded" — which is
#   exactly the failure this whole block was written to remove.
IN_CONTAINER_SHA=$(docker exec "$FS_CONTAINER" sha256sum "$MOD_PATH" 2>/dev/null | cut -d' ' -f1)
[ "$IN_CONTAINER_SHA" = "$FRESH_SHA" ] || fail "the module in $FS_CONTAINER is NOT the one just built
  built:        $FRESH_SHA
  in container: $IN_CONTAINER_SHA
  ⇒ steps 3-5 would be validating a different binary (this is how the
    original harness silently tested a two-month-old module)."
pass "freshly built module installed + loaded (sha ${FRESH_SHA:0:12}…)"

# ----------------------------------------------------------------------------
# 4. API surface — USAGE banner mentions every subcommand.
# ----------------------------------------------------------------------------
bold "[4/5] API surface"

USAGE=$(fs "uuid_audio_fork")
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
OUT=$(fs "uuid_audio_fork")
echo "$OUT" | grep -q "^-USAGE:" || fail "empty args should print '-USAGE:', got: $OUT"
pass "empty args -> -USAGE"

# Non-existent UUID → graceful failure, no panic.
OUT=$(fs "uuid_audio_fork 00000000-0000-0000-0000-000000000000 start ws://localhost:1 mono 8000")
echo "$OUT" | grep -q "Operation Failed" || fail "non-existent UUID should fail gracefully, got: $OUT"
pass "non-existent UUID -> -ERR Operation Failed"

# Container must still be healthy after our pokes.
HEALTH=$(docker inspect "$FS_CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
[ "$HEALTH" = "healthy" ] || fail "FS container health = $HEALTH (expected healthy) — module may have crashed it"
pass "FS still healthy after probes"

echo ""
green "==> smoke tests passed"
