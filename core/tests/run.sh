#!/usr/bin/env bash
# Offline check of the two claims the design rests on: that Opus at this
# module's exact frame size and bitrate carries speech, and that a packet is
# small enough for 25 a second on a gossipsub topic. Opens no audio device.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH=/nix/var/nix/profiles/default/bin:$PATH
NIX="nix --extra-experimental-features 'nix-command flakes'"
OPD=$(eval $NIX build --impure --no-link --print-out-paths --expr "'(import <nixpkgs> {}).libopus.dev'")
OPL=$(eval $NIX build --impure --no-link --print-out-paths --expr "'(import <nixpkgs> {}).libopus'")
clang++ -std=c++17 -O1 -o "$HERE/harness" "$HERE/harness.cpp" \
    -I"$OPD/include/opus" -L"$OPL/lib" -lopus -Wl,-rpath,"$OPL/lib"
"$HERE/harness"
