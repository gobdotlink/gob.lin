#!/bin/sh
# Run every GOB-14 dictionary-biasing arm over the 128-clip synthetic set, one process per arm.
# Usage: scripts/run-dictionary-eval.sh <dataset-dir> <output-dir>
# Requires: prepare-model, prepare-model --model whisper-large-v3-turbo, and Moonshine models
# (the first Moonshine arm passes --download). Arms run serially so timings do not overlap.
# Parakeet has no recognition dictionary: its arm is the baseline that aliases and Cleanup start from.
set -eu
DATA=${1:?dataset directory with manifest.json and glossaries/}
OUT=${2:?output directory}
CLI="$(swift build -c release --product goblin --show-bin-path)/goblin"
swift build -c release --product goblin >/dev/null
mkdir -p "$OUT"
MANIFEST="$DATA/manifest.json"

for glossary in focused-16 full-120; do
    terms="$DATA/glossaries/$glossary.txt"
    "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" > "$OUT/parakeet-none-$glossary.jsonl"
    "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --model whisper-large-v3-turbo --language en > "$OUT/whisper-turbo-$glossary.jsonl"
    for boost in 1 2 3 4; do
        "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --moonshine medium --keyterm-boost "$boost" --download \
            > "$OUT/moonshine-medium-boost$boost-$glossary.jsonl"
    done
    "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --moonshine small --download > "$OUT/moonshine-small-boost2-$glossary.jsonl"
done
echo "Score with: scripts/score-dictionary-eval.py --split original $OUT/*.jsonl"
