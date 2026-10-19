#!/bin/bash
# Converts every sample to every offered target with the headless CLI and checks the outputs.
# Usage: ./test.sh   (after ./build.sh; creates samples/ and test-out/)
set -uo pipefail
cd "$(dirname "$0")"
B=build.noindex/Swivel.app/Contents/MacOS/Swivel
FF=/opt/homebrew/bin/ffmpeg; FP=/opt/homebrew/bin/ffprobe
fail=0
rm -rf test-out; mkdir test-out; cd test-out

# Samples: transparent PNG (odd size), HEIC, short video with audio, WAV, 3-page PDF.
$FF -loglevel error -f lavfi -i "color=c=black@0:s=401x301,format=rgba" \
  -vf "geq=r=255:g=60:b=0:a='if(lt(hypot(X-200,Y-150),120),255,0)'" -frames:v 1 photo.png
sips -s format heic photo.png --out shot.heic >/dev/null
$FF -loglevel error -f lavfi -i testsrc2=s=641x361:r=30:d=3 -f lavfi -i sine=f=440:d=3 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest clip.mov
$FF -loglevel error -f lavfi -i "sine=f=330:d=3" -ac 2 tone.wav
for p in one two three; do echo "This is page $p" > p.txt; /usr/sbin/cupsfilter p.txt > $p.pdf 2>/dev/null; done
"../$B" --convert one.pdf two.pdf three.pdf merge >/dev/null && mv "one merged.pdf" doc.pdf
rm -f p.txt two.pdf three.pdf
before=$(md5 -q photo.png)

check() { # file, description of what must be true
  local f="$1"
  if [ ! -e "$f" ]; then echo "FAIL missing $f"; fail=1; return; fi
  case "$f" in
    *.jpg|*.png|*.heic|*.tiff|*.bmp|*.gif) sips -g pixelWidth "$f" 2>/dev/null | grep -q pixelWidth || { echo "FAIL unreadable $f"; fail=1; return; } ;;
    *.pdf) [ "$(head -c 4 "$f")" = "%PDF" ] || { echo "FAIL not a pdf $f"; fail=1; return; } ;;
  esac
  case "$f" in
    *.webp|*.avif|*.mp3|*.m4a|*.wav|*.flac|*.ogg|*.opus|*.aiff|*.mp4|*.mov|*.mkv|*.webm|*.gif)
      $FF -v error -i "$f" -f null - 2>&1 | grep -q . && { echo "FAIL decode errors $f"; fail=1; return; } ;;
  esac
  echo "ok   ${f#$PWD/}"
}

conv() { # file target -> prints output path
  out=$("../$B" --convert "$@" 2>&1) || { echo "FAIL $* : $out"; fail=1; return 1; }
  echo "$out"
}

for src in photo.png shot.heic clip.mov tone.wav doc.pdf; do
  for t in $("../$B" --targets "$src"); do
    out=$(conv "$src" "$t") || continue
    if [ -d "$out" ]; then for f in "$out"/*; do check "$f"; done; else check "$out"; fi
  done
done

echo "--- specific checks"
[ "$(sips -g hasAlpha photo.jpg | awk '/hasAlpha/{print $2}')" = "no" ] && echo "ok   jpg has no alpha" || { echo "FAIL jpg alpha"; fail=1; }
# corner pixel of the flattened JPG must be white, not black
corner=$($FF -v error -i photo.jpg -vf "crop=2:2:0:0,scale=1:1" -f rawvideo -pix_fmt rgb24 - | xxd -p)
[ "$corner" = "ffffff" ] && echo "ok   jpg flattened on white" || { echo "FAIL jpg corner=$corner"; fail=1; }
[ "$(sips -g hasAlpha photo.webp 2>/dev/null | awk '/hasAlpha/{print $2}')" = "yes" ] && echo "ok   webp keeps alpha" || echo "note webp alpha not kept"
w=$(sips -g pixelWidth "doc pages/doc page 1.png" | awk '/pixelWidth/{print $2}')
[ "$w" -ge 2400 ] && echo "ok   pdf page rendered at 300dpi (width $w)" || { echo "FAIL dpi width $w"; fail=1; }
[ "$(ls "doc pages" | grep -c '\.png$')" = 3 ] && echo "ok   3 png pages" || { echo "FAIL page count"; fail=1; }
[ "$(ls "doc pages 3" 2>/dev/null | grep -c '\.pdf$')" = 3 ] && echo "ok   split into 3 pdfs" || { ls; echo "FAIL split"; fail=1; }
grep -q "page three" doc.txt && echo "ok   txt has text" || { echo "FAIL txt"; fail=1; }
gw=$($FP -v error -select_streams v:0 -show_entries stream=width,r_frame_rate -of csv=p=0 clip.gif)
echo "     gif: $gw (want width<=720, 15/1)"
$FP -v error -show_entries stream=codec_name -of csv=p=0 clip.mp3 | grep -q mp3 && echo "ok   mp3 extracted from video" || { echo "FAIL mp3"; fail=1; }
out=$(conv photo.png jpg); [ "$out" = "$PWD/photo 2.jpg" ] && echo "ok   unique name: photo 2.jpg" || { echo "FAIL naming $out"; fail=1; }
[ "$(md5 -q photo.png)" = "$before" ] && echo "ok   original untouched" || { echo "FAIL original changed"; fail=1; }
for pair in "clip.mp4 mov" "tone.flac wav"; do out=$(conv $pair) && check "$out"; done
$FP -v error -show_entries stream=pix_fmt -of csv=p=0 photo.avif | grep -q yuv420p && echo "ok   avif is yuv420p" || { echo "FAIL avif pix_fmt"; fail=1; }
"../$B" --convert photo.png mp3 >/dev/null 2>&1 && { echo "FAIL bad target accepted"; fail=1; } || echo "ok   invalid target rejected"

[ $fail = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
