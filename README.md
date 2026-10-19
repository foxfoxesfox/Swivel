# Swivel

A small offline file converter for the macOS menu bar. Start dragging a file, tap **Shift**, and a format wheel opens at the cursor. Release on a slice and Swivel writes a converted copy next to the original. The original is never changed or moved.

macOS 13+, Apple silicon. Everything runs on your Mac; nothing is uploaded.

## Just want the app?

Download [`dist/Swivel-1.0.dmg`](dist/Swivel-1.0.dmg) (or clone this repo and open that file), double-click it, and drag Swivel into Applications. The first launch needs one extra step; see [Share with a friend](#share-with-a-friend).

## Build

```bash
brew install ffmpeg      # needed for audio, video, WebP and AVIF
./build.sh               # -> build.noindex/Swivel.app
./test.sh                # optional: converts generated samples to every format and checks the results
```

## Install

```bash
cp -R build.noindex/Swivel.app /Applications/
open /Applications/Swivel.app
```

A pie-chart icon appears in the menu bar. Turn on **Launch at Login** from its menu (this works best once the app is in /Applications). Allow notifications when asked; that's how Swivel reports finished and failed conversions.

## Use

1. Start dragging one or more files (from Finder, the Desktop, anywhere).
2. While still holding the mouse button, **tap Shift**. The wheel appears.
3. Move onto a format (it highlights) and let go.
4. To cancel, let go in the centre ✕ or anywhere off the wheel.

The output lands next to the original: `photo.png` → `photo.jpg`, or `photo 2.jpg` if that name is taken. During a conversion the menu bar icon turns into an hourglass. Click the notification, or choose **Show Last Output in Finder**, to see the result.

| Input | Wheel options |
|---|---|
| JPG PNG HEIC TIFF BMP GIF WebP AVIF | JPG, PNG, HEIC, TIFF, BMP, GIF, PDF, WebP\*, AVIF\* |
| MP3 M4A WAV FLAC OGG Opus AIFF | each other\* |
| MP4 MOV MKV WebM | each other, GIF (≤720px wide, 15 fps), MP3\* |
| PDF | PNG / JPG (300 DPI), TXT, Split; Merge when 2+ PDFs are dragged |

\* needs ffmpeg. An option only appears if your ffmpeg has the encoder it needs.

Notes:
- Transparency is flattened onto white for JPG and AVIF.
- A multi-page PDF exported to PNG/JPG, or split, goes into a `<name> pages` folder.
- Merge joins files in name order into `<first file> merged.pdf`.
- For animated GIF/WebP input, only the first frame is converted.

Command-line mode (handy for scripts and testing):

```bash
Swivel.app/Contents/MacOS/Swivel --targets photo.png      # list options
Swivel.app/Contents/MacOS/Swivel --convert photo.png jpg  # convert
```

## Share with a friend

```bash
./make-dmg.sh            # -> dist/Swivel-1.0.dmg
```

Send `dist/Swivel-1.0.dmg` (AirDrop, Drive, a message), or point them at this repo. Your friend then:

1. Double-clicks the DMG. A window opens; they drag **Swivel** onto **Applications**.
2. Opens Swivel from Applications. The first time, macOS blocks it because it isn't notarized by Apple ("Apple could not verify…"). They click **Done**, then go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Swivel, and confirm. They only do this once.
   (On macOS 14 and older, right-click Swivel → **Open** → **Open** works too.)
3. Runs `brew install ffmpeg` if they want audio, video, WebP and AVIF conversions. Images and PDFs work without it.

Skipping the warning entirely needs an Apple Developer ID ($99/year) to sign and notarize the app.

`make-dmg.sh` asks macOS for permission to control Finder the first time (to lay out the window). If you decline, the DMG still works, just without the arrow background.
