# Third-party software

Dropster itself is MIT-licensed (see LICENSE).

Dropster's own code has no third-party Swift dependencies. It links system frameworks
(Foundation, AppKit, SwiftUI, ImageIO, CoreGraphics, QuickLookThumbnailing, CryptoKit in tests)
and the system `zlib` and `sqlite3`.

At runtime it invokes these separately installed programs if present. They are **not**
bundled with Dropster today; each is used under its own licence:

| Tool | Used for | Licence |
|---|---|---|
| FFmpeg / ffprobe | Video, audio, JPEG encoding, SSIM, media analysis | LGPL 2.1+ / GPL 2+ depending on build (Homebrew builds include GPL components such as x264/x265) |
| cwebp (libwebp) | WebP encoding | BSD 3-Clause |
| zstd | Zstandard | BSD / GPL 2 dual |
| xz | XZ | 0BSD / public domain (liblzma) |
| brotli | Brotli | MIT |
| gzip, zip, unzip | Gzip/ZIP | GPL 3 (gzip), Info-ZIP |
| Ghostscript (optional) | Stronger PDF compression | AGPL 3 |

If Dropster ever bundles these binaries, their licence texts and (for GPL/LGPL builds) source
offers must be added here and to the app bundle.
