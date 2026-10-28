#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/capture-check
swift build --target GoblinCore
core=$(swift build --show-bin-path)
swiftc -parse-as-library -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx26.0" \
    -I "$core" -I Sources/CSQLite "$core/GoblinCore.o" -lsqlite3 \
    Sources/GoblinEngines/AudioInputDevice.swift Sources/GoblinEngines/CapturedAudio.swift \
    Sources/GoblinEngines/CaptureFile.swift Sources/GoblinEngines/CaptureProcessor.swift \
    Sources/GoblinEngines/FeedbackSounds.swift \
    Sources/GoblinEngines/AudioCaptureService.swift scripts/checks/audio-capture.swift \
    -o .build/capture-check/check
.build/capture-check/check "$@"
