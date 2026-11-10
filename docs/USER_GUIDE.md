# Using Dropster

## The clover

Start dragging files in Finder, Photos or a web browser and hold **⌥ Option**. A clover opens
under your cursor showing only what fits those files.

- **Drop on a leaf** to run its main action (for images: Optimize, WebP, HEIC, your first preset).
- **Rest on a leaf** for a moment and its choices fan out; drop on one.
- **Drop on the centre** to give every file its suggested action.
- **Rest on the centre, press Tab or scroll** to turn the clover over to the tools: Crop,
  Rotate & Flip, Colour (grayscale, remove background) and Combine (one PDF, one ZIP).

A ring at the cursor shows progress and how much space was saved; click it to see the files.
Results are saved next to the originals. Pictures dragged from a web page are downloaded into
Downloads first, with the speed shown on the ring.

You don't need to open Dropster first: it starts at login in the background (menu bar only)
and the dial is always ready. Opening Dropster from Finder or Launchpad shows its window; closing
the window puts it back in the menu bar. Turn this off with **Settings › General › Open at login**.

Other ways to open it: **⌥⌘D** (Finder selection, or whatever is on the clipboard, in which
case the result is copied back), Finder's right-click **Services › Convert with Dropster**, and
**Convert Clipboard…** in the menu bar. Change the key or turn it off in **Settings › Clover**.

## Crop

Choose **Crop** on the back of the clover, or **Edit › Crop…** on selected files. Drag to draw
or move the frame, drag the handles to resize. Press **A** for the aspect dial (or 1–7), **X**
to swap portrait and landscape. **Crop & Next** (↩) saves and moves on; **Crop All Remaining**
applies the same frame to the rest.

## Presets

**Settings › Presets** holds named actions per kind of file, for example *Web 1920 · WebP*,
*720p · MP4*, *Frames · 1 per second*, *MP3 · 320 kb/s* or *Pages · PNG 150 dpi*. Each can set
quality, size, DPI, TIFF compression, ICO sizes, video height and codec, hardware encoding,
MP3 bitrate, output folder, file names and whether to keep the original dates. Presets appear
on the clover's Presets leaf and in each file's **Presets** menu.

## Fit under a size

For an upload form or an email attachment limit, choose **Fit Under** in a file's action menu
(1, 5, 10, 25 MB or **Other Size…**), or the **Fit Size** leaf on the back of the clover.

- **Images** keep their format if it is JPEG, HEIC, AVIF or WebP; others become JPEG. Dropster
  searches for the highest quality that fits, and only scales the image down when even
  reasonable quality is too big. The Inspector shows the new dimensions if it did.
- **Video** becomes H.264 MP4, which plays everywhere, encoded in two passes at the exact
  bitrate the limit allows. If that bitrate can't carry the full resolution, Dropster picks a
  smaller one (and caps 60 fps to 30 first).
- **Audio** keeps MP3, AAC or Opus; lossless audio becomes AAC.

A file that is already under the limit is left alone ("Already fits"). If a limit is too small
to be watchable, for example 1 MB for ten minutes of video, Dropster says so instead of
producing mush.

## Archives

Select an archive to see its contents in the Inspector without unpacking it. **Unpack** (the
default action for archives, or the clover's Unpack leaf) extracts ZIP, 7-Zip, Tar and
compressed tars, and single compressed files (`.gz`, `.xz`, `.zst`, `.br`). An archive holding
one folder unpacks as that folder, like Archive Utility. Archives with entries that try to
write outside their folder, or that expand to an unreasonable size, are refused.

## Watch folders

**Settings › Watch › Add Folder…** picks a folder and an action (any action or preset). From
then on every new file in it is processed into a `Dropster` subfolder (you can rename it).

- Files already in the folder are left alone. Files that arrive while Dropster is closed are
  processed at the next launch.
- Downloads and copies are processed only once they have stopped growing; browser partial
  files (`.crdownload`, `.download`, `.part`) are ignored until they are renamed.
- Files the action doesn't apply to are skipped quietly.
- The menu bar menu shows which folders are being watched. Use the switch to pause a folder.

## Process files

Drop files or folders on the window, on the Dock icon, or choose **File › Add Files…** (⌘O).
Each file is analysed and, by default, processed straight away with its suggested action:

| File | Default action |
|---|---|
| JPEG, PNG, HEIC, AVIF, WebP, TIFF | Optimize |
| BMP, TIFF, PSD | Convert to PNG (lossless) |
| WAV, AIFF | Convert to FLAC (lossless) |
| Camera RAW | Convert to HEIC |
| ZIP, 7-Zip, Tar, .gz, .xz, .zst | Unpack |
| Animated GIF | Convert to MP4 |
| Video | Optimize (re-encode to HEVC) |
| Anything else | Compress with Zstandard |

To choose a different action, click the action next to a file (or right-click several
selected files) and pick **Optimize**, **Remove Metadata**, a format under **Convert To**, an
**Edit** (crop, rotate, flip, grayscale, remove background), **Pages**/**Frames** (PDF pages or
video frames as pictures, one long image, split, extract a page range) or a **Preset**. Only
actions this Mac can perform are listed. **Queue › Merge Selected into One PDF** and **Pack
Selected into One ZIP** combine files.

Results are saved next to the original as `name-min.ext` (optimize), `name-clean.ext`
(metadata removal) or `name.newext` (conversion). Originals are never changed.

## Modes

- **Balanced**: aims for results you can't tell from the original (SSIM ≈0.97 on photos).
- **Smallest**: smaller files with slight, usually invisible losses (≈0.95), more encoder effort.
- **Fastest**: hardware encoders and less effort; files are larger.

## Reading results

- `694 KB → 405 KB −42%`: the new file and how much smaller it is.
- **Already optimal**: Dropster's result was not smaller, so it kept the original and wrote nothing.
- The inspector shows the measured **Quality** for lossy images: *Visually identical*
  (SSIM ≥ 0.99), *Excellent* (≥ 0.97), *Good* (≥ 0.95) or *Visible differences*.
- **Compare…** opens a before/after view. Use **Actual Size** to inspect pixels 1:1.

## Settings (⌘,)

- Save results next to the original or in a chosen folder
- Start automatically, include subfolders
- Resize images to a maximum edge
- Discard conversions that are larger than the original
- Metadata: keep all, remove location & serials (default), or remove all
- **Engines** shows which optional tools were found and how to install missing ones

## Queue

Pause (⌥⌘P) lets running files finish and holds the rest. Cancel a file with its ✕ button or
everything with ⌘.; a cancelled file leaves nothing behind. Failed files can be run again from
the context menu. **Window › History** (⇧⌘Y) lists past work and total space saved.
