#!/usr/bin/env bash
# Builds CcinnOpenRTB.app (release, ad-hoc signed) into ./dist.
#
#   scripts/build-app.sh                 # build dist/CcinnOpenRTB.app for this Mac's architecture
#   scripts/build-app.sh --universal     # Apple silicon + Intel
#   scripts/build-app.sh --open          # build and launch
#   CCINNOPENRTB_VERSION=1.2.3 scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CcinnOpenRTB"
BUNDLE_ID="io.github.whiteccinn.ccinnopenrtb"
VERSION="${CCINNOPENRTB_VERSION:-1.6.0}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ICON="$ROOT/Resources/AppIcon.icns"
INFO_PLIST="$ROOT/Resources/Info.plist"

ARCH_ARGS=()
OPEN_AFTER=false
for argument in "$@"; do
  case "$argument" in
    --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    --open) OPEN_AFTER=true ;;
    *) echo "unknown option: $argument" >&2; exit 1 ;;
  esac
done

cd "$ROOT"
swift build -c release --product "$APP_NAME" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"})"

if [[ ! -f "$ICON" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
  mkdir -p "$ROOT/Resources"
  iconutil -c icns "$ICONSET" -o "$ICON"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# Resources/Info.plist holds everything but the version (App Transport Security included; see the comment there).
PLIST="$APP/Contents/Info.plist"
cp "$INFO_PLIST" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
plutil -lint -s "$PLIST"
if [[ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" != "$BUNDLE_ID" \
   || "$(plutil -extract CFBundleExecutable raw "$PLIST")" != "$APP_NAME" ]]; then
  echo "Resources/Info.plist does not name $BUNDLE_ID / $APP_NAME" >&2
  exit 1
fi

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "$OPEN_AFTER" == true ]]; then
  open "$APP"
fi
