#!/bin/zsh
# Publish only the independently signed Chinese beta to Penny777btc/Compositor.
# Run release.sh first, then push the exact release commit and its tag to that fork.
# Usage: ./scripts/publish.sh VERSION FULL_COMMIT_SHA zh-beta-vVERSION [NOTES_FILE]
# Example: ./scripts/publish.sh 1.2.2.1 <40-character-SHA> zh-beta-v1.2.2.1 BETA.zh-Hans.md
# No repository override, tag creation, git push, or upstream update-feed changes.
set -euo pipefail

usage() {
  print -r -- "Usage: ./scripts/publish.sh VERSION FULL_COMMIT_SHA zh-beta-vVERSION [NOTES_FILE]"
}
fail() { print -u2 -r -- "$*"; exit 1; }
if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
(( $# == 3 || $# == 4 )) || { usage >&2; exit 1; }

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly REPO=Penny777btc/Compositor
readonly VERSION="$1"
readonly COMMIT="$2"
readonly TAG="$3"
NOTES_FILE="${4:-$PROJECT_DIR/BETA.zh-Hans.md}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Expected a four-component version, such as 1.2.2.1."
[[ "$COMMIT" =~ '^[0-9a-f]{40}$' ]] || fail "Pass the full, lowercase 40-character commit SHA."
[[ "$TAG" == "zh-beta-v$VERSION" ]] || fail "Tag must be zh-beta-v$VERSION."
[[ -f "$NOTES_FILE" && -s "$NOTES_FILE" ]] || fail "Release notes are missing or empty: $NOTES_FILE"

ACTUAL_COMMIT=$(git -C "$PROJECT_DIR" rev-parse --verify HEAD)
[[ "$ACTUAL_COMMIT" == "$COMMIT" ]] || fail "The requested commit must be this checkout's HEAD."
[[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || fail "Commit or move aside all working-tree changes before publishing."
LOCAL_TAG_COMMIT=$(git -C "$PROJECT_DIR" rev-parse --verify "refs/tags/$TAG^{commit}")
[[ "$LOCAL_TAG_COMMIT" == "$COMMIT" ]] || fail "Local tag $TAG does not point at $COMMIT."

settings=$(xcodebuild -project "$PROJECT_DIR/Compositor.xcodeproj" -scheme Compositor -configuration Release -showBuildSettings 2>/dev/null)
PROJECT_VERSION=$(print -r -- "$settings" | awk -F' = ' '!found && / MARKETING_VERSION = /{print $2; found=1}')
MINIMUM=$(print -r -- "$settings" | awk -F' = ' '!found && / MACOSX_DEPLOYMENT_TARGET = /{print $2; found=1}')
BUNDLE_ID=$(print -r -- "$settings" | awk -F' = ' '!found && / PRODUCT_BUNDLE_IDENTIFIER = /{print $2; found=1}')
[[ "$PROJECT_VERSION" == "$VERSION" ]] || fail "Requested version $VERSION differs from project version $PROJECT_VERSION."
[[ "$BUNDLE_ID" == com.penny777btc.compositor.zhbeta ]] || fail "Refusing to publish a different bundle: $BUNDLE_ID"
[[ "$MINIMUM" =~ '^[0-9]+(\.[0-9]+)*$' ]] || fail "Could not determine the minimum macOS version."

DIST="$PROJECT_DIR/dist"
DMG_NAME="Compositor-ZH-Beta-$VERSION.dmg"
DMG="$DIST/$DMG_NAME"
CHECKSUM="$DMG.sha256"
BUILD_INFO="$DMG.build-info.txt"
[[ -f "$DMG" && -f "$CHECKSUM" && -f "$BUILD_INFO" ]] || fail "Run scripts/release.sh first; the DMG, SHA-256 file, and build provenance are required."
EXPECTED_SHA=$(awk 'NR == 1 {print $1}' "$CHECKSUM")
ACTUAL_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
[[ "$EXPECTED_SHA" =~ '^[0-9a-f]{64}$' && "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || fail "DMG SHA-256 does not match the build checksum."
BUILD_VERSION=$(awk -F': ' '$1 == "Version" {print $2}' "$BUILD_INFO")
BUILD_COMMIT=$(awk -F': ' '$1 == "Commit" {print $2}' "$BUILD_INFO")
BUILD_SHA=$(awk -F': ' '$1 == "SHA256" {print $2}' "$BUILD_INFO")
[[ "$BUILD_VERSION" == "$VERSION" && "$BUILD_COMMIT" == "$COMMIT" && "$BUILD_SHA" == "$ACTUAL_SHA" ]] || fail "Build provenance does not match the requested version, commit, and DMG."
codesign --verify --strict --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Resolve this exact tag through the fork API, independently of the checkout's default remote.
REMOTE_TAG=$(gh api --hostname github.com "repos/$REPO/git/ref/tags/$TAG" --jq '.ref')
[[ "$REMOTE_TAG" == "refs/tags/$TAG" ]] || fail "Push the exact tag to $REPO before publishing."
REMOTE_COMMIT=$(gh api --hostname github.com "repos/$REPO/commits/$TAG" --jq '.sha')
[[ "$REMOTE_COMMIT" == "$COMMIT" ]] || fail "The tag on $REPO does not point at the requested commit."
if gh release view "$TAG" --repo "github.com/$REPO" >/dev/null 2>&1; then
  fail "Release $TAG already exists. This script never overwrites a release."
fi

WORK=$(mktemp -d /private/tmp/CompositorZHBetaPublish.XXXXXX)
trap 'print -r -- "Publish files retained at: $WORK"' EXIT
# Copy the verified artifact so the upload and checksum use the same snapshot.
cp "$DMG" "$WORK/$DMG_NAME"
UPLOAD_SHA=$(shasum -a 256 "$WORK/$DMG_NAME" | awk '{print $1}')
[[ "$UPLOAD_SHA" == "$ACTUAL_SHA" ]] || fail "The artifact changed while preparing the upload."
(cd "$WORK" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
printf 'Version: %s\nCommit: %s\nSHA256: %s\n' "$VERSION" "$COMMIT" "$UPLOAD_SHA" > "$WORK/$DMG_NAME.build-info.txt"
cp "$NOTES_FILE" "$WORK/release-notes.md"
printf '\n\nLSMinimumSystemVersion: %s\n' "$MINIMUM" >> "$WORK/release-notes.md"

echo "==> Repository: $REPO"
echo "==> Tag: $TAG; commit: $COMMIT"
echo "==> SHA-256: $UPLOAD_SHA"
gh release create "$TAG" "$WORK/$DMG_NAME" "$WORK/$DMG_NAME.sha256" "$WORK/$DMG_NAME.build-info.txt" \
  --repo "github.com/$REPO" --verify-tag --target "$COMMIT" --prerelease --latest=false \
  --title "Compositor 中文体验版 $VERSION" --notes-file "$WORK/release-notes.md"
echo "==> Release: https://github.com/$REPO/releases/tag/$TAG"
