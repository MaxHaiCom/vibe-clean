#!/bin/bash
set -e

APP_NAME="VibeGauge"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> 正在编译 ${APP_NAME}..."
cd "${BUILD_DIR}"

rm -rf "${APP_BUNDLE}" "${APP_NAME}"

swiftc -O \
    -target arm64-apple-macosx14.0 \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework UserNotifications \
    Sources/ProcessScanner.swift \
    Sources/ProxyManager.swift \
    Sources/DashboardView.swift \
    Sources/AppDelegate.swift \
    Sources/main.swift \
    -o "${APP_NAME}"

echo "==> 正在构建 App Bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

mv "${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp Resources/vibegauge-proxy.py "${APP_BUNDLE}/Contents/Resources/vibegauge-proxy.py"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "==> 正在签名..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> 编译构建完成: ${BUILD_DIR}/${APP_BUNDLE}"
