# Building mod_audio_fork

This module is built out-of-tree with CMake against an installed FreeSWITCH.

## Prerequisites

Install the dependencies:

| Library | Notes |
|---|---|
| FreeSWITCH (with development headers) | Required at build and run time |
| libwebsockets | `pkg-config --modversion libwebsockets` should succeed |
| speexdsp | Used for the audio resampler |
| Boost (header-only, `circular_buffer.hpp`) | No linked Boost libraries are needed |
| CMake ≥ 3.16, a C99 compiler, a C++14 compiler | |

**Debian / Ubuntu:**

```bash
sudo apt-get install -y cmake build-essential pkg-config \
    libwebsockets-dev libspeexdsp-dev libboost-dev \
    freeswitch-dev
```

**macOS (development / experimentation only — FreeSWITCH modules are typically deployed on Linux):**

```bash
brew install cmake pkg-config libwebsockets speexdsp boost
# FreeSWITCH headers/library on macOS are usually self-built; pass their paths via -D.
```

## Build

```bash
./build.sh build
```

This configures CMake in `build/` and builds `mod_audio_fork.so`.

To use non-standard FreeSWITCH paths:

```bash
FREESWITCH_INCLUDE_DIR=/opt/freeswitch/include/freeswitch \
FREESWITCH_LIBRARY=/opt/freeswitch/lib/libfreeswitch.so \
./build.sh build
```

The same overrides also work as CMake `-D` flags if you invoke `cmake` directly:

```bash
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DFREESWITCH_INCLUDE_DIR=/opt/freeswitch/include/freeswitch \
    -DFREESWITCH_LIBRARY=/opt/freeswitch/lib/libfreeswitch.so
cmake --build build --parallel
```

## Install

Default install location is `/usr/local/freeswitch/mod`. Override with `FREESWITCH_MOD_DIR`:

```bash
sudo ./build.sh install
# or
FREESWITCH_MOD_DIR=/usr/lib/freeswitch/mod sudo ./build.sh install
```

## Enabling the module

Add to `modules.conf.xml`:

```xml
<load module="mod_audio_fork"/>
```

Then reload from `fs_cli`:

```bash
fs_cli -x "reload mod_audio_fork"
fs_cli -x "module_exists mod_audio_fork"
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `FreeSWITCH not found` during configure | Set `FREESWITCH_INCLUDE_DIR` / `FREESWITCH_LIBRARY` |
| `boost/circular_buffer.hpp not found` | Install `libboost-dev` (Debian) or `boost` (Homebrew) |
| Module fails to load at runtime | `ldd build/mod_audio_fork.so` and check for missing libs |
| `pkg-config` cannot find libwebsockets/speexdsp | Verify each `.pc` file is on `PKG_CONFIG_PATH` |
