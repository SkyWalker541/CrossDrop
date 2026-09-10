#!/usr/bin/env bash
# Builds the two installable plugin zips into releases/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

rm -rf releases
mkdir -p releases

zip -r -q releases/CrossDrop-SD-Plugin.zip crosspoint-plugin/crossdrop
zip -r -q releases/CrossDrop-Plugin.zip koreader-plugin/crossdrop.koplugin

echo "Built:"
ls -1 releases/