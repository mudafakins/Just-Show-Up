#!/bin/bash
# Publishes a new version of Just Show Up! to everyone.
# Usage: scripts/release.sh 0.3.0
#
# 1. Sets the version for the Mac and Windows apps, commits and pushes.
# 2. Builds the Mac app (signed with your local certificate) and zips it.
# 3. Publishes a GitHub Release with the Mac update attached.
# 4. GitHub then builds the Windows update and adds it to the same release
#    (about 10 minutes; see .github/workflows/windows.yml).
# Installed apps notice the new version and offer "Update to …" in settings.
#
# Uses the GitHub sign-in that `git push` already saved in your Keychain.
set -euo pipefail

REPO="mudafakins/Just-Show-Up"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
CURRENT="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: scripts/release.sh <new version>   (now at $CURRENT)" >&2
    exit 1
fi
newest="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
if [[ "$VERSION" == "$CURRENT" || "$newest" != "$VERSION" ]]; then
    echo "The new version must be higher than $CURRENT." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or discard your changes first." >&2
    exit 1
fi
if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "Switch to the main branch first." >&2
    exit 1
fi
security find-certificate -c "Just Show Up Local Signing" >/dev/null 2>&1 || {
    echo "The signing certificate is missing, so Mac updates couldn't be verified." >&2
    exit 1
}

TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
if [[ -z "$TOKEN" ]]; then
    echo "No saved GitHub sign-in. Run 'git push' once to sign in, then try again." >&2
    exit 1
fi
api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

echo "==> Setting version $VERSION"
echo "$VERSION" > VERSION
/usr/bin/sed -i '' -E "s/\"version\": \"[0-9.]+\"/\"version\": \"$VERSION\"/" windows/src-tauri/tauri.conf.json
/usr/bin/sed -i '' -E "1,5 s/\"version\": \"[0-9.]+\"/\"version\": \"$VERSION\"/" windows/package.json
/usr/bin/sed -i '' -E "1,10 s/^version = \"[0-9.]+\"/version = \"$VERSION\"/" windows/src-tauri/Cargo.toml
python3 - "$VERSION" <<'EOF'
import json, sys
p = "windows/package-lock.json"
lock = json.load(open(p))
lock["version"] = sys.argv[1]
lock["packages"][""]["version"] = sys.argv[1]
open(p, "w").write(json.dumps(lock, indent=2) + "\n")
EOF
python3 - "$VERSION" <<'EOF'
import re, sys
p = "windows/src-tauri/Cargo.lock"
s = open(p).read()
s = re.sub(r'(name = "just-show-up"\nversion = )"[0-9.]+"', r'\1"%s"' % sys.argv[1], s)
open(p, "w").write(s)
EOF

echo "==> Building the Mac app"
scripts/build-app.sh release
APP="build/Just Show Up!.app"
ZIP="build/JustShowUp-mac.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Pushing"
git add VERSION windows/src-tauri/tauri.conf.json windows/package.json windows/package-lock.json \
    windows/src-tauri/Cargo.toml windows/src-tauri/Cargo.lock
git commit -q -m "Release $VERSION"
git push -q origin main
SHA="$(git rev-parse HEAD)"

echo "==> Publishing release v$VERSION"
BODY="$(python3 -c 'import json,sys; print(json.dumps({"tag_name": "v"+sys.argv[1], "target_commitish": sys.argv[2], "name": "Just Show Up! "+sys.argv[1], "body": "**Already installed?** Update from the gear menu: Update to …\n\n**Mac (first install):** download JustShowUp-mac.zip, unzip it, drag Just Show Up! into Applications and open it. macOS blocks it the first time: open System Settings > Privacy & Security, scroll down, click Open Anyway next to Just Show Up!, then confirm.\n\n**Windows (first install):** download the setup .exe (GitHub adds it a few minutes after publishing) and run it. On the SmartScreen warning click More info > Run anyway."}))' "$VERSION" "$SHA")"
RELEASE="$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY")"
UPLOAD="$(printf '%s' "$RELEASE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')"
URL="$(printf '%s' "$RELEASE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["html_url"])')"
git fetch -q --tags origin

echo "==> Uploading the Mac update"
api -X POST -H "Content-Type: application/zip" --data-binary @"$ZIP" "$UPLOAD?name=JustShowUp-mac.zip" >/dev/null

echo
echo "Released $VERSION: $URL"
echo "Mac teammates can update now. Windows teammates can update once GitHub adds"
echo "the Windows files to the release (about 10 minutes; watch the Actions tab)."
