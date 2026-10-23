# Changelog

All notable changes to Swivel. Newest first.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [2.1] - 2026-10-23

Polish, progress you can see, and a new way to share.

### Added
- **Send** slice on the actions wheel for photos and videos: makes a copy that fits under **10 MB (Discord)**, **16 MB (WhatsApp)** or **25 MB (email)**.
  - Photos become JPG, lowering quality and then size until they fit.
  - Videos become MP4. The bitrate comes from the video's length, it's encoded in two passes for an accurate size, and the resolution drops when needed.
  - Location and other metadata are removed.
  - Videos too long to fit get a clear message instead of a bad result.
- **Progress ring** in the menu bar while converting, with the percentage in the menu.
- **Cancel** for running conversions. ffmpeg stops at once and the half-written file is deleted.
- **Show in Finder** and **Undo** buttons on result notifications. Undo moves only the files Swivel just made to the Trash, so it can be undone with Put Back.
- **Recent Conversions** menu with the last 10 results and their thumbnails.
- **File preview** in the centre of the wheel (a Quick Look thumbnail), with a count badge when several files are dragged.
- **Smart wheel:** the format you pick most for a file type moves to the top slice and is highlighted.
- **Keyboard control** for the wheel opened from Finder's right-click: 1–9 pick a slice, ← → move, Return picks, Esc cancels.

### Changed
- The wheel opens with a short spring animation and fades out when closed. With Reduce Motion on, it only fades.
- Pointing at the centre of the wheel shows ✕ over the preview, to make cancelling obvious.
- The welcome tour and Settings mention the Send slice.

## [2.0] - 2026-10-19

A guided setup, more ways to open the wheel, and a second wheel for sharing.

### Added
- **Welcome tour** on first launch, in four pages: what Swivel does, how you want to convert, share and file actions, and general settings.
- **How to Use & Settings** window, opened from the menu bar (⌘,) or by opening Swivel again from Applications or Spotlight. While it's open, Swivel has a Dock icon and a ⌘-Tab entry.
- **Choice of trigger key** for each wheel (Shift, Control, Option or Command). The two wheels can't share a key.
- **Finder right-click items:** "Convert with Swivel" and "Share with Swivel", each with its own on/off switch. Opened this way, the wheel works by clicking.
- **Share and file actions wheel** (default: Control while dragging): AirDrop, Share, Copy, Move, Copy Path, and open in Terminal.
- **Compress** (Best quality, Balanced, Smallest file) and **Resize** (50%, 25%, fit within 1920 / 1280 / 640 px) for photos and videos, with the size before → after in the notification.
- **Guided ffmpeg install:** a one-click button that opens Terminal and installs ffmpeg with Homebrew (and Homebrew itself if missing), then restarts Swivel.
- A notification explaining why, when a song or video is dragged without ffmpeg installed.
- Version number shown in Settings.

### Changed
- The installer is now `dist/Swivel.dmg`, a fixed name so download links never break.
- Builds go to `build.noindex/`, so Spotlight and Launchpad don't list a second copy of Swivel.
- The menu bar's ffmpeg item offers to install ffmpeg instead of copying a command.

### Removed
- `test.sh` is no longer published in the repository. It's a local development tool.

## [1.0] - 2026-10-19

First release: an offline file converter in the menu bar.

### Added
- **Format wheel at the cursor:** start dragging files, tap Shift, and let go on a format. The result is saved as a new file next to the original ("photo 2.jpg" if the name is taken). Originals are never changed or moved.
- **Images:** JPG, PNG, HEIC, TIFF, BMP, GIF and PDF, plus WebP and AVIF with ffmpeg. Transparency is flattened onto white for JPG and AVIF, and photo orientation is respected.
- **Audio:** MP3, M4A, WAV, FLAC, OGG, Opus and AIFF to each other (needs ffmpeg).
- **Video:** MP4, MOV, MKV and WebM to each other, plus GIF (up to 720 px wide, 15 fps) and MP3 audio extraction (needs ffmpeg).
- **PDF:** every page to PNG or JPG at 300 DPI, text to TXT, split into one PDF per page, and merge 2+ PDFs.
- Only formats that make sense for the dragged files, and that your ffmpeg can encode, appear on the wheel.
- Menu bar menu: status, ffmpeg found/missing, Launch at Login, Show Last Output in Finder, Quit.
- Notifications when a conversion finishes or fails.
- Command-line mode for scripts and testing: `Swivel --convert <file> <format>` and `Swivel --targets <file>`.
- Drag-to-Applications installer (DMG) and an original app icon.
- Works without the Accessibility permission. Nothing is uploaded; everything runs on your Mac.

[2.1]: https://github.com/foxfoxesfox/Swivel/compare/5d80321...HEAD
[2.0]: https://github.com/foxfoxesfox/Swivel/compare/f559c0e...5d80321
[1.0]: https://github.com/foxfoxesfox/Swivel/commit/f559c0e
