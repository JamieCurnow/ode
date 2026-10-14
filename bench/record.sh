#!/bin/bash
# Records each line of bench/prompts.txt to bench/clips/<id>.wav (16 kHz mono) with ffmpeg.
#   ./bench/record.sh          record every clip that doesn't exist yet
#   ./bench/record.sh 03-email record (or redo) just that one
# Mic: MIC="device name" to pick another input (list them: ffmpeg -f avfoundation -list_devices true -i "")
set -euo pipefail
cd "$(dirname "$0")"
MIC="${MIC:-MacBook Pro Microphone}"
mkdir -p clips

record() {
  local id="$1" text="$2" out="clips/$1.wav"
  while true; do
    clear
    printf "\n  \033[2m%s\033[0m\n\n  \033[1m%s\033[0m\n\n" "$id" "$text"
    read -rp "  Enter to start recording… " _
    ffmpeg -hide_banner -loglevel error -y -f avfoundation -i ":$MIC" -ac 1 -ar 16000 "$out" </dev/null &
    local pid=$!
    printf "  \033[31m● Recording\033[0m, Enter to stop "
    read -r _
    kill -INT "$pid"; wait "$pid" 2>/dev/null || true
    read -rp "  Saved. Enter for next, r to redo, p to play back: " ans
    if [[ "$ans" == p ]]; then afplay "$out"; read -rp "  Enter for next, r to redo: " ans; fi
    [[ "$ans" == r ]] || break
  done
}

grep -v '^#' prompts.txt | while IFS='|' read -r id text; do
  id="$(echo "$id" | xargs)"; text="$(echo "$text" | sed 's/^ *//')"
  if [[ -n "${1:-}" ]]; then [[ "$id" == "$1" ]] || continue
  elif [[ -f "clips/$id.wav" ]]; then continue; fi
  record "$id" "$text" </dev/tty
done
echo "Done: $(ls clips/*.wav 2>/dev/null | wc -l | xargs) clips in bench/clips"
