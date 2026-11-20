#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
unset SDKROOT

OUT_DIR=".build/manual"
BIN_PATH="$OUT_DIR/LiveStemPlayer"
SOURCES=(
  "Sources/LiveStemPlayer/Models.swift"
  "Sources/LiveStemPlayer/AudioChannel.swift"
  "Sources/LiveStemPlayer/LiveStemBackend.swift"
  "Sources/LiveStemPlayer/AUPluginCatalog.swift"
  "Sources/LiveStemPlayer/ContentView.swift"
  "Sources/LiveStemPlayer/main.swift"
)

mkdir -p "$OUT_DIR"

echo "Compilazione di LiveStemPlayer..."
swiftc \
  "${SOURCES[@]}" \
  -o "$BIN_PATH" \
  -framework CoreMIDI \
  -framework AudioToolbox \
  -framework SwiftUI \
  -framework AppKit

if [[ "${1:-}" == "--build-only" ]]; then
  echo "Build completata: $BIN_PATH"
  exit 0
fi

echo "Avvio di LiveStemPlayer..."
exec "$BIN_PATH"