#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/checks/feedback-media.mjs
