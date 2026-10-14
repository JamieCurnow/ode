#!/bin/bash
# Runs every transcription engine on the clips and writes bench/results/report.md.
#
#   ./bench/run.sh                       all engines on bench/clips
#   CLIPS=/path/to/wavs ./bench/run.sh   another folder of clips (named like the ids in prompts.txt)
#   ENGINES="apple parakeet" ./bench/run.sh   just some of: apple parakeet whisper deepgram
#
# First run downloads models: Parakeet (~2 GB, into ~/Library/Application Support/FluidAudio) and
# Whisper large-v3-turbo (~1.6 GB, into bench/models). Needs whisper.cpp: brew install whisper-cpp
# Deepgram reads its API key from the Keychain and is skipped without one. To add it:
#   security add-generic-password -s "Ode Deepgram" -a deepgram -w
set -euo pipefail
cd "$(dirname "$0")"
BENCH="$PWD"
CLIPS="${CLIPS:-$BENCH/clips}"
RESULTS="${RESULTS:-$BENCH/results}"
ENGINES="${ENGINES:-apple parakeet whisper deepgram}"
WHISPER_MODEL="$BENCH/models/ggml-large-v3-turbo.bin"
want() { [[ " $ENGINES " == *" $1 "* ]]; }

ls "$CLIPS"/*.wav >/dev/null 2>&1 || { echo "No clips in $CLIPS. Record some with ./bench/record.sh"; exit 1; }
mkdir -p "$RESULTS"
rm -f "$RESULTS"/*.jsonl

echo "Building Ode (for Apple's SpeechAnalyzer and the vocabulary list)…"
(cd .. && swift build -c release --arch arm64 -q)
ODE="$BENCH/../.build/arm64-apple-macosx/release/Ode"
"$ODE" --print-vocabulary > "$RESULTS/vocab.txt"
echo "Vocabulary: $(wc -l < "$RESULTS/vocab.txt" | xargs) terms from your style guide"

if want apple; then
  echo "Apple SpeechAnalyzer…"
  "$ODE" --test-transcribe-dir "$CLIPS" 2>/dev/null | grep '^{' > "$RESULTS/apple.jsonl"
fi

if want parakeet; then
  echo "Building the Parakeet bench…"
  swift build -c release -q
  for version in v2 ultra; do
    echo "Parakeet ${version}…"
    vocab=(); [[ "$version" == v2 ]] && vocab=("$RESULTS/vocab.txt")
    .build/release/Bench parakeet "$version" "$CLIPS" ${vocab[@]+"${vocab[@]}"} 2>/dev/null | grep -o '{.*}' > "$RESULTS/parakeet-$version.jsonl"
  done
fi

if want whisper; then
  command -v whisper-cli >/dev/null || { echo "whisper-cli missing: brew install whisper-cpp"; exit 1; }
  if [[ ! -f "$WHISPER_MODEL" ]]; then
    echo "Downloading Whisper large-v3-turbo (~1.6 GB)…"
    mkdir -p "$(dirname "$WHISPER_MODEL")"
    curl -fL --progress-bar -o "$WHISPER_MODEL.part" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
    mv "$WHISPER_MODEL.part" "$WHISPER_MODEL"
  fi
  echo "Whisper large-v3-turbo…"
  python3 -I engines.py whisper "$CLIPS" "$WHISPER_MODEL" "$RESULTS/vocab.txt" > "$RESULTS/whisper.jsonl"
fi

if want deepgram; then
  echo "Deepgram nova-3…"
  python3 -I engines.py deepgram "$CLIPS" "$RESULTS/vocab.txt" > "$RESULTS/deepgram.jsonl"
fi

echo
python3 -I score.py prompts.txt "$RESULTS/vocab.txt" "$RESULTS"
