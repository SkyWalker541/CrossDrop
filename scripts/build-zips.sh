#!/usr/bin/env bash
# Builds the two installable plugin zips into releases/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

rm -rf releases
mkdir -p releases

( cd crosspoint-plugin && zip -r -q "$ROOT/releases/CrossDrop-SD-Plugin.zip" crossdrop )
( cd koreader-plugin && zip -r -q "$ROOT/releases/CrossDrop-Plugin.zip" crossdrop.koplugin )

echo "Built:"
ls -1 releases/