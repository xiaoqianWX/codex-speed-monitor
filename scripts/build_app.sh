#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexSpeedMonitor"
BUILD_DIR="${ROOT}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun was not found. Install Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"

xcrun swiftc \
  "${ROOT}/CodexSpeedMonitorViewer/App/CodexSpeedMonitorMenuApp.swift" \
  "${ROOT}/CodexSpeedMonitorViewer/CodexSpeedMonitorViewer.swift" \
  "${ROOT}/CodexSpeedMonitorViewer/Models/TelemetryModels.swift" \
  "${ROOT}/CodexSpeedMonitorViewer/Stores/TelemetryStore.swift" \
  "${ROOT}/CodexSpeedMonitorViewer/Support/Formatting.swift" \
  "${ROOT}/CodexSpeedMonitorViewer/Views/ReportView.swift" \
  "${ROOT}/CodexSpeedMonitorViewer/Views/WidgetView.swift" \
  -framework SwiftUI \
  -framework AppKit \
  -lsqlite3 \
  -o "${MACOS_DIR}/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CodexSpeedMonitor</string>
  <key>CFBundleIdentifier</key>
  <string>dev.codexspeedmonitor.viewer</string>
  <key>CFBundleName</key>
  <string>Codex Speed Monitor</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "${APP_DIR}"
