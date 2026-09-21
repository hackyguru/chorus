cmake_minimum_required(VERSION 3.14)
project(VoicePlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()

# PortAudio reaches the microphone and the speakers (CoreAudio here, ALSA or
# PulseAudio on Linux); Opus takes a 40 ms frame from 3840 bytes down to about
# 120, which is what makes voice fit on a gossipsub topic at all.
#
# Both are declared in metadata.json (nix.packages.runtime) so they land in
# buildInputs, and linked here through pkg-config rather than through the
# metadata cmake block — the same shape booth-basecamp uses for libsodium.
find_package(PkgConfig REQUIRED)
pkg_check_modules(portaudio REQUIRED IMPORTED_TARGET portaudio-2.0)
pkg_check_modules(opus      REQUIRED IMPORTED_TARGET opus)

logos_module(
    NAME voice
    SOURCES
        src/voice_impl.h
        src/voice_impl.cpp
        src/voice_audio.h
        src/voice_audio.cpp
    LINK_LIBRARIES
        PkgConfig::portaudio
        PkgConfig::opus
)
