#!/bin/bash
# Packs the built app and the install notes into build/JustShowUp.zip for teammates.
# Run scripts/build-app.sh release first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/build"
APP="$(ls -d *.app | head -1)"
rm -rf JustShowUp JustShowUp.zip
mkdir JustShowUp
ditto "$APP" "JustShowUp/$APP"
cp "$ROOT/Resources/TeammateNotes.txt" "JustShowUp/READ ME FIRST.txt"
ditto -c -k --keepParent JustShowUp JustShowUp.zip
rm -rf JustShowUp
echo "Wrote $ROOT/build/JustShowUp.zip ($(du -h JustShowUp.zip | cut -f1 | tr -d ' '))"
