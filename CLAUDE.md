# DROPSTER

## Mission

Build DROPSTER as a privacy-first, native-feeling universal file conversion and compression desktop application for macOS, with a clear path to Windows and Linux support.

This product should compete with and exceed modern file utilities by combining:

- intelligent format conversion
- adaptive compression
- batch processing
- local-first privacy
- elegant macOS-native UX
- transparent quality and size comparisons

The system must never depend on cloud uploads or mandatory accounts.

## Product Direction

DROPSTER should help users:

- drag and drop supported files
- automatically detect file types and compatible outputs
- choose optimized conversion and compression presets
- compare original vs transformed files
- process files locally without uploading
- queue large jobs with progress, pause, resume, and retry
- create reusable workflows and presets
- use macOS-native interfaces and haptics where appropriate

## Non-Negotiable Principles

1. Privacy first: all processing happens locally by default.
2. Native feel: design should resemble a polished Apple utility, not a generic web dashboard.
3. High quality: no fake "successful" conversions or placeholder UI.
4. Verified improvements: never claim compression gains without benchmarking.
5. Safety: no unsafe archive extraction, no path traversal issues, no original-file corruption.
6. Performance: never block the main UI with expensive work.
7. Testability: every feature should be implemented, tested, and documented before being marked complete.

## Core Product Areas

### 1. Conversion Engine

Support conversion across:

- images
- video
- audio
- PDF and documents
- archives
- spreadsheets, presentations, and structured data
- subtitles and media metadata
- e-books, fonts, CAD, 3D assets, and geospatial files

Requirements:

- conversion registry with supported formats and dependencies
- automatic routing through intermediate formats when needed
- file signature detection instead of trusting extensions
- precise metadata handling and compatibility reporting

### 2. Compression Engine

Build an adaptive compression system with multiple strategies rather than a single algorithm for everything.

Core modes:

- maximum compression
- balanced
- maximum speed
- advanced custom mode

Support compression for:

- images: JPEG, PNG, WebP, AVIF, HEIC, JPEG XL, TIFF, GIF, SVG, BMP, RAW where practical
- video: MP4, MOV, MKV, WebM, AVI, GIF, ProRes where supported
- audio: MP3, AAC, ALAC, FLAC, WAV, AIFF, Opus, OGG, WMA
- PDF and archive files

Use libraries such as:

- FFmpeg
- libvips
- ImageMagick
- Apple ImageIO and Core Image
- Zstandard, Brotli, LZMA2, Deflate, libarchive, and others where appropriate

### 3. File Intelligence

Every imported file should be analyzed for:

- MIME type and file signature
- extension and content validity
- dimensions, duration, bitrate, codec, and quality markers
- metadata, color profile, file size, and compression traits
- safe optimization opportunities

The app should recommend sensible actions with clear language such as:

- "lossless optimization available"
- "WebP conversion may save space"
- "this operation would increase file size"

### 4. Workflows and Batch Processing

Implement:

- visual workflow builder
- conditional operations
- sequential and parallel processing
- presets for common use cases
- folder processing
- pause/resume/cancel/retry behavior
- queue management with estimated completion and status tracking
- adaptive concurrency based on CPU, RAM, GPU, and disk performance

### 5. Creative Features

Add features that clearly save time or improve quality, including:

- compression comparison studio
- side-by-side previews
- duplicate and similar file detection
- bulk metadata editing
- EXIF privacy cleaning
- social-media resizing presets
- PDF merge/split/reorder/extract tools
- archive preview without extraction
- clipboard conversion
- global keyboard shortcuts
- menu bar utility
- monitoring/watch folders
- history dashboard

## Technical Architecture

Preferred stack:

- Swift 6
- SwiftUI
- AppKit interoperability
- Core Image
- ImageIO
- AVFoundation
- VideoToolbox
- Accelerate
- Metal when it provides real value
- Rust for performance-critical reusable processing components where justified
- SQLite for local history, presets, workflows, and cached metadata

Module boundaries:

1. Presentation layer
2. Application orchestration layer
3. Domain layer
4. Conversion engine
5. Compression engine
6. File analysis engine
7. Codec adapters
8. Workflow engine
9. Persistence layer
10. Platform integration layer

Keep UI logic separate from processing logic. Never run expensive processing on the main thread.

## UI and Experience Standards

The UI should feel like a premium Apple utility.

Required qualities:

- mature light and dark appearance
- clean whitespace and restrained hierarchy
- contextual navigation
- elegant drop zones and empty states
- system accent color support
- subtle animations and responsive feedback
- clear metadata and quality summaries
- strong accessibility and keyboard support

Avoid:

- dashboard-style clutter
- generic card-heavy layouts
- placeholder buttons masquerading as features
- web-app styling patterns
- excessive gradients, drop shadows, or noisy motion

## Performance Expectations

Performance is a first-class requirement.

The app should optimize for:

- low memory usage
- multi-core utilization
- GPU acceleration where beneficial
- stream processing
- efficient caching and avoided duplicate work
- minimal disk I/O and improved throughput
- benchmarking and measurement across real workloads

Benchmark the following consistently:

- compression ratio
- encoding time
- decoding time
- peak memory
- CPU utilization
- output quality
- energy usage

## Privacy and Security

The app must remain local-first.

Requirements:

- no mandatory cloud uploads
- no telemetry by default
- no network dependency for core processing
- secure temp-file handling
- sandboxed file access where appropriate
- safe extraction and resource limits for malformed files
- dependency auditing and license compliance
- secure cleanup of temporary data when feasible

## Quality Gates

Every feature must be validated before it is considered complete.

Required test coverage:

- unit tests
- integration tests
- conversion correctness checks
- compression regression tests
- memory stress tests
- large-file tests
- malformed-file tests
- UI automation and accessibility tests
- cross-platform validation where applicable

The app must verify that:

- outputs open correctly
- metadata behaves as configured
- lossless operations stay lossless
- canceled jobs clean up correctly
- failed jobs do not corrupt originals
- batch operations remain stable

## Development Sequence

Follow this order:

1. research and architecture
2. design system and UI patterns
3. core app shell and file import pipeline
4. conversion registry and job orchestration
5. compression intelligence and codec integration
6. advanced features and workflow tooling
7. hardening, benchmarking, packaging, documentation, and release preparation

Do not attempt to implement everything in one pass. Build the foundations first, then layer in advanced capabilities.

## Deliverables

The project should eventually include:

- production source code
- architecture design documentation
- UI design system documentation
- benchmark framework
- conversion and compression engine modules
- automated tests
- build scripts
- installation and developer documentation
- user documentation
- contribution guidelines
- license and third-party notices
- CI/CD configuration

## Implementation Rules

- no fake functionality or placeholder controls
- no cloud-only workflows for core features
- no unsafe file handling
- no unverified compression claims
- no unnecessary dependencies
- no monolithic architecture
- no blocking UI operations
- no unnecessary abstractions
- no hardcoded success states

When technical limitations are encountered, document them and implement the best feasible alternative.

## Working Style

Treat this as a serious production product, not a toy prototype.

Aim for a system that is:

- elegant
- robust
- secure
- fast
- testable
- maintainable
- genuinely useful to real users

The goal is not merely to convert files; the goal is to create an intelligent local processing ecosystem that feels premium and behaves reliably.
