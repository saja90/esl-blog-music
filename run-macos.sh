#!/bin/sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
cd "$ROOT" || exit 1

usage() {
    echo "Usage: $(basename "$0") SONG [tracks | solo TRACK | mute TRACK,TRACK,...]" >&2
    exit 1
}

[ "$#" -ge 1 ] || usage
SONG=$1
PLAY_CALL="music:play($SONG)"

if [ "$#" -gt 1 ]; then
    case $2 in
        tracks)
            [ "$#" -eq 2 ] || usage
            PLAY_CALL="begin io:write(music:tracks($SONG)), io:nl(), ok end"
            ;;
        solo)
            [ "$#" -eq 3 ] || usage
            PLAY_CALL="music:play($SONG, {solo, $3})"
            ;;
        mute)
            [ "$#" -eq 3 ] || usage
            PLAY_CALL="music:play($SONG, {mute, [$3]})"
            ;;
        *) usage ;;
    esac
elif [ "$#" -ne 1 ]; then
    usage
fi

command -v escript >/dev/null 2>&1 || {
    echo "Error: escript is not available on PATH." >&2
    exit 1
}
command -v erl >/dev/null 2>&1 || {
    echo "Error: erl is not available on PATH." >&2
    exit 1
}
command -v xcrun >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1 || {
    echo "Error: Apple Command Line Tools are required (run xcode-select --install)." >&2
    exit 1
}

REBAR="$ROOT/rebar3"
[ -f "$REBAR" ] || "$ROOT/bootstrap-rebar3-macos.sh" || exit 1

escript "$REBAR" compile || exit 1

BRIDGE_SOURCE="$ROOT/priv/audio_out.c"
BRIDGE_DIR="$ROOT/_build/macos"
BRIDGE="$BRIDGE_DIR/audio_out"
mkdir -p "$BRIDGE_DIR" || exit 1

if [ ! -x "$BRIDGE" ] || [ "$BRIDGE_SOURCE" -nt "$BRIDGE" ]; then
    echo "Building macOS audio bridge..."
    xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
        "$BRIDGE_SOURCE" -framework AudioToolbox -o "$BRIDGE" || exit 1
fi

MUSIC_AUDIO_BRIDGE="$BRIDGE" erl -noshell -pa "$ROOT/_build/default/lib/music/ebin" \
    -eval "case $PLAY_CALL of ok -> init:stop(0); Error -> io:format(standard_error, '~p~n', [Error]), init:stop(1) end."
