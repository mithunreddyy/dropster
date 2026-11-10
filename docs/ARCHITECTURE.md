# Architecture

Dropster is a Swift package with four targets. Processing code never imports SwiftUI, and
the app never touches codecs directly.

```
DropsterApp (SwiftUI, AppKit)        dropster-cli
        │                                 │
        └──────────────┬──────────────────┘
                       ▼
              DropsterEngines   ── codec adapters: ImageIO, PNG optimizer, JPEG (mjpeg),
                       │            WebP (cwebp), FFmpeg, archives; analysis; verification
                       ▼
               DropsterCore     ── domain model, routing, processor, job queue,
                                    workspace, output planning, history (SQLite)
```

## Core (`Sources/DropsterCore`)

| File | Responsibility |
|---|---|
| `Formats.swift` | `FormatID`, categories, extensions, lossy/alpha traits |
| `FileSignature.swift` | Detects format from magic bytes (incl. ISOBMFF brands, EBML doctype) |
| `JPEGQuality.swift` | Estimates IJG quality from the luminance DQT table |
| `FileReport.swift` | What analysis learned: image traits, media traits, pages |
| `Operations.swift` | `FileOperation` (optimize, convert, strip metadata, edit, export pages, long image, split, extract), `BatchOperation`, `ImageEdit` with exact EXIF-orientation algebra, preset options, page ranges |
| `Presets.swift` | `Preset` and the JSON `PresetStore` |
| `CloverLayout.swift` | Clover geometry and hit testing (unit-tested) |
| `Recommendations.swift` | `Advisor`: plain-language suggestions and the default action per file |
| `Engine.swift` | The `Engine` protocol, `ConversionEdge`, `StepContext`, errors |
| `ConversionRegistry.swift` | Format graph and Dijkstra route planning |
| `Processor.swift` | Runs one file: plan → steps in a private workspace → verify → size rule → commit |
| `JobQueue.swift` | Actor: bounded parallelism, per-engine limits, pause/resume/cancel/retry, event stream |
| `Workspace.swift` | Private temp folders (0700, under Caches) and `OutputPlanner` (naming, safe commit) |
| `HistoryStore.swift` | SQLite history of completed work |

### Routing

Each engine publishes edges (`from → to`, cost). `ConversionRegistry.route` runs Dijkstra
bounded to 3 hops. Lossy targets cost more than lossless ones, so multi-hop routes pass
through lossless intermediates (HEIC → PNG → WebP). Two rules keep routes sensible:

- A hop that changes category (image → video, video → audio, any → archive) must be the whole
  route. Without this the graph happily finds JPEG → GIF → MP4 → MP3.
- Edges are emitted in sorted order so ties resolve the same way in every process.

`Processor.targets(for:)` filters further per file: no audio targets for a silent video, no
video targets for a still image.

### Processing a file

1. `plan` turns the operation into steps (optimize = one same-format step on the first engine
   that lists the format as optimizable).
2. Each step writes into a fresh job folder in the workspace. Intermediate steps are forced
   lossless (`qualityOverride = 1`); only the final step decides quality.
3. After every step the `OutputVerifier` checks the file: signature matches, image decodes,
   media has a positive duration (ffprobe), archives pass their own integrity test.
4. Optimize, and conversions when "discard larger" is on, keep the original if the result is
   not smaller. Nothing is written in that case, and the UI says so.
5. `OutputPlanner.commit` moves the result into place with `moveItem`, which refuses to
   overwrite. Modification/creation dates and the quarantine flag are copied from the source.
6. The job folder is deleted whether the job succeeded, failed or was cancelled.

Originals are only ever opened for reading.

### Queue

`JobQueue` is an actor. Global parallelism is `min(cores − 1, RAM / 2 GB, 12)`. Each engine
declares `maxConcurrency` (FFmpeg 2, PNG 3, cwebp cores/2, ImageIO cores − 1) because
encoders that already multi-thread slow everything down when stacked. A failure never stops
the batch. Output names are reserved while a job runs so two jobs can't pick the same name.
Progress is throttled to 1% steps before being published.

## Engines (`Sources/DropsterEngines`)

| Engine | Optimizes | Converts | Notes |
|---|---|---|---|
| `PNGEngine` | PNG | – | In-house lossless optimizer (below) |
| `JPEGEngine` | JPEG | – | FFmpeg mjpeg + optimal Huffman; ICC and EXIF carried over; quality ceiling |
| `ImageIOEngine` | HEIC, AVIF, TIFF (and JPEG fallback) | images → JPEG/PNG/HEIC/AVIF/TIFF/GIF/BMP/JPEG 2000/PDF | Orientation baked when resizing; alpha flattened on white for JPEG; lossless metadata strip |
| `WebPEngine` | WebP | PNG/JPEG/TIFF → WebP | Lossless for PNG sources; images rotated upright first (cwebp ignores EXIF orientation) |
| `FFmpegEngine` | MP4/MOV/MKV (HEVC), WebM, MP3, M4A, Opus, FLAC | video ↔ video, video → GIF, audio ↔ audio | Stream copy when codecs fit; arguments built as arrays; progress from `-progress pipe:1` |
| `ArchiveEngine` | – | any file → zstd, xz, brotli, gzip, zip | Multi-threaded; verified with each tool's `-t` |
| `ImageEditEngine` | – | edit operations | Orientation-only edits of JPEG/HEIC/TIFF rewrite one EXIF tag; others render, then re-encode (JPEG through `JPEGEngine` with the original's ICC and metadata) |
| `TraceEngine` | – | images → SVG | Vision contour detection, polygon simplification, even-odd fill |
| `PDFEngine` | PDF | PDF → TXT; pages, long image, split, extract | PDFKit image recompression vs Ghostscript `pdfwrite`, smaller wins |
| `DocumentEngine` | – | DOCX/DOC/ODT/RTF/HTML/MD/TXT ⇄ each other and PDF | AppKit text system; Core Text pagination for PDF |
| `SubtitleEngine` | – | SRT ⇄ VTT, → TXT | Native parser; ASS via FFmpeg |
| `FitSizeEngine` | – | `fitSize` for images, video, audio | Quality binary search through the regular encoders, then √-scaled downsizing; two-pass x264 with a bits-per-pixel resolution ladder; computed audio bitrate; retries on overshoot |
| `UnpackEngine` | – | `unpack` for zip, 7z, tar, gz, xz, zst, br | libarchive (`bsdtar`) after a listing check; size monitor during extraction; link and special-file cleanup (see SECURITY.md) |
| `BatchProcessor` | – | many files → one PDF or ZIP | Not a `JobQueue` job; same workspace and commit rules |

Operations other than optimize/convert are routed by `Engine.supports(_:source:)`. Operations
that produce several files (`exportPages`, `splitPDF`, `unpack`) write a folder; `unpack`
skips per-file verification (contents can be anything) and hoists a single top-level item;
`fitSize` returns `keptOriginal` when the file already fits and fails if the result does not; the processor verifies
every file in it and commits the folder atomically.

Missing external tools remove their edges; the UI only offers what can run.

### PNG optimizer

`PNGCodec.swift` contains a strict decoder (CRC-checked chunks, bounded dimensions and data,
Adam7 de-interlacing, every colour type and depth) and an optimizing encoder:

1. **Reduce** without loss: 16 → 8 bit when every sample is a repeated byte, drop an all-opaque
   alpha channel, RGB → gray when R = G = B, ≤256 colours → palette (translucent entries first
   so tRNS stays short), pack gray/palette into 1/2/4 bits.
2. **Search** filter strategies (none, per-row minimum sum of absolute differences, Paeth) ×
   zlib strategies (default, filtered, RLE). Large images are scored on three sample bands and
   only the best two candidates are compressed at full size.
3. **Compress** in parallel 1 MB blocks (pigz technique).
4. **Verify**: decode the result and compare every pixel with the original. A mismatch is an
   error, never a silent output.

Colour chunks (iCCP, sRGB, gAMA, cHRM, cICP, pHYs) are always kept. Animated PNG is refused
rather than flattened.

### JPEG metadata

`JPEGMetadata.strip` rewrites a JPEG's segments without touching the entropy-coded scan:
JFIF, ICC and Adobe segments stay; EXIF, XMP, IPTC and comments go. If the photo had a
non-default orientation, a minimal EXIF block with only that tag is written so it still
displays upright.

### Analysis and quality

`FileAnalyzer` combines the signature, ImageIO properties (dimensions, depth, profile,
orientation, EXIF/GPS presence, frame count), the JPEG quality estimate, ffprobe JSON for
media and CGPDFDocument for page counts. `QualityMeter` measures SSIM for lossy image results.

## App (`Sources/DropsterApp`)

`AppModel` (`@MainActor @Observable`) owns the item list, consumes the queue's event stream
and records history. Analysis runs in detached tasks. Thumbnails come from QuickLook. See
`docs/DESIGN.md` for the interface.

| File | Responsibility |
|---|---|
| `CloverMenu.swift` | Builds both clover faces for a set of files from what the processor can do |
| `CloverController.swift` | Panel, pointer/drop/click handling, dwell timers, flip, keyboard/scroll monitors |
| `CloverView.swift` | Leaf, leaflet, core and stem drawing |
| `CloverTriggers.swift` | Global drag watcher, ⌥⌘D hot key (Carbon), Finder selection, Services provider |
| `DropReader.swift` | Files from any drop: file URLs, file promises, web downloads, image data |
| `CursorHUD.swift` | Progress ring at the cursor |
| `CropStudio.swift` | Crop session, canvas, aspect dial |

**Global drag detection.** A global left-mouse-down monitor starts a 30 Hz poll of
`NSEvent.pressedMouseButtons` and `modifierFlags` that stops on release. If the drag
pasteboard's change count moved since the press, the modifier is held and the pasteboard
holds something readable, the clover opens at `NSEvent.mouseLocation`. No Accessibility
permission is needed; only Tab-to-flip during a drag needs it, and scrolling works regardless.

**Developer flags** for screenshots and manual checks: `--show-clover file… [--back] [--expand N]`,
`--crop file…`, `--run-preset N file…`, and `--self-test-clover drag|click <leaf> <leaflet> [--back] file…`,
which drives the real panel with a synthetic `NSDraggingInfo` (or clicks), waits for the jobs and
exits non-zero if any output is missing. `scripts/e2e.sh` runs a matrix of these.

**Instant dial.** The panel and its SwiftUI tree are built and laid out once at launch
(`prewarm`). On a drag the menu is built from a signature-only look at the files (a few bytes
each, no decoding or ffprobe) so the dial is on screen within ~50 ms; the full analysis then
refines the menu if it changes (for example, removing audio formats for a silent video). The
self-test prints the time-to-screen.

**Background utility.** First run registers a login item (`SMAppService.mainApp`). A login launch
(detected from the `kAEOpenApplication` event's `keyAELaunchedAsLogInItem`) starts with the
accessory policy and no window. `DockPresence` switches to the regular policy when a titled
window becomes key and back to accessory when the last one closes. A user launch always ends
with the main window visible, even if SwiftUI restored "no windows". `--self-test-dock` checks
the close transition; `--background` simulates a login launch.

**Diagnostics.** The drag watcher records what it saw (mouse-downs, drags of files, whether the
modifier was held, when the clover was shown and dropped on) in Settings › Clover › Status and in
`~/Library/Logs/Dropster/clover.log`.

### Watch folders

`WatchRule`, `ArrivalTracker` and `WatchStore` live in Core (unit tested); `WatchFolderService`
in the app opens a `DispatchSource` vnode watcher per folder, so nothing polls while the folder
is quiet. A change triggers a scan; while files are settling (same size and date across scans
at least 1.5 s apart), scans repeat every 0.5 s. Each rule stores the names it has seen, so
files that arrived while the app was closed are found at launch. Ready files go through
`AppModel.runFromWatchFolder` with the output pinned to the rule's subfolder.

## Extending

Add a format: a `FormatID` case, its signature in `FileSignature`, and edges in an engine.
Add an engine: implement `Engine`, register it in `Engines.available()` (order sets
priority), add tests in `Tests/DropsterEnginesTests`.
