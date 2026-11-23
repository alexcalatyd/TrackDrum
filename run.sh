#!/bin/zsh
# Compila en release y lanza TrackDrum.
cd "$(dirname "$0")" && swift build -c release && .build/release/TrackDrum
