#!/bin/bash
# Builds dist/Swivel.dmg: open it, drag Swivel onto Applications. (Fixed name, so download links never break.)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build.noindex/Swivel.app/Contents/Info.plist)
VOL=Swivel
WORK=$(mktemp -d)
STAGE="$WORK/stage"; mkdir -p "$STAGE/.background"
ditto build.noindex/Swivel.app "$STAGE/Swivel.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/dmg-background.swift "$WORK/bg.png" 1 2>/dev/null
swift scripts/dmg-background.swift "$WORK/bg@2x.png" 2 2>/dev/null
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/bg.tiff" >/dev/null

[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -quiet || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size 40m "$WORK/rw.dmg"
hdiutil attach -quiet -noautoopen -nobrowse "$WORK/rw.dmg" -mountpoint "/Volumes/$VOL"

# Lay out the Finder window. Needs permission to control Finder; without it the DMG still works, just unstyled.
osascript <<OSA || echo "warning: couldn't style the window (allow Automation > Finder to get the arrow background)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 548}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:bg.tiff"
    set position of item "Swivel.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
rm -rf "/Volumes/$VOL/.fseventsd"
hdiutil detach -quiet "/Volumes/$VOL"
mkdir -p dist
rm -f dist/Swivel.dmg
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o dist/Swivel.dmg
rm -rf "$WORK"
# Update feed the app reads: version, download link, checksum, and this version's CHANGELOG section.
REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
REPO=${REPO:-foxfoxesfox/Swivel}
SHA=$(shasum -a 256 dist/Swivel.dmg | cut -d' ' -f1)
python3 - "$VERSION" "$SHA" "https://github.com/$REPO/raw/main/dist/Swivel.dmg" <<'PY'
import json, re, sys
version, sha, url = sys.argv[1:4]
try:
    text = open("CHANGELOG.md").read()
    m = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|^\[[^\]]+\]: |\Z)", text, re.S | re.M)
    notes = m.group(1).strip() if m else ""
except FileNotFoundError:
    notes = ""
if not notes:
    print(f"warning: CHANGELOG.md has no section for {version}; the update window will show no notes")
json.dump({"version": version, "url": url, "sha256": sha, "notes": notes}, open("dist/latest.json", "w"), indent=2)
PY
echo "Built dist/Swivel.dmg and dist/latest.json (version $VERSION)"
