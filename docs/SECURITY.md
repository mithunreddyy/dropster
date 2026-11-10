# Security and privacy

## Local only

Dropster has no telemetry, accounts or update checks, and processes everything on this Mac.
The one network request it can make is user-initiated: when you drag a picture out of a web page
onto the clover and the browser provides only its URL, Dropster downloads it into Downloads
(ephemeral session, no cookies, HTTP 2xx only, 2 GB cap) and then processes the local copy.
Installing optional tools from Settings › Engines runs `brew install`, which uses Homebrew's
own network access.
External tools are run with an argument array (never a shell), a minimal environment
(`PATH=/usr/bin:/bin`, `LC_ALL=C`), stdin closed, and are terminated when a job is cancelled.

## Originals are never modified

- Originals are opened read-only.
- Work happens in `~/Library/Caches/Dropster/work/<uuid>/` (mode 0700). Each job's folder is
  removed when the job ends, whatever the outcome; folders left by a crash are purged on launch.
- Results are moved into place with `FileManager.moveItem`, which fails instead of
  overwriting. Names that already exist, or are reserved by a running job, get " 2", " 3"…
- Output names are sanitised (no `/`, `:`, control characters or leading dots), and the
  final path must sit directly in the chosen folder.

## Hostile input

- Format is detected from content; a mismatched extension is reported, not trusted.
- The PNG decoder checks every chunk length and CRC, caps images at 268 megapixels and
  compressed data at 1 GB, rejects unknown critical chunks and invalid filter types, and
  is fuzzed in the test suite (random corruption must throw, never crash).
- The JPEG segment parser bounds-checks every length.
- ImageIO decodes are capped at 400 megapixels.
- Archive extraction (`UnpackEngine`) reads the listing before writing anything and refuses
  the whole archive if any entry has an absolute path, a `..` component or control
  characters. Declared sizes must stay under 1000× the archive (at least 4 GB) and the free
  disk space minus 1 GB, with at most 200,000 entries. While extracting, the output is
  measured every 250 ms and the extractor is stopped if it grows past the limit, because
  headers can lie. libarchive's own guards stay on (no `-P`, never extracts through a
  symlink); ownership, permissions bits, ACLs and file flags from the archive are dropped.
  Afterwards, links that resolve outside the folder and special files are deleted, and a
  downloaded archive's quarantine flag is copied to every extracted file. Everything happens
  in the private workspace and is moved into place only when it succeeded. Tests cover
  path traversal, absolute paths and an expanding archive.
- Watch folders write only to their results subfolder and scan only the top level, so their
  own output is never processed again.

## Metadata

| Policy | Images | Video/audio |
|---|---|---|
| Keep | Everything | `-map_metadata 0` |
| Remove location & serials (default) | GPS, body/lens serials, owner, user comment, artist, maker notes, XMP in PNG | location tags cleared |
| Remove all | Everything except colour profile and orientation | `-map_metadata -1`, chapters dropped |

"Remove Metadata" on JPEG and PNG is lossless: the compressed image data is copied unchanged.

## Permissions

- **Global mouse monitoring** (clover on drag) needs no permission. Global key monitoring for
  Tab-to-flip during a drag only works if the user grants Accessibility; nothing else depends on it.
- **Automation (Finder)**: asked once, the first time ⌥⌘D reads the Finder selection.
- **Services**: "Convert with Dropster" receives file URLs only.
- **Open at login** uses `SMAppService`.

## Not yet sandboxed

The app currently runs unsandboxed because it executes FFmpeg/cwebp from Homebrew. The plan
for a sandboxed, notarised build is to bundle signed, pinned copies of those tools in
`Contents/Resources/bin` (already searched first by `ToolLocator`) and use security-scoped
bookmarks for output folders.
