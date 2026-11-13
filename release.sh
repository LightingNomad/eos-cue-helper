#!/bin/bash
# Bump the version, tag and push. GitHub Actions builds the app and publishes the release;
# the installed app picks it up next launch.
#   ./release.sh 1.2.0 "What changed"
set -euo pipefail
cd "$(dirname "$0")"
NEW="${1:?usage: ./release.sh <version> [notes]}"
NOTES="${2:-}"
echo "$NEW" > VERSION
git add -A
git commit -m "Release $NEW${NOTES:+: $NOTES}"
git tag -a "v$NEW" -m "${NOTES:-Release $NEW}"
git push origin HEAD "v$NEW"
echo "✓ Pushed v$NEW — GitHub is building it: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions"
