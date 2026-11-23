#!/bin/bash
# Builds build/Reko.app: release, universal (Apple Silicon + Intel). Usage: scripts/build-app.sh [--run]
#
# Signing: ad-hoc by default, which makes macOS re-ask for mic/speech permission after every rebuild.
# Set REKO_SIGN_IDENTITY to a certificate name from `security find-identity -p codesigning` (a free
# "Apple Development" cert, or a self-signed one made in Keychain Access) to keep permissions across builds.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Reko"
APP="build/Reko.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reko"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Reko</string>
  <key>CFBundleDisplayName</key><string>Reko</string>
  <key>CFBundleIdentifier</key><string>app.reko.teleprompter</string>
  <key>CFBundleExecutable</key><string>Reko</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Reko listens to your voice to scroll the script while you talk.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Reko recognizes your speech (on-device when your Mac supports the language) to keep the line you are reading in view.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Reko runs a small remote-control page your phone can open on the same Wi-Fi.</string>
  <key>NSBonjourServices</key><array><string>_http._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --deep --sign "${REKO_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Reko"))"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Reko 2>/dev/null || true
  open "$APP"
fi
