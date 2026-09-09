#!/bin/bash
# Ship a new Excalicast release + update the Homebrew cask, in one shot.
#
#   bash native/release.sh 0.3.0
#
# Does: build the app at the given version -> package the .dmg -> compute its sha256 ->
# create a GitHub release with the .dmg -> bump version+sha256 in the genc-v/homebrew-tap cask
# and push. After it finishes, users get it with:  brew upgrade --cask excalicast
set -euo pipefail

VERSION="${1:?usage: bash native/release.sh X.Y.Z}"
NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
DMG="$NATIVE_DIR/dist/Excalicast.dmg"

RELEASE_REPO="genc-v/Excalicast"
TAP_REPO="genc-v/homebrew-tap"
BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"

echo "==> Building + packaging v$VERSION (branch $BRANCH)"
VERSION="$VERSION" bash "$NATIVE_DIR/build.sh"
bash "$NATIVE_DIR/makedmg.sh"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "    sha256 $SHA"

echo "==> Pushing branch + creating GitHub release v$VERSION"
git -C "$ROOT_DIR" push origin "$BRANCH"
if gh release view "v$VERSION" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" --repo "$RELEASE_REPO" --clobber
else
  gh release create "v$VERSION" "$DMG" --repo "$RELEASE_REPO" --target "$BRANCH" \
    -t "Excalicast $VERSION" -n "Excalicast $VERSION"
fi

echo "==> Updating cask in $TAP_REPO"
TMP="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TMP/tap" -- -q
CASK="$TMP/tap/Casks/excalicast.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TMP/tap" commit -aqm "excalicast $VERSION"
git -C "$TMP/tap" push -q
rm -rf "$TMP"

echo "==> Released v$VERSION. Update with:  brew upgrade --cask excalicast"
