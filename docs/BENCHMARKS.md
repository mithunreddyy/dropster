# Benchmarks

Every quality setting in Dropster was chosen from measurements, not intuition. This file
records those measurements and how to reproduce them.

## How to run

```sh
swift build -c release --product dropster-cli
.build/release/dropster-cli bench path/to/corpus --out report.md
.build/release/dropster-cli ssim original.jpg candidate.webp
```

`bench` runs each applicable operation in every mode, records size, wall time and, for lossy
image outputs, SSIM against the original (both rendered upright to PNG by ImageIO first, then
compared with FFmpeg's `ssim` filter in RGB). Outputs are written to a scratch folder and deleted.

## Corpus

Four aerial landscape photos shipped with macOS (`/System/Library/Wallpapers/.default/DefaultAerial.jpg`
and `idleassetsd` snapshots), downscaled to ≤2400 px and stored as lossless PNG references
(`ref*.png`). `phone*.jpg` are those references saved by FFmpeg at IJG quality ≈91, standing in
for camera JPEGs. `shot.png` is a synthetic, highly saturated fractal (worst case for chroma
subsampling). `tone.wav` is a 5 s sine.

This corpus is small. It is enough to calibrate defaults and catch regressions; it is not a
substitute for a broad photographic test set (see "Known gaps").

## Finding 1: ImageIO's JPEG encoder is inefficient

Apple's ImageIO JPEG writer uses **flat quantisation tables** (every DCT coefficient gets the
same step; at `quality = 0.6` every entry is 4) and turns chroma subsampling off at
`quality ≥ 0.75`. At equal SSIM, FFmpeg's `mjpeg` encoder (Annex K tables, optimal Huffman)
produces much smaller files:

| Image | ImageIO JPEG | FFmpeg mjpeg | Saving at equal SSIM |
|---|---|---|---|
| ref1, SSIM ≈0.950 | 295 KB (q 0.45) | 241 KB (qscale 6) | 18% |
| ref1, SSIM ≈0.967 | 484 KB (q 0.65) | 386 KB (qscale 3) | 20% |
| ref2, SSIM ≈0.936 | 203 KB (q 0.45) | 177 KB (qscale 5) | 13% |
| ref2, SSIM ≈0.969 | 465 KB (q 0.65) | 307 KB (qscale 3) | 34% |

So JPEG optimization uses FFmpeg `mjpeg` (`JPEGEngine`), with the original ICC profile spliced
back in and EXIF/XMP copied over losslessly with `CGImageDestinationCopyImageSource`.

FFmpeg qscale maps to IJG quality as **IJG ≈ 101 − 5 × qscale** (measured with Dropster's own
quantisation-table estimator: q2→91, q3→86, q4→81, q5→76, q6→71, q8→61, q10→52). The quality
ceiling uses this: a source saved at quality Q is never re-encoded with qscale below ⌈(101−Q)/5⌉.

## Finding 2: AVIF and WebP needed higher settings than common defaults

Sweep of quality vs SSIM (photos are JPEG sources at IJG≈91, so SSIM is relative to that):

| Format / quality | phone2 | phone3 | ref4 |
|---|---|---|---|
| AVIF 0.70 | 0.940 | 0.960 | 0.956 |
| AVIF 0.80 | 0.960 | 0.974 | 0.970 |
| AVIF 0.85 | 0.971 | 0.979 | 0.978 |
| WebP 80 | 0.939 | 0.951 | 0.959 |
| WebP 85 | 0.949 | 0.959 | 0.969 |
| WebP 90 | 0.962 | 0.971 | 0.976 |

Defaults: **Balanced** targets SSIM ≈0.97 (AVIF 0.82, WebP 88, HEIC 0.70, JPEG qscale 3);
**Smallest** targets ≈0.95 (AVIF 0.72, WebP 80, HEIC 0.60, JPEG qscale 5).

The saturated fractal (`shot.png`) plateaus at SSIM ≈0.946 in every lossy format at every
quality: 4:2:0 chroma subsampling, not quantisation, is the limit. That is why PNG → WebP
defaults to lossless WebP (SSIM 1.000, still 36–43% smaller than the PNG).

## Finding 3: PNG optimization

Dropster's PNG optimizer is lossless and verified pixel-for-pixel. Gains depend heavily on how
the PNG was written: an FFmpeg-written photo PNG shrinks 3–8%, an ImageIO-written one 14%.
Fastest mode (one attempt, zlib level 6) often cannot beat a decent encoder; the result is then
discarded and the original kept.

Large images, before and after two algorithmic changes (8000×4218 photo, 20.2 MB, Smallest):

| Version | Time | Peak memory | Result |
|---|---|---|---|
| All 9 filter×strategy attempts at full size, serial zlib | 141 s | 2.0 GB | 18.6 MB |
| Trial-compress 3 sample bands, run the best 2 at full size | 52 s | 948 MB | 18.6 MB |
| + pigz-style parallel deflate (1 MB blocks, 32 KB dictionary priming) | 16 s | ~950 MB | 18.6 MB |

## Current results (Balanced)

| File | Operation | Mode | Input | Output | Change | Time | SSIM |
| phone1.jpg | Optimize | Balanced | 694 KB | 405 KB | -41.7% | 0.05 s | 0.9717 |
| phone1.jpg | Convert to WebP | Balanced | 694 KB | 379 KB | -45.4% | 0.26 s | 0.9773 |
| phone1.jpg | Convert to AVIF | Balanced | 694 KB | 381 KB | -45.1% | 0.15 s | 0.9770 |
| phone1.jpg | Convert to HEIC | Balanced | 694 KB | 309 KB | -55.4% | 0.05 s | 0.9708 |
| phone2.jpg | Optimize | Balanced | 473 KB | 328 KB | -30.7% | 0.05 s | 0.9659 |
| phone2.jpg | Convert to WebP | Balanced | 473 KB | 268 KB | -43.3% | 0.19 s | 0.9555 |
| phone2.jpg | Convert to AVIF | Balanced | 473 KB | 304 KB | -35.8% | 0.06 s | 0.9639 |
| phone2.jpg | Convert to HEIC | Balanced | 473 KB | 293 KB | -38.1% | 0.04 s | 0.9669 |
| phone3.jpg | Optimize | Balanced | 417 KB | 264 KB | -36.6% | 0.04 s | 0.9715 |
| phone3.jpg | Convert to WebP | Balanced | 417 KB | 233 KB | -44.1% | 0.19 s | 0.9650 |
| phone3.jpg | Convert to AVIF | Balanced | 417 KB | 251 KB | -39.8% | 0.06 s | 0.9761 |
| phone3.jpg | Convert to HEIC | Balanced | 417 KB | 217 KB | -47.9% | 0.04 s | 0.9687 |
| ref4.png | Optimize | Balanced | 2 MB | 1.9 MB | -3.2% | 1.03 s | – |
| ref4.png | Convert to WebP | Balanced | 2 MB | 1.1 MB | -42.6% | 0.84 s | 1.0000 |
| ref4.png | Convert to AVIF | Balanced | 2 MB | 219 KB | -88.8% | 0.06 s | 0.9726 |
| ref4.png | Convert to HEIC | Balanced | 2 MB | 234 KB | -88.0% | 0.06 s | 0.9770 |
| shot.png | Optimize | Balanced | 530 KB | 453 KB | -14.4% | 0.38 s | – |
| shot.png | Convert to WebP | Balanced | 530 KB | 337 KB | -36.4% | 0.30 s | 1.0000 |
| shot.png | Convert to AVIF | Balanced | 530 KB | 64 KB | -87.9% | 0.13 s | 0.9452 |
| shot.png | Convert to HEIC | Balanced | 530 KB | 60 KB | -88.6% | 0.03 s | 0.9445 |
| tone.wav | Convert to FLAC | Balanced | 441 KB | 69 KB | -84.4% | 0.06 s | – |
| tone.wav | Convert to Opus | Balanced | 441 KB | 93 KB | -79.0% | 0.07 s | – |

Peak resident memory (largest of Dropster process and any single child tool): 790 MB
Machine: Apple M4 Pro · 12 cores · macOS Version 27.0.1 (Build 26A434)

The peak-memory figure is the larger of Dropster's own process and the largest single child
tool (FFmpeg, cwebp) across the whole run; lossless WebP at `-z 9` and SSIM measurement are the
heaviest children.

## Known gaps

- No broad photographic corpus yet (camera RAW, iPhone HEIC with Display P3, screenshots, line art).
- SSIM only; no perceptual metric such as SSIMULACRA 2 or Butteraugli.
- Video and audio presets are set from encoder documentation, not measured with VMAF.
- Energy usage is not measured.
