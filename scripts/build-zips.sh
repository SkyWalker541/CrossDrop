#!/usr/bin/env bash
# Builds the installable KOReader plugin zip into releases/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

rm -rf releases
mkdir -p releases

# -x drops macOS AppleDouble silently-added files along with the README; only
# the six plugin source files belong in the installable zip.
( cd koreader-plugin && zip -r -q "$ROOT/releases/CrossDrop-Plugin.zip" crossdrop.koplugin -x "._*" -x "*.DS_Store" -x "*README*" )

echo "Built:"
ls -1 releases/