<p align="center"><img src="assets/brand/dropster-mark.svg" width="160" alt="Dropster icon: four coloured petals around an open centre"></p>

# Dropster

Dropster is a native macOS app for compressing and converting files without uploading them
anywhere. Hold ⌥ Option while dragging files anywhere on screen and the **clover dial**, a
round four-petal dial with haptic detents, opens at your cursor with the formats that fit them: drop on a leaf and the result appears next to the
original. Or drop files on the window and Dropster picks a sensible action, shows how much it
saved and, for lossy images, the measured quality.

## What it does today

| | Optimize (same format) | Convert to |
|---|---|---|
| Images | JPEG, PNG (lossless), HEIC, AVIF, WebP, TIFF | JPEG, PNG, HEIC, AVIF, WebP, TIFF, GIF, BMP, JPEG 2000, PDF |
| Video | MP4, MOV, MKV (to HEVC), WebM | MP4, MOV, MKV, WebM, GIF |
| Audio | MP3, M4A, Opus, FLAC | MP3, M4A (AAC), Opus, FLAC, WAV, AIFF |
| Images, more | | SVG (traced), ICO (multi-size), ICNS |
| PDF | Compress (PDFKit, plus Ghostscript if installed) | Pages as PNG/JPEG/HEIC/TIFF/WebP, one long image, split, page ranges, text |
| Documents | – | Word (DOCX/DOC), OpenDocument, RTF, HTML, Markdown, text ⇄ each other and PDF, without Office |
| Subtitles | – | SRT ⇄ WebVTT ⇄ ASS, text |
| Any file | – | Zstandard, XZ, Brotli, Gzip, ZIP |
| Archives | – | Unpack ZIP, 7-Zip, Tar, Gzip, XZ, Zstandard, Brotli (contents shown before unpacking) |

Inputs also include Camera RAW, JPEG XL, PSD, ICO, AVI, Ogg and animated GIF.

**Tools:** crop with an aspect dial, rotate and flip (lossless for JPEG, HEIC and TIFF), grayscale,
background removal (on-device Vision), video frames as pictures, merge files into one PDF, pack
files into one ZIP.

**Fit Under a size:** pick 1, 5, 10 or 25 MB (or any size) and Dropster finds the best quality
that fits: a quality search for images, scaling down only when quality alone isn't enough;
two-pass H.264 for video, choosing the resolution the bitrate can carry; and a calculated
bitrate for audio. The result is always under the limit, or Dropster says it can't be done.

**Watch folders:** point Dropster at Downloads or Screenshots and every new file gets the action
you choose, into a subfolder. It waits for downloads to finish and catches files that arrived
while Dropster was closed.

**Presets** per file type: quality, resize, DPI, TIFF compression, ICO sizes, 720p, H.264/HEVC/AV1,
hardware encoding, frames per second, MP3 bitrate, output folder, file names and original dates.

### The clover

| Do | Get |
|---|---|
| Hold ⌥ while dragging files (Finder, Photos, a browser) | The clover at your cursor |
| Drop on a leaf | Its main action |
| Rest on a leaf | Its leaflets fan out: every format or variant |
| Drop on the centre | Each file's suggested action |
| Rest on the centre, press Tab, or scroll | It turns over to the tools: crop, rotate, colour, combine |
| ⌥⌘D | Clover for the Finder selection, or the clipboard (result goes back to the clipboard) |
| Finder right-click › Services › Convert with Dropster | Clover for those files |

After a drop, a ring at the cursor shows download speed (for web pictures), progress and the
space saved.

**Always ready, never in the way.** Dropster adds itself as a login item on first run and starts
silently at login: no window, no Dock icon, just the menu bar mark and the dial waiting for ⌥.
The dial appears within about 50 ms of the key being held. The Dock icon shows only while a
Dropster window is open. Turn off *Open at login* in Settings › General if you prefer.

- **Never larger, never overwritten.** If an optimized file isn't smaller, nothing is written.
  Originals are only read; results get new names.
- **Verified output.** Every result is checked to open as the right format before it's kept.
  Lossless PNG optimization is checked pixel by pixel.
- **Measured, calibrated quality.** Encoder settings come from SSIM measurements
  ([docs/BENCHMARKS.md](docs/BENCHMARKS.md)). JPEG optimization uses standard quantisation
  tables with optimal Huffman coding, 13–34% smaller than Apple's encoder at equal quality,
  and never re-encodes above the source's own quality.
- **Privacy.** Removes location and device serials by default; "Remove Metadata" is lossless
  for JPEG and PNG. Colour profiles and orientation are always kept.
- **Batch queue.** Folders, parallel processing with per-engine limits, pause, cancel, retry,
  time remaining, history.
- **Command line.** `dropster analyze | optimize | convert | clean | edit | pages | long | split | extract | merge | zip | bench | ssim`.

## Requirements

- macOS 15 or later, Apple silicon or Intel
- Xcode 16+ / Swift 6 to build
- Optional tools, found automatically in Homebrew or `/usr/local`:
  ```sh
  brew install ffmpeg webp zstd xz brotli
  ```
  Without FFmpeg, video, audio and JPEG optimization are hidden; without `cwebp`, WebP
  output is hidden. Everything else uses built-in macOS frameworks.

## Build and run

```sh
./scripts/install.sh            # build, install to /Applications and open
./scripts/build-app.sh          # just build build/Dropster.app (release, ad-hoc signed)

swift run Dropster              # run the app from source
swift run dropster-cli formats  # list what this machine can do
swift test                      # unit and integration tests
./scripts/e2e.sh                # every operation end to end, plus the clover in the real app
```

## Command line

```sh
dropster-cli analyze photo.jpg
dropster-cli optimize --mode smallest *.png
dropster-cli convert webp --max-size 2048 --out ~/Desktop/web photos/
dropster-cli clean IMG_0001.jpg            # remove metadata, image data untouched
dropster-cli edit rotate-right IMG_0001.jpg # lossless for JPEG/HEIC/TIFF
dropster-cli pages png --dpi 150 report.pdf
dropster-cli convert mp4 --height 720 --codec av1 clip.mov
dropster-cli merge scan1.jpg scan2.jpg notes.pdf
dropster-cli fit 10MB holiday.mov photo.png  # best quality under 10 MB
dropster-cli list backup.zip               # contents, without extracting
dropster-cli unpack backup.zip logs.tar.zst
dropster-cli bench corpus/ --out report.md
```

Inside the app bundle the CLI is at `Dropster.app/Contents/Resources/bin/dropster`.

## Documentation

- [User guide](docs/USER_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Interface design](docs/DESIGN.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [Security and privacy](docs/SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Third-party notices](THIRD-PARTY-NOTICES.md)

## Status and limits

Version 0.2. Not yet sandboxed or notarised (see [docs/SECURITY.md](docs/SECURITY.md)).

Not implemented yet: spreadsheets and presentations, HWP, e-books, CAD, 3D, maps and fonts;
visual workflows; conditional rules; duplicate detection; translations (the UI is
English only).

## Licence

Dropster is released under the [MIT License](LICENSE). Optional tools it runs (FFmpeg, cwebp,
Ghostscript and others) keep their own licences; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
