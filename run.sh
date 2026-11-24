#!/bin/zsh
# Desarrollo: compila en release y lanza TrackDrum desde el terminal (ves los logs).
# El golpe-bombo usa el ayudante (Ajustes → Activar). `./run.sh --sudo` lo lee directamente como root.
cd "$(dirname "$0")" && swift build -c release || exit 1
if [[ "${1:-}" == "--sudo" ]]; then sudo .build/release/TrackDrum; else .build/release/TrackDrum; fi
