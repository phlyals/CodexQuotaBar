#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

SWIFT_BUILD_FLAGS=()
if [[ "${QUOTAFLOAT_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_BUILD_FLAGS+=(--disable-sandbox)
fi

swift build "${SWIFT_BUILD_FLAGS[@]}" -c release --product QuotaFloat
BIN_DIR="$(swift build "${SWIFT_BUILD_FLAGS[@]}" -c release --show-bin-path)"
CODEXBAR_PACKAGE="$ROOT/.build/checkouts/CodexBar"
if [[ "${QUOTAFLOAT_USE_EXISTING_CODEXBAR_CLI:-0}" != "1" ]]; then
  swift build "${SWIFT_BUILD_FLAGS[@]}" -c release --product CodexBarCLI
fi
if [[ ! -x "$BIN_DIR/CodexBarCLI" ]]; then
  echo "CodexBarCLI helper not found in the QuotaFloat release build directory." >&2
  exit 1
fi
APP="$ROOT/dist/codex额度显示器.app"

rm -rf "$APP"
rm -rf "$ROOT/dist/QuotaFloat.app"
rm -rf "$ROOT/dist/CodexQuotaBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/QuotaFloat" "$APP/Contents/MacOS/QuotaFloat"
cp "$BIN_DIR/CodexBarCLI" "$APP/Contents/Helpers/CodexBarCLI"
cp -R "$BIN_DIR/CodexBar_CodexBarCore.bundle" "$APP/Contents/Resources/"
sed -n 's/^MARKETING_VERSION=//p' "$CODEXBAR_PACKAGE/version.env" > "$APP/Contents/Helpers/VERSION"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/QuotaFloat-LICENSE.txt"
cp "$ROOT/PRIVACY.md" "$APP/Contents/Resources/PRIVACY.md"
cp "$ROOT/ThirdPartyLicenses/CodexBar-LICENSE.txt" "$APP/Contents/Resources/CodexBar-LICENSE.txt"
chmod +x "$APP/Contents/MacOS/QuotaFloat"
chmod +x "$APP/Contents/Helpers/CodexBarCLI"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/QuotaFloat")"
if [[ "$ARCHS" != "arm64" ]]; then
  echo "Expected an Apple Silicon arm64 build, got: $ARCHS" >&2
  exit 1
fi

HELPER_ARCHS="$(lipo -archs "$APP/Contents/Helpers/CodexBarCLI")"
if [[ "$HELPER_ARCHS" != "arm64" ]]; then
  echo "Expected an Apple Silicon arm64 helper, got: $HELPER_ARCHS" >&2
  exit 1
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
fi

echo "$APP"
