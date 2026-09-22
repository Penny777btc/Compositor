#!/bin/zsh
# Builds the independently signed and notarized Simplified Chinese beta DMG.
#
# Needs, all kept out of this repository:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarization credentials saved once with:
#       xcrun notarytool store-credentials "compositor-zh-beta-notary" --apple-id "…" --team-id YY4JJY99NB
#   - create-dmg (brew install create-dmg)
# The DMG window background is scripts/dmg/dmg-bg.jpg (600 × 380, the window's exact size) plus
# dmg-bg-retina.jpg (1200 × 760) for Retina displays.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP=Compositor
TEAM=YY4JJY99NB
IDENTITY="Developer ID Application: PEIWEN WU (YY4JJY99NB)"
NOTARY_PROFILE=compositor-zh-beta-notary
SOURCE_COMMIT=$(git -C "$PROJECT_DIR" rev-parse --verify HEAD)
[[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || {
  print -u2 -- "Commit or move aside all working-tree changes before building a release."; exit 1
}
# Each run keeps its own archive and logs outside synced folders. No previous build is deleted.
WORK=$(mktemp -d /private/tmp/CompositorZHBetaRelease.XXXXXX)
trap 'print -r -- "Build files retained at: $WORK"' EXIT
DIST="$PROJECT_DIR/dist"

settings=$(xcodebuild -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(print -r -- "$settings" | awk -F' = ' '!found && / MARKETING_VERSION = /{print $2; found=1}')
BUILD=$(print -r -- "$settings" | awk -F' = ' '!found && / CURRENT_PROJECT_VERSION = /{print $2; found=1}')
MINIMUM=$(print -r -- "$settings" | awk -F' = ' '!found && / MACOSX_DEPLOYMENT_TARGET = /{print $2; found=1}')
BUNDLE_ID=$(print -r -- "$settings" | awk -F' = ' '!found && / PRODUCT_BUNDLE_IDENTIFIER = /{print $2; found=1}')
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && -n "$BUILD" ]] || {
  print -u2 -- "Expected a four-component Chinese beta version and a build number."; exit 1
}
[[ "$BUNDLE_ID" == com.penny777btc.compositor.zhbeta ]] || {
  print -u2 -- "Refusing to package a different bundle: $BUNDLE_ID"; exit 1
}
DMG_NAME="Compositor-ZH-Beta-$VERSION.dmg"
[[ ! -e "$DIST/$DMG_NAME" && ! -e "$DIST/$DMG_NAME.sha256" && ! -e "$DIST/$DMG_NAME.build-info.txt" ]] || {
  print -u2 -- "An artifact for $VERSION already exists in $DIST. Move it aside before rebuilding."; exit 1
}
echo "==> $APP $VERSION ($BUILD)"
echo "==> Minimum macOS: $MINIMUM"

mkdir -p "$DIST"

echo "==> Archiving a Release build"
xcodebuild archive -quiet \
  -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$WORK/$APP.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM"

echo "==> Exporting, signed with Developer ID"
xcodebuild -exportArchive -quiet \
  -archivePath "$WORK/$APP.xcarchive" \
  -exportOptionsPlist "$PROJECT_DIR/scripts/ExportOptions.plist" \
  -exportPath "$WORK/export"
APP_PATH="$WORK/export/$APP.app"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP_PATH" "$WORK/$APP.zip"
xcrun notarytool submit "$WORK/$APP.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Building the DMG window"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
DISPLAY_APP="Compositor 中文体验版.app"
cp -R "$APP_PATH" "$STAGE/$DISPLAY_APP"
cp "$PROJECT_DIR/LICENSE" "$PROJECT_DIR/BETA.zh-Hans.md" "$STAGE/"
DMG="$WORK/$DMG_NAME"
# Icon centers in the DMG window, in points from its top-left.
APP_X=160
APPLICATIONS_X=440
ICON_Y=180
background=()
LOW="$PROJECT_DIR/scripts/dmg/dmg-bg.jpg"
HIGH="$PROJECT_DIR/scripts/dmg/dmg-bg-retina.jpg"
if [[ -f "$LOW" && -f "$HIGH" ]]; then
  # Finder takes one background file; a TIFF holding both sizes stays sharp on Retina displays.
  sips -s format png -s dpiWidth 72 -s dpiHeight 72 "$LOW" --out "$WORK/background.png" >/dev/null
  sips -s format png -s dpiWidth 144 -s dpiHeight 144 "$HIGH" --out "$WORK/background@2x.png" >/dev/null
  tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null
  background=(--background "$WORK/background.tiff")
elif [[ -f "$LOW" ]]; then
  background=(--background "$LOW")
fi
create-dmg \
  --volname "Compositor 中文体验版" \
  --window-pos 200 120 --window-size 600 380 \
  --icon-size 128 --text-size 13 \
  --icon "$DISPLAY_APP" "$APP_X" "$ICON_Y" --hide-extension "$DISPLAY_APP" \
  --app-drop-link "$APPLICATIONS_X" "$ICON_Y" \
  "${background[@]}" \
  "$DMG" "$STAGE"

echo "==> Signing and notarizing the DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

echo "==> What Gatekeeper will say on another Mac"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP_PATH"
[[ "$(git -C "$PROJECT_DIR" rev-parse --verify HEAD)" == "$SOURCE_COMMIT" && -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || {
  print -u2 -- "Sources changed during the build. The retained artifacts will not be copied to dist."; exit 1
}
(cd "$WORK" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
ARTIFACT_SHA=$(awk 'NR == 1 {print $1}' "$WORK/$DMG_NAME.sha256")
printf 'Version: %s\nCommit: %s\nSHA256: %s\n' "$VERSION" "$SOURCE_COMMIT" "$ARTIFACT_SHA" > "$WORK/$DMG_NAME.build-info.txt"
for artifact in "$DMG_NAME" "$DMG_NAME.sha256" "$DMG_NAME.build-info.txt"; do
  [[ ! -e "$DIST/$artifact" ]] || { print -u2 -- "Artifact appeared during the build: $DIST/$artifact"; exit 1; }
done
cp -n "$DMG" "$WORK/$DMG_NAME.sha256" "$WORK/$DMG_NAME.build-info.txt" "$DIST/"
echo "==> DMG: $DIST/$DMG_NAME"
echo "==> SHA-256: $DIST/$DMG_NAME.sha256"
echo "==> Build provenance: $DIST/$DMG_NAME.build-info.txt"
echo "==> Signed app: $APP_PATH"
