#!/bin/bash
# Packs the Windows app's source (with the Supabase settings) into
# build/JustShowUp-Windows-source.zip, to build the installer on a Windows PC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/JustShowUp-Windows-source"

# The publishable Supabase key is safe to ship; it is in every copy of the app anyway.
python3 - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
c = json.load(open(f"{root}/Config.local.json"))
open(f"{root}/windows/.env.local", "w").write(
    f"VITE_SUPABASE_URL={c['supabaseURL']}\nVITE_SUPABASE_KEY={c['supabaseKey']}\n")
PY

rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT"
rsync -a --exclude node_modules --exclude dist --exclude src-tauri/target --exclude src-tauri/gen \
    "$ROOT/windows/" "$OUT/"
(cd "$ROOT/build" && ditto -c -k --norsrc --noextattr --keepParent JustShowUp-Windows-source JustShowUp-Windows-source.zip)
rm -rf "$OUT"
echo "Wrote $OUT.zip ($(du -h "$OUT.zip" | cut -f1 | tr -d ' '))"
