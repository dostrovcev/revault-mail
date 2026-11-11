#!/bin/bash
# Собирает «Re:Vault Mail.app» и zip для релиза в build/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
# номер сборки растёт с каждой сборкой: пересборки одной версии различимы в Settings > About
BUILD="$(date +%Y%m%d%H%M)"
APP="build/Re:Vault Mail.app"
rm -rf build && mkdir -p build

swift build -c release --disable-sandbox
BIN="$(swift build -c release --disable-sandbox --show-bin-path)/ReVaultMail"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReVaultMail"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# ключ входа Google встраивается, если лежит рядом (в git не попадает)

swift scripts/make_icon.swift build >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Re:Vault Mail</string>
  <key>CFBundleDisplayName</key><string>Re:Vault Mail</string>
  <key>CFBundleIdentifier</key><string>io.revault.mail.oss</string>
  <key>CFBundleExecutable</key><string>ReVaultMail</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Re:Vault</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
  </dict>
</dict>
</plist>
PLIST

# Подпись ad-hoc: без аккаунта разработчика Apple, достаточно для своего мака.
codesign --force --deep --sign - "$APP"

(cd build && ditto -c -k --sequesterRsrc --keepParent "Re:Vault Mail.app" "ReVaultMail-${VERSION}.zip")
echo "build/ReVaultMail-${VERSION}.zip (build ${BUILD})"
