#!/bin/bash
# Builds build.noindex/Swivel.app (release, Apple silicon, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Swivel"

APP=build.noindex/Swivel.app  # .noindex keeps Spotlight from listing a second Swivel
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Swivel"

# App icon from Resources/icon-1024.png (regenerate with: swift scripts/icon.swift Resources/icon-1024.png)
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Swivel</string>
    <key>CFBundleIdentifier</key><string>com.local.swivel</string>
    <key>CFBundleName</key><string>Swivel</string>
    <key>CFBundleDisplayName</key><string>Swivel</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Finder right-click items; an empty NSRequiredContext makes macOS show them by default -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Convert with Swivel</string></dict>
            <key>NSMessage</key><string>convertFiles</string>
            <key>NSPortName</key><string>Swivel</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.item</string><string>public.folder</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Share with Swivel</string></dict>
            <key>NSMessage</key><string>fileActions</string>
            <key>NSPortName</key><string>Swivel</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.item</string><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
