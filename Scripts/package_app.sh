#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release --product QuotaFloat
BIN_DIR="$(swift build -c release --show-bin-path)"
CODEXBAR_PACKAGE="$ROOT/.build/checkouts/CodexBar"
swift build --package-path "$CODEXBAR_PACKAGE" -c release --product CodexBarCLI
CODEXBAR_BIN_DIR="$(swift build --package-path "$CODEXBAR_PACKAGE" -c release --show-bin-path)"
APP="$ROOT/dist/codex额度显示器.app"

rm -rf "$APP"
rm -rf "$ROOT/dist/QuotaFloat.app"
rm -rf "$ROOT/dist/CodexQuotaBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/QuotaFloat" "$APP/Contents/MacOS/QuotaFloat"
cp "$CODEXBAR_BIN_DIR/CodexBarCLI" "$APP/Contents/Helpers/CodexBarCLI"
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
