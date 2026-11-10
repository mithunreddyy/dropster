#!/bin/bash
# End-to-end check of Dropster: every CLI operation on generated fixtures, each output checked
# with an independent tool, then the clover driven through the real app (scripts/build-app.sh first).
#
#   ./scripts/e2e.sh            CLI + clover
#   ./scripts/e2e.sh --cli      CLI only
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=.build/release/dropster-cli
APP=build/Dropster.app/Contents/MacOS/Dropster
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dropster-e2e.XXXXXX")"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  - %s (skipped: %s)\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

swift build -c release --product dropster-cli >/dev/null || { echo "build failed"; exit 1; }
echo "Fixtures in $WORK"
F="$WORK/in"; mkdir -p "$F"

# ---- Fixtures -------------------------------------------------------------------------------
if have ffmpeg; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=1600x900 -frames:v 1 -q:v 2 "$F/photo.jpg"
  ffmpeg -hide_banner -loglevel error -f lavfi -i "mandelbrot=size=800x600" -frames:v 1 "$F/art.png"
  ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25 -f lavfi -i "sine=frequency=440" \
    -t 3 -c:v libx264 -crf 18 -c:a aac -shortest "$F/clip.mp4"
  ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=330:duration=3" -ar 44100 "$F/tone.wav"
else
  sips -s format jpeg /System/Library/Desktop\ Pictures/*.heic --out "$F/photo.jpg" >/dev/null 2>&1
fi
printf '1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n' > "$F/subs.srt"
printf '# Notes\n\nSome **bold** text.\n' > "$F/notes.md"
textutil -convert docx -output "$F/memo.docx" "$F/notes.md"
seq 1 100000 > "$F/server.log"

# ---- Helpers --------------------------------------------------------------------------------
# run <label> <expected output path> <check> -- <cli args…>
run() {
  local label="$1" out="$2" check="$3"; shift 4
  rm -rf "$out"
  if ! "$CLI" "$@" >"$WORK/last.log" 2>&1; then bad "$label: $(tail -1 "$WORK/last.log")"; return; fi
  if [ ! -e "$out" ]; then bad "$label: no output at $(basename "$out")"; return; fi
  if eval "$check" >/dev/null 2>&1; then ok "$label"; else bad "$label: output failed check ($check)"; fi
}
isa()   { file -b "$1" | grep -qi "$2"; }
img()   { [ "$(sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ {print $2}')" -gt 0 ]; }
media() { [ "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" | cut -d. -f1)" -ge 0 ] 2>/dev/null; }
vcodec(){ [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$1")" = "$2" ]; }
height(){ [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$1")" = "$2" ]; }
pages() { [ "$(mdls -raw -name kMDItemNumberOfPages "$1" 2>/dev/null)" = "$2" ] || python3 - "$1" "$2" <<'PY'
import sys, re
data = open(sys.argv[1], 'rb').read()
sys.exit(0 if len(re.findall(rb'/Type\s*/Page[^s]', data)) == int(sys.argv[2]) else 1)
PY
}
count() { [ "$(ls "$1" | wc -l | tr -d ' ')" -ge "$2" ]; }

echo "Images"
run "JPEG optimize"            "$F/photo-min.jpg"   'isa "$F/photo-min.jpg" JPEG'              -- optimize "$F/photo.jpg"
run "PNG optimize (lossless)"  "$F/art-min.png"     'isa "$F/art-min.png" PNG'                 -- optimize "$F/art.png"
run "JPEG → WebP"              "$F/photo.webp"      'isa "$F/photo.webp" "Web/P"'              -- convert webp "$F/photo.jpg"
run "JPEG → AVIF"              "$F/photo.avif"      'img "$F/photo.avif"'                       -- convert avif "$F/photo.jpg"
run "JPEG → HEIC"              "$F/photo.heic"      'img "$F/photo.heic"'                       -- convert heic "$F/photo.jpg"
run "PNG → TIFF 300 dpi"       "$F/art.tiff"        'sips -g dpiWidth "$F/art.tiff" | grep -q 300' -- convert tiff --dpi 300 "$F/art.png"
run "PNG → ICO"                "$F/art.ico"         'isa "$F/art.ico" icon'                    -- convert ico "$F/art.png"
run "PNG → ICNS"               "$F/art.icns"        'isa "$F/art.icns" icon'                   -- convert icns "$F/art.png"
run "PNG → SVG (trace)"        "$F/art.svg"         'xmllint --noout "$F/art.svg"'              -- convert svg "$F/art.png"
run "JPEG → PDF"               "$F/photo.pdf"       'isa "$F/photo.pdf" PDF'                    -- convert pdf "$F/photo.jpg"
run "Resize to 800"            "$F/photo-min 2.jpg" '[ "$(sips -g pixelWidth "$F/photo-min 2.jpg" | awk "/pixelWidth/ {print \$2}")" = 800 ]' -- optimize --max-size 800 "$F/photo.jpg"
run "Remove metadata"          "$F/photo-clean.jpg" 'isa "$F/photo-clean.jpg" JPEG'            -- clean "$F/photo.jpg"
# sips does not report JPEG EXIF orientation; FFmpeg's independent EXIF parser does (−90 = clockwise).
run "Rotate right (lossless)"  "$F/photo-edited.jpg" 'ffprobe -v error -show_frames -read_intervals "%+#1" "$F/photo-edited.jpg" | grep -q "rotation=-90"' -- edit rotate-right "$F/photo.jpg"
run "Fit under 100 KB"         "$F/photo-100KB.jpg" '[ "$(stat -f%z "$F/photo-100KB.jpg")" -le 100000 ] && img "$F/photo-100KB.jpg"' -- fit 100KB "$F/photo.jpg"
run "Grayscale"                "$F/art-edited.png"  'isa "$F/art-edited.png" PNG'              -- edit grayscale "$F/art.png"

if have ffmpeg; then
  echo "Video and audio"
  run "MP4 optimize (HEVC)"    "$F/clip-min.mp4"    'vcodec "$F/clip-min.mp4" hevc'             -- optimize "$F/clip.mp4"
  run "MP4 → WebM"             "$F/clip.webm"       'vcodec "$F/clip.webm" vp9'                 -- convert webm --mode fastest "$F/clip.mp4"
  run "MP4 → 240p AV1"         "$F/clip-converted.mp4" 'vcodec "$F/clip-converted.mp4" av1 && height "$F/clip-converted.mp4" 240' -- convert mp4 --height 240 --codec av1 "$F/clip.mp4"
  run "MP4 → GIF"              "$F/clip.gif"        'isa "$F/clip.gif" GIF'                     -- convert gif "$F/clip.mp4"
  run "MP4 → MP3 192k"         "$F/clip.mp3"        'media "$F/clip.mp3"'                       -- convert mp3 --mp3-bitrate 192 "$F/clip.mp4"
  run "Frames 2 fps"           "$F/clip frames"     'count "$F/clip frames" 5'                  -- pages jpeg --fps 2 "$F/clip.mp4"
  run "WAV → FLAC (bit-exact)" "$F/tone.flac"       '[ "$(ffmpeg -v error -i "$F/tone.wav" -f md5 -)" = "$(ffmpeg -v error -i "$F/tone.flac" -f md5 -)" ]' -- convert flac "$F/tone.wav"
  run "Fit video under 300 KB" "$F/clip-300KB.mp4" '[ "$(stat -f%z "$F/clip-300KB.mp4")" -le 300000 ] && vcodec "$F/clip-300KB.mp4" h264' -- fit 300KB "$F/clip.mp4"
  run "WAV → Opus"             "$F/tone.opus"       'media "$F/tone.opus"'                      -- convert opus "$F/tone.wav"
else
  skip "Video and audio" "ffmpeg not installed"
fi

echo "Documents, PDF, subtitles"
run "Markdown → Word"          "$F/notes.docx"      'isa "$F/notes.docx" "Word\|Zip\|OOXML"'  -- convert docx "$F/notes.md"
run "Word → PDF"               "$F/memo.pdf"        'isa "$F/memo.pdf" PDF'                    -- convert pdf "$F/memo.docx"
run "Word → ODT"               "$F/memo.odt"        'unzip -tq "$F/memo.odt"'                  -- convert odt "$F/memo.docx"
run "Merge into PDF"           "$F/Combined.pdf"    'pages "$F/Combined.pdf" 3'                -- merge "$F/photo.jpg" "$F/art.png" "$F/memo.pdf"
run "PDF pages → PNG"          "$F/Combined pages"  'count "$F/Combined pages" 3'              -- pages png --dpi 72 "$F/Combined.pdf"
run "PDF one long image"       "$F/Combined-long.jpg" 'img "$F/Combined-long.jpg"'             -- long jpeg --dpi 72 "$F/Combined.pdf"
run "PDF extract 2-3"          "$F/Combined-extract.pdf" 'pages "$F/Combined-extract.pdf" 2'   -- extract "2-3" "$F/Combined.pdf"
run "PDF optimize"             "$F/Combined-min.pdf" 'isa "$F/Combined-min.pdf" PDF'           -- optimize "$F/Combined.pdf"
run "PDF → text"               "$F/memo.txt"        'grep -q bold "$F/memo.txt"'               -- convert txt "$F/memo.pdf"
run "SRT → VTT"                "$F/subs.vtt"        'head -1 "$F/subs.vtt" | grep -q WEBVTT'   -- convert vtt "$F/subs.srt"
run "SRT → ASS"                "$F/subs.ass"        'grep -q "Script Info" "$F/subs.ass"'      -- convert ass "$F/subs.srt"

echo "Archives"
run "Log → Zstandard"          "$F/server.log.zst"  'zstd -tq "$F/server.log.zst"'             -- convert zst "$F/server.log"
run "Log → XZ"                 "$F/server.log.xz"   'xz -t "$F/server.log.xz"'                 -- convert xz "$F/server.log"
run "Pack into ZIP"            "$F/Combined.zip"    'unzip -tq "$F/Combined.zip"'              -- zip "$F/server.log" "$F/subs.srt"
run "Unpack ZIP"               "$F/Combined"        'cmp "$F/Combined/server.log" "$F/server.log"' -- unpack "$F/Combined.zip"
run "Unpack .zst stream"       "$F/server 2.log"    'cmp "$F/server 2.log" "$F/server.log"'   -- unpack "$F/server.log.zst"

echo "Safety"
before=$(shasum "$F/photo.jpg" "$F/art.png" "$F/clip.mp4" 2>/dev/null)
"$CLI" optimize "$F/photo.jpg" "$F/art.png" >/dev/null 2>&1
after=$(shasum "$F/photo.jpg" "$F/art.png" "$F/clip.mp4" 2>/dev/null)
[ "$before" = "$after" ] && ok "Originals untouched after repeated runs" || bad "An original changed"
printf '\x89PNG\r\n\x1a\nbroken' > "$F/broken.png"
if "$CLI" optimize "$F/broken.png" >/dev/null 2>&1; then bad "Corrupt PNG was accepted"; else ok "Corrupt PNG rejected"; fi
[ ! -e "$F/broken-min.png" ] && ok "No output left for a failed job" || bad "Partial output left behind"
mkdir -p "$F/slip/deep"
python3 -I -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('../../slipped.txt','x'); z.close()" "$F/slip/deep/evil.zip"
if "$CLI" unpack "$F/slip/deep/evil.zip" >/dev/null 2>&1; then bad "Path-traversal archive was unpacked"; else ok "Path-traversal archive refused"; fi
[ ! -e "$F/slipped.txt" ] && [ ! -e "$F/slip/slipped.txt" ] && ok "Nothing written outside the archive's folder" || bad "An entry escaped"

if [ "${1:-}" != "--cli" ]; then
  echo "Clover (real app, synthetic pointer)"
  if [ ! -x "$APP" ]; then
    skip "Clover" "build the app first with scripts/build-app.sh"
  else
    C="$WORK/clover"; mkdir -p "$C"
    cp "$F/photo.jpg" "$C/a.jpg"; cp "$F/art.png" "$C/b.png"; cp "$F/memo.docx" "$C/m.docx"; cp "$F/Combined.pdf" "$C/r.pdf"
    [ -e "$F/clip.mp4" ] && cp "$F/clip.mp4" "$C/v.mp4"; [ -e "$F/tone.wav" ] && cp "$F/tone.wav" "$C/t.wav"
    clover() { # label, args…
      local label="$1"; shift
      if "$APP" --self-test-clover "$@" >"$WORK/clover.log" 2>&1; then ok "$label"; else bad "$label: $(grep -v sandbox_extension "$WORK/clover.log" | tail -1)"; fi
    }
    if "$APP" --self-test-dock >"$WORK/dock.log" 2>&1; then ok "Closing the window leaves the dial running, no Dock icon"
    else bad "Dock presence: $(grep dock "$WORK/dock.log")"; fi
    clover "Drag → Optimize leaf"            drag 0 0 "$C/a.jpg"
    clover "Drag → Web › WEBP leaflet"        drag 1 0 "$C/a.jpg" "$C/b.png"
    clover "Click → Formats › HEIC leaflet"   click 2 0 "$C/a.jpg"
    clover "Drag → Presets leaf"              drag 3 0 "$C/b.png"
    clover "Back › Rotate › Left"             drag 1 1 --back "$C/a.jpg"
    clover "Back › Colour › Grayscale"        click 2 0 --back "$C/b.png"
    clover "Back › Combine › Merge PDF"       drag 3 0 --back "$C/a.jpg" "$C/b.png"
    clover "Back › Combine › ZIP"             drag 3 1 --back "$C/a.jpg" "$C/b.png"
    clover "Back › Fit Size › 1MB"         drag 0 0 --back "$C/a.jpg"
    cp "$F/Combined.zip" "$C/z.zip"
    clover "Archive › Unpack"              drag 0 0 "$C/z.zip"
    clover "PDF › Pictures › PNG"             drag 1 0 "$C/r.pdf"
    clover "Word › PDF"                       drag 0 0 "$C/m.docx"
    if [ -e "$C/v.mp4" ]; then
      clover "Video › Audio › MP3"            drag 2 0 "$C/v.mp4"
      clover "Audio › Lossless › FLAC"        drag 2 0 "$C/t.wav"
    fi
  fi
fi

echo
echo "Passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" -eq 0 ] && rm -rf "$WORK"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
