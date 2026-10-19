# Swivel

A small offline file converter for the macOS menu bar. Start dragging a file, tap **Shift**, and a format wheel opens at the cursor. Release on a slice and Swivel writes a converted copy next to the original. The original is never changed or moved.

macOS 13+, Apple silicon. Everything runs on your Mac; nothing is uploaded.

## Just want the app?

**[Download Swivel.dmg](https://github.com/foxfoxesfox/Swivel/raw/main/dist/Swivel.dmg)** (or clone this repo and open `dist/Swivel.dmg`), double-click it, and drag Swivel into Applications. The first launch needs one extra step; see [Share with a friend](#share-with-a-friend).

## Build

```bash
brew install ffmpeg      # needed for audio, video, WebP and AVIF
./build.sh               # -> build.noindex/Swivel.app
```

## Install

```bash
cp -R build.noindex/Swivel.app /Applications/
open /Applications/Swivel.app
```

A pie-chart icon appears in the menu bar, and a short welcome tour opens the first time: what Swivel does, how you want to convert, share and file actions, and a few settings (Launch at Login, notifications). Change any of it later in **How to Use & Settings…** (menu bar icon, or ⌘, while the menu is open). Allow notifications when asked; that's how Swivel reports results.

## Use

Swivel has two wheels, and each can open in two ways (pick them in the tour or in Settings):

| | Convert wheel | Share & file actions wheel |
|---|---|---|
| **Drag, then tap a key** | default ⇧ Shift | default ⌃ Control (can't be the same key) |
| **Right-click in Finder** | Convert with Swivel | Share with Swivel |

- **Drag, then tap a key:** start dragging one or more files, keep holding, tap the key, then let go on a slice.
- **Right-click in Finder:** right-click a file and choose the Swivel item. It's at the bottom of the menu, or inside **Services** when you have many. Then click a slice, or press Esc.
- To cancel, let go or click in the centre ✕, or anywhere off the wheel.

The actions wheel works on any files or folders: **AirDrop**, **Share** (Messages, Mail, Notes…), **Copy** (paste in Finder), **Move** (pick a folder), **Copy Path**, and **Terminal** (opens the folder).

For photos and videos it also has **Compress** and **Resize**, each with a small menu of presets:

- **Compress:** Best quality, Balanced or Smallest file. JPG, HEIC, WebP and AVIF keep their format; PNG, TIFF, BMP and GIF become JPG (on a white background). Videos keep their format. If the result wouldn't be smaller, no copy is kept.
- **Resize:** 50%, 25%, or fit within 1920 / 1280 / 640 px on the longest side. Never enlarges; transparency is kept.

Results are new files next to the original (`photo compressed.jpg`, `clip resized.mp4`), and the notification shows the size before → after.

Converted files land next to the original: `photo.png` → `photo.jpg`, or `photo 2.jpg` if that name is taken. During a conversion the menu bar icon turns into an hourglass. Click the notification, or choose **Show Last Output in Finder**, to see the result.

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
Swivel.app/Contents/MacOS/Swivel --convert photo.png compress-balanced   # also compress-high|small, scale-50, fit-1280
```

## Share with a friend

```bash
./make-dmg.sh            # -> dist/Swivel.dmg
```

Send `dist/Swivel.dmg` (AirDrop, Drive, a message), or point them at this repo. Your friend then:

1. Double-clicks the DMG. A window opens; they drag **Swivel** onto **Applications**.
2. Opens Swivel from Applications. The first time, macOS blocks it because it isn't notarized by Apple ("Apple could not verify…"). They click **Done**, then go to **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Swivel, and confirm. They only do this once.
   (On macOS 14 and older, right-click Swivel → **Open** → **Open** works too.)
3. For audio, video, WebP and AVIF they need ffmpeg (images and PDFs work without it). Swivel walks them through it: the last tour page and Settings have an **Install ffmpeg** button that opens Terminal and runs `brew install ffmpeg`, installing Homebrew first with its official installer if needed (that step asks for their Mac password). Swivel restarts itself when it's done. Dragging a song or video without ffmpeg shows a notification that leads to the same button.

Skipping the warning entirely needs an Apple Developer ID ($99/year) to sign and notarize the app.

`make-dmg.sh` asks macOS for permission to control Finder the first time (to lay out the window). If you decline, the DMG still works, just without the arrow background.
