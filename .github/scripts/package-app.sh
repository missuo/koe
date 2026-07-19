#!/bin/bash
# Package Koe.app for release: embed koe-cli, codesign, optionally notarize, and zip.
#
# Usage: package-app.sh <app-path> <cli-path> <output-zip>
#
# Behavior is controlled by environment variables:
#   CODESIGN_IDENTITY                        Developer ID identity used for signing.
#                                            Falls back to ad-hoc signing when unset
#                                            (local/PR builds without certificates).
#   APPLE_ID, APPLE_APP_PASSWORD,
#   APPLE_TEAM_ID                            When all set (and CODESIGN_IDENTITY is set),
#                                            the app is notarized and stapled before zipping.
#   SPARKLE_BIN, SPARKLE_PRIVATE_KEY_FILE    When both set, the output zip is signed with
#                                            Sparkle's sign_update and a <zip>.sparkle.json
#                                            metadata file is written for appcast generation.
set -euo pipefail

APP_PATH="$1"
CLI_PATH="$2"
OUTPUT_ZIP="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/../../KoeApp/Koe/Koe.entitlements"

test -d "$APP_PATH"
test -x "$CLI_PATH"
test -f "$ENTITLEMENTS"

cp "$CLI_PATH" "$APP_PATH/Contents/MacOS/koe-cli"
chmod +x "$APP_PATH/Contents/MacOS/koe-cli"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "Signing with identity: $CODESIGN_IDENTITY"
  SIGN_FLAGS=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")

  # Sparkle's helper executables and XPC services live inside the framework
  # and must be signed individually before the framework bundle itself.
  SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SPARKLE_FW" ]; then
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW/Versions/B/Updater.app"
    for xpc in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc; do
      [ -e "$xpc" ] || continue
      codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$xpc"
    done
  fi

  # Sign nested code first (frameworks and dylibs, if any), then embedded
  # helper binaries, then the outer bundle. The entitlements are applied to
  # every executable that may capture audio under the hardened runtime.
  while IFS= read -r -d '' nested; do
    codesign "${SIGN_FLAGS[@]}" "$nested"
  done < <(find "$APP_PATH/Contents" -depth \( -name "*.dylib" -o -name "*.framework" \) -print0)

  codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_PATH/Contents/MacOS/koe-cli"
  codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_PATH"
else
  echo "CODESIGN_IDENTITY not set; using ad-hoc signature"
  codesign --force --deep --sign - "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [ -n "${CODESIGN_IDENTITY:-}" ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  echo "Submitting $APP_PATH for notarization"
  NOTARIZE_ZIP="$(mktemp -d)/notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

  SUBMIT_JSON=$(xcrun notarytool submit "$NOTARIZE_ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait --timeout 30m \
    --output-format json)
  rm -f "$NOTARIZE_ZIP"
  echo "$SUBMIT_JSON"

  SUBMISSION_ID=$(echo "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  STATUS=$(echo "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
  if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization failed with status: $STATUS" >&2
    xcrun notarytool log "$SUBMISSION_ID" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" >&2 || true
    exit 1
  fi

  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "Notarization credentials not set; skipping notarization" >&2
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_ZIP"

if [ -n "${SPARKLE_BIN:-}" ] && [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  echo "Signing $OUTPUT_ZIP for Sparkle"
  SIGN_OUTPUT=$("$SPARKLE_BIN/sign_update" -f "$SPARKLE_PRIVATE_KEY_FILE" "$OUTPUT_ZIP")
  ED_SIGNATURE=$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
  if [ -z "$ED_SIGNATURE" ]; then
    echo "ERROR: failed to extract sparkle:edSignature" >&2
    echo "$SIGN_OUTPUT" >&2
    exit 1
  fi

  ZIP_LENGTH=$(stat -f%z "$OUTPUT_ZIP")
  APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
  APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
  MIN_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP_PATH/Contents/Info.plist")

  ED_SIGNATURE="$ED_SIGNATURE" ZIP_LENGTH="$ZIP_LENGTH" APP_VERSION="$APP_VERSION" \
  APP_BUILD="$APP_BUILD" MIN_SYSTEM_VERSION="$MIN_SYSTEM_VERSION" OUTPUT_ZIP="$OUTPUT_ZIP" \
  python3 - <<'PY'
import json, os
with open(os.environ["OUTPUT_ZIP"] + ".sparkle.json", "w") as f:
    json.dump({
        "signature": os.environ["ED_SIGNATURE"],
        "length": int(os.environ["ZIP_LENGTH"]),
        "version": os.environ["APP_VERSION"],
        "build": os.environ["APP_BUILD"],
        "minimum_system_version": os.environ["MIN_SYSTEM_VERSION"],
    }, f, indent=2)
PY
fi

echo "Packaged $OUTPUT_ZIP"
