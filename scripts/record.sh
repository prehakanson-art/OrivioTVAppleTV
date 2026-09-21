#!/bin/bash
# Record a whole session from the Apple TV's dev probe (:8123) to a file.
#
#   scripts/record.sh 10.0.0.19                  # → probe-<date>.log in $PWD
#   scripts/record.sh 10.0.0.19 ~/browse.log     # → a path you choose
#
# Why not just `scripts/probe.sh <ip> > file`: a bare curl DIES the first time
# the app is suspended — stepping away from the app, a system overlay, the
# screensaver — and takes the rest of the session with it. This reconnects
# forever and stamps each gap, so the recording covers the whole sitting and
# says where the breaks were.
#
# Stop it with Ctrl-C. Mark a moment while it runs, from another terminal:
#   scripts/probe.sh 10.0.0.19 mark "froze right here"
set -u

HOST="${1:-${ORIVIO_TV:-}}"
OUT="${2:-probe-$(date +%Y%m%d-%H%M%S).log}"

if [ -z "$HOST" ]; then
    echo "usage: $0 <apple-tv-ip> [output-file]" >&2
    exit 64
fi

# Fail fast instead of looping forever with silently-failing redirections if the
# output path is unwritable or curl is missing. `>>` creates the file without
# truncating an existing recording.
command -v curl >/dev/null 2>&1 || { echo "!! curl not found on PATH" >&2; exit 69; }
if ! ( : >> "$OUT" ) 2>/dev/null; then
    echo "!! cannot write output file: $OUT" >&2
    exit 73
fi

echo "recording $HOST → $OUT   (Ctrl-C to stop)"
printf '==== recording started %s ====\n' "$(date '+%H:%M:%S')" >> "$OUT"

trap 'printf "==== recording stopped %s ====\n" "$(date "+%H:%M:%S")" >> "$OUT"; exit 0' INT TERM

while true; do
    curl --no-buffer --silent --show-error --max-time 86400 \
         "http://${HOST}:8123/live" >> "$OUT"
    # Reaching here means the stream ended: the app suspended, the box slept,
    # or the network blinked. Say so in the file rather than leaving a silent
    # seam, and back off a little so a powered-down TV isn't hammered.
    printf '\n---- probe unreachable at %s (app suspended?) — retrying ----\n' \
           "$(date '+%H:%M:%S')" >> "$OUT"
    sleep 3
done
