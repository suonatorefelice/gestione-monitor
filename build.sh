#!/bin/zsh
# Compila "Gestione Monitor.app" (nessun Xcode richiesto)
set -e
cd "$(dirname "$0")"
APP="Gestione Monitor.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos14.0 -parse-as-library -swift-version 5 Sources/GestioneMonitor.swift -o "$APP/Contents/MacOS/GestioneMonitor" -framework IOKit
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Gestione Monitor</string>
  <key>CFBundleDisplayName</key><string>Gestione Monitor</string>
  <key>CFBundleIdentifier</key><string>local.pasquale.monitornativo</string>
  <key>CFBundleExecutable</key><string>GestioneMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Creato $(pwd)/$APP"
