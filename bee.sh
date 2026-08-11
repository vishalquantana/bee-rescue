#!/usr/bin/env bash
# bee.sh — build (once) and run the Bee rescue tool.
#
#   ./bee.sh              # read battery once (default)
#   ./bee.sh scan         # list nearby BLE devices
#   ./bee.sh connect      # dump all services/characteristics
#   ./bee.sh monitor 180  # print battery every 180s while charging
#
# Requirements: macOS with Xcode command-line tools (`xcode-select --install`).
set -euo pipefail
cd "$(dirname "$0")"

BIN=bee_tool
SRC=bee_tool.swift

# Rebuild only if the source is newer than the binary.
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  echo "Building $BIN..."
  swiftc -framework CoreBluetooth -framework Foundation "$SRC" -o "$BIN"
fi

exec ./"$BIN" "$@"
