cmake_minimum_required(VERSION 3.16)

project(mod_audio_fork
    VERSION 0.1.0
    DESCRIPTION "FreeSWITCH module: stream channel audio to a WebSocket server"
    LANGUAGES C CXX
)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)

pkg_check_modules(LIBWEBSOCKETS REQUIRED IMPORTED_TARGET libwebsockets)
pkg_check_modules(SPEEXDSP      REQUIRED IMPORTED_TARGET speexdsp)

# FreeSWITCH headers and library — override via -D or env vars when not in standard paths.
find_path(FREESWITCH_INCLUDE_DIR
    NAMES switch.h
    HINTS ENV FREESWITCH_INCLUDE_DIR
    PATHS
        /usr/include/freeswitch
        /usr/local/include/freeswitch
        /usr/local/freeswitch/include/freeswitch
        /opt/freeswitch/include/freeswitch
)
find_library(FREESWITCH_LIBRARY
    NAMES freeswitch
    HINTS ENV FREESWITCH_LIBRARY_DIR
    PATHS
        /usr/lib
        /usr/lib/x86_64-linux-gnu
        /usr/local/lib
        /usr/local/freeswitch/lib
        /opt/freeswitch/lib
)
if(NOT FREESWITCH_INCLUDE_DIR OR NOT FREESWITCH_LIBRARY)
    message(FATAL_ERROR
        "FreeSWITCH not found. Install freeswitch-dev, or pass -DFREESWITCH_INCLUDE_DIR=... -DFREESWITCH_LIBRARY=..."
    )
endif()

find_path(BOOST_CIRCULAR_BUFFER_INCLUDE_DIR boost/circular_buffer.hpp)
if(NOT BOOST_CIRCULAR_BUFFER_INCLUDE_DIR)
    message(FATAL_ERROR
        "boost/circular_buffer.hpp not found. Install libboost-dev (or your platform's equivalent)."
    )
endif()

add_library(mod_audio_fork MODULE
    mod_audio_fork.c
    lws_glue.cpp
    parser.cpp
    audio_pipe.cpp
)

set_target_properties(mod_audio_fork PROPERTIES
    PREFIX ""
    OUTPUT_NAME mod_audio_fork
)

target_include_directories(mod_audio_fork PRIVATE
    ${FREESWITCH_INCLUDE_DIR}
    ${BOOST_CIRCULAR_BUFFER_INCLUDE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(mod_audio_fork PRIVATE
    ${FREESWITCH_LIBRARY}
    PkgConfig::LIBWEBSOCKETS
    PkgConfig::SPEEXDSP
    Threads::Threads
)

target_compile_options(mod_audio_fork PRIVATE -Wall -Wextra)

set(FREESWITCH_MOD_DIR "/usr/local/freeswitch/mod"
    CACHE PATH "FreeSWITCH module install directory")

install(TARGETS mod_audio_fork
    LIBRARY DESTINATION ${FREESWITCH_MOD_DIR}
)

message(STATUS "")
message(STATUS "mod_audio_fork configuration")
message(STATUS "  Build type:            ${CMAKE_BUILD_TYPE}")
message(STATUS "  FreeSWITCH include:    ${FREESWITCH_INCLUDE_DIR}")
message(STATUS "  FreeSWITCH library:    ${FREESWITCH_LIBRARY}")
message(STATUS "  libwebsockets:         ${LIBWEBSOCKETS_VERSION}")
message(STATUS "  speexdsp:              ${SPEEXDSP_VERSION}")
message(STATUS "  Boost circular_buffer: ${BOOST_CIRCULAR_BUFFER_INCLUDE_DIR}")
message(STATUS "  Install destination:   ${FREESWITCH_MOD_DIR}")
message(STATUS "")
