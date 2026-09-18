#!/usr/bin/env bash
# Builds the installable KOReader plugin zip into releases/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

rm -rf releases
mkdir -p releases

# -x drops macOS AppleDouble silently-added files along with the plugin's
# README; only the plugin itself belongs in the installable zip (the six
# .lua files + icon.png).
( cd koreader-plugin && zip -r -q "$ROOT/releases/CrossDrop-Plugin.zip" crossdrop.koplugin -x "._*" -x "*.DS_Store" -x "*README*" )

echo "Built:"
ls -1 releases/
