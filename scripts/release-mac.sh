#!/bin/bash
# Adds the Mac app to a release that's already published, at the same version.
# Usage: scripts/release-mac.sh
#
# For a release made without the Mac (e.g. a Windows-only fix published from a
# Windows PC): run this on the Mac that has the signing certificate, so Mac
# teammates get the same version number. It builds the version in VERSION from
# main and uploads JustShowUp-mac.zip to release v<VERSION>, replacing any old one.
#
# Uses the GitHub sign-in that `git push` already saved in your Keychain.
set -euo pipefail

REPO="mudafakins/Just-Show-Up"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or discard your changes first." >&2
    exit 1
fi
if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "Switch to the main branch first." >&2
    exit 1
fi
git pull -q --ff-only origin main
VERSION="$(tr -d '[:space:]' < VERSION)"

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

RELEASE="$(api "https://api.github.com/repos/$REPO/releases/tags/v$VERSION")" || {
    echo "There's no release v$VERSION yet. Use scripts/release.sh for a new version." >&2
    exit 1
}
read -r UPLOAD URL OLD_ASSET < <(printf '%s' "$RELEASE" | python3 -c '
import json, sys
r = json.load(sys.stdin)
old = next((a["id"] for a in r["assets"] if a["name"] == "JustShowUp-mac.zip"), "")
print(r["upload_url"].split("{")[0], r["html_url"], old)')

echo "==> Building the Mac app ($VERSION)"
scripts/build-app.sh release
APP="build/Just Show Up!.app"
ZIP="build/JustShowUp-mac.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${OLD_ASSET:-}" ]]; then
    api -X DELETE "https://api.github.com/repos/$REPO/releases/assets/$OLD_ASSET" >/dev/null
fi
echo "==> Uploading the Mac update"
api -X POST -H "Content-Type: application/zip" --data-binary @"$ZIP" "$UPLOAD?name=JustShowUp-mac.zip" >/dev/null

echo
echo "Added the Mac app to $VERSION: $URL"
echo "Mac teammates can update now."
