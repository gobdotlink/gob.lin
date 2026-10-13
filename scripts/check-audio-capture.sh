#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/capture-check
swiftc -parse-as-library -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx26.0" \
    Sources/GoblinEngines/AudioInputDevice.swift Sources/GoblinEngines/CapturedAudio.swift \
    Sources/GoblinEngines/CaptureFile.swift Sources/GoblinEngines/CaptureProcessor.swift \
    Sources/GoblinEngines/AudioCaptureService.swift scripts/checks/audio-capture.swift \
    -o .build/capture-check/check
.build/capture-check/check "$@"
