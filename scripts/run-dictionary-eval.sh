#!/bin/sh
# Run every GOB-14 dictionary-biasing arm over the 128-clip synthetic set, one process per arm.
# Usage: scripts/run-dictionary-eval.sh <dataset-dir> <output-dir>
# Requires: prepare-model --vocabulary-support, prepare-model --model whisper-large-v3-turbo, and
# Moonshine models (the first Moonshine arm passes --download). Arms run serially so timings do not overlap.
set -eu
DATA=${1:?dataset directory with manifest.json and glossaries/}
OUT=${2:?output directory}
CLI="$(swift build -c release --product goblin --show-bin-path)/goblin"
swift build -c release --product goblin >/dev/null
mkdir -p "$OUT"
MANIFEST="$DATA/manifest.json"
CONSERVATIVE="env FLUID_CBW_TAPER_PIVOT=5 FLUID_CBW_TAPER_EXP=2 FLUID_SPOTTER_MIN_SIM=0.30 FLUID_SPOTTER_MIN_SIM_MULTI=0.50 FLUID_SPOTTER_RESCUE=0"
DEFAULTS="env -u FLUID_CBW_TAPER_PIVOT -u FLUID_CBW_TAPER_EXP -u FLUID_SPOTTER_MIN_SIM -u FLUID_SPOTTER_MIN_SIM_MULTI -u FLUID_SPOTTER_RESCUE"

for glossary in focused-16 full-120; do
    terms="$DATA/glossaries/$glossary.txt"
    # Same term texts with the handoff's 0.90 spelling-similarity gate.
    python3 -I -c 'import json,sys; t=[l.strip() for l in open(sys.argv[1]) if l.strip()]; print(json.dumps({"terms":[{"text":x} for x in t],"minSimilarity":0.90}))' \
        "$terms" > "$OUT/$glossary-similarity090.json"
    $DEFAULTS "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" > "$OUT/parakeet-default-$glossary.jsonl"
    $CONSERVATIVE "$CLI" dictionary-eval "$MANIFEST" --glossary "$OUT/$glossary-similarity090.json" > "$OUT/parakeet-similarity090-$glossary.jsonl"
    "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --parakeet-correction none --text-join > "$OUT/parakeet-textjoin-$glossary.jsonl"
    $DEFAULTS "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --guard spelling > "$OUT/parakeet-spelling-$glossary.jsonl"
    $DEFAULTS "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --guard spelling-or-confidence:0.8 > "$OUT/parakeet-spellconf-$glossary.jsonl"
    "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --model whisper-large-v3-turbo --language en > "$OUT/whisper-turbo-$glossary.jsonl"
    for boost in 1 2 3 4; do
        "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --moonshine medium --keyterm-boost "$boost" --download \
            > "$OUT/moonshine-medium-boost$boost-$glossary.jsonl"
    done
    "$CLI" dictionary-eval "$MANIFEST" --glossary "$terms" --moonshine small --download > "$OUT/moonshine-small-boost2-$glossary.jsonl"
done
echo "Score with: scripts/score-dictionary-eval.py --split original $OUT/*.jsonl"
