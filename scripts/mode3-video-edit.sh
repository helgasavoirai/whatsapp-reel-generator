#!/usr/bin/env bash
#
# mode3-video-edit.sh
#
# Standalone reference implementation of MODE 3 (trader-submitted video,
# color-graded + text overlay) from server.js. Mirrors the Node render
# logic exactly -- same per-language font tuning, same eq color-grade
# filter, same silent-video detection / audio-mix logic, same duration
# capping, same CRF size-fallback strategy. Reference/report artifact;
# production render path is still server.js.
#
# USAGE:
#   ./mode3-video-edit.sh \
#     --media ./input/trader-clip.mp4 \
#     --product-name "પ્રીમિયમ સિલિકોન કિચન વાસણ સેટ" \
#     --price "₹1009" \
#     --tagline "તમારા રસોડાને એક આધુનિક લુક આપશે" \
#     --language gujarati \
#     --music ../music/upbeat.mp3 \
#     --output ./output/mode3-reel.mp4
#
# --media is a local video file path (this script does not handle
# Twilio-authenticated downloads -- pre-download the video first, same as
# server.js's downloadFile() step does before this stage runs). Requires
# ffprobe (ships alongside ffmpeg).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FONTS_DIR="$SCRIPT_DIR/../fonts"

MODE3_MAX_DURATION=13
FRAME_WIDTH=1080
FFMPEG_THREADS=2
MAX_FILE_SIZE_MB=16

MEDIA=""
MUSIC=""
PRODUCT_NAME=""
PRICE=""
TAGLINE=""
LANGUAGE="english"
OUTPUT="./output/mode3-reel.mp4"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --media) MEDIA="$2"; shift 2 ;;
    --music) MUSIC="$2"; shift 2 ;;
    --product-name) PRODUCT_NAME="$2"; shift 2 ;;
    --price) PRICE="$2"; shift 2 ;;
    --tagline) TAGLINE="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$MEDIA" ]]; then
  echo "ERROR: --media is required" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Per-language styling -- same values as LANGUAGE_TEXT_STYLE in server.js.
# ---------------------------------------------------------------------------
lang_lc="$(echo "$LANGUAGE" | tr '[:upper:]' '[:lower:]')"
case "$lang_lc" in
  *hindi*)
    CHAR_WIDTH_RATIO=0.68; SAFE_WIDTH_RATIO=0.82; LINE_HEIGHT_MULT=1.3
    PRODUCT_SCALE=0.95; PRICE_SCALE=1.0; TAGLINE_SCALE=1.0
    FONT_REGULAR="$FONTS_DIR/NotoSansDevanagari-Regular.ttf"
    FONT_BOLD="$FONTS_DIR/NotoSansDevanagari-Bold.ttf"
    ;;
  *gujarati*)
    CHAR_WIDTH_RATIO=0.68; SAFE_WIDTH_RATIO=0.82; LINE_HEIGHT_MULT=1.3
    PRODUCT_SCALE=0.95; PRICE_SCALE=1.0; TAGLINE_SCALE=1.0
    FONT_REGULAR="$FONTS_DIR/NotoSansGujarati-Regular.ttf"
    FONT_BOLD="$FONTS_DIR/NotoSansGujarati-Bold.ttf"
    ;;
  *english*)
    CHAR_WIDTH_RATIO=0.55; SAFE_WIDTH_RATIO=0.86; LINE_HEIGHT_MULT=1.15
    PRODUCT_SCALE=1.0; PRICE_SCALE=1.0; TAGLINE_SCALE=0.9
    FONT_REGULAR="$FONTS_DIR/NotoSans-Regular.ttf"
    FONT_BOLD="$FONTS_DIR/NotoSans-Bold.ttf"
    ;;
  *)
    CHAR_WIDTH_RATIO=0.6; SAFE_WIDTH_RATIO=0.84; LINE_HEIGHT_MULT=1.2
    PRODUCT_SCALE=1.0; PRICE_SCALE=1.0; TAGLINE_SCALE=1.0
    FONT_REGULAR="$FONTS_DIR/NotoSans-Regular.ttf"
    FONT_BOLD="$FONTS_DIR/NotoSans-Bold.ttf"
    ;;
esac

[[ -f "$FONT_BOLD" ]] || FONT_BOLD="$FONT_REGULAR"

BASE_PRODUCT_FONTSIZE=60
BASE_PRICE_FONTSIZE=80
BASE_TAGLINE_FONTSIZE=46

PRODUCT_FONTSIZE=$(awk -v b="$BASE_PRODUCT_FONTSIZE" -v s="$PRODUCT_SCALE" 'BEGIN{printf "%d", b*s}')
PRICE_FONTSIZE=$(awk -v b="$BASE_PRICE_FONTSIZE" -v s="$PRICE_SCALE" 'BEGIN{printf "%d", b*s}')
TAGLINE_FONTSIZE=$(awk -v b="$BASE_TAGLINE_FONTSIZE" -v s="$TAGLINE_SCALE" 'BEGIN{printf "%d", b*s}')

max_chars_for_fontsize() {
  local fontsize="$1"
  awk -v w="$FRAME_WIDTH" -v safe="$SAFE_WIDTH_RATIO" -v fs="$fontsize" -v ratio="$CHAR_WIDTH_RATIO" \
    'BEGIN{v=int((w*safe)/(fs*ratio)); if(v<4) v=4; print v}'
}

wrap_text() {
  local text="$1"
  local max_chars="$2"
  awk -v max="$max_chars" '
    {
      n = split($0, words, " ")
      line = ""; nlines = 0
      for (i = 1; i <= n; i++) {
        candidate = (line == "") ? words[i] : line " " words[i]
        if (length(candidate) > max && line != "") {
          lines[nlines++] = line
          line = words[i]
        } else {
          line = candidate
        }
      }
      if (line != "") lines[nlines++] = line
      if (nlines > 2) {
        merged = lines[1]
        for (j = 2; j < nlines; j++) merged = merged " " lines[j]
        print lines[0]; print merged
      } else {
        for (j = 0; j < nlines; j++) print lines[j]
      }
    }' <<< "$text"
}

escape_path() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

write_text_lines() {
  local base="$1"; shift
  local -a lines=("$@")
  local i=0
  local out=""
  for line in "${lines[@]}"; do
    local f="${base}_l${i}.txt"
    printf '%s' "$line" > "$f"
    out+="$(escape_path "$f")"$'\n'
    i=$((i + 1))
  done
  printf '%s' "$out"
}

mapfile -t PRODUCT_LINES < <(wrap_text "$PRODUCT_NAME" "$(max_chars_for_fontsize "$PRODUCT_FONTSIZE")")
mapfile -t PRICE_LINES < <(wrap_text "$PRICE" "$(max_chars_for_fontsize "$PRICE_FONTSIZE")")
mapfile -t TAGLINE_LINES < <(wrap_text "$TAGLINE" "$(max_chars_for_fontsize "$TAGLINE_FONTSIZE")")

mapfile -t PRODUCT_LINE_PATHS < <(write_text_lines "$WORKDIR/product_name" "${PRODUCT_LINES[@]}")
mapfile -t PRICE_LINE_PATHS < <(write_text_lines "$WORKDIR/price" "${PRICE_LINES[@]}")
mapfile -t TAGLINE_LINE_PATHS < <(write_text_lines "$WORKDIR/tagline" "${TAGLINE_LINES[@]}")

animated_text_filter() {
  local textfile="$1" fontfile="$2" color="$3" fontsize="$4" y_final_expr="$5" appear_at="$6" anim_dur="$7" slide_dist="$8"
  local y_expr="(${y_final_expr})+${slide_dist}*(1-min(max((t-${appear_at})/${anim_dur}\,0)\,1))"
  local alpha_expr="if(lt(t\,${appear_at})\,0\,min((t-${appear_at})/${anim_dur}\,1))"
  echo "drawtext=fontfile='${fontfile}':textfile='${textfile}':fontcolor=${color}:fontsize=${fontsize}:x=(w-text_w)/2:y='${y_expr}':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='${alpha_expr}'"
}

multiline_text_filter() {
  local fontfile="$1" color="$2" fontsize="$3" y_center_expr="$4" appear_at="$5" anim_dur="$6" slide_dist="$7" line_height_mult="$8"; shift 8
  local -a line_paths=("$@")
  local n="${#line_paths[@]}"
  local line_height
  line_height=$(awk -v fs="$fontsize" -v m="$line_height_mult" 'BEGIN{print fs*m}')
  local parts=()
  for ((i = 0; i < n; i++)); do
    local offset
    offset=$(awk -v i="$i" -v n="$n" -v lh="$line_height" 'BEGIN{print (i-(n-1)/2)*lh}')
    local y_expr="(${y_center_expr})+(${offset})"
    parts+=("$(animated_text_filter "${line_paths[$i]}" "$fontfile" "$color" "$fontsize" "$y_expr" "$appear_at" "$anim_dur" "$slide_dist")")
  done
  local IFS=,
  echo "${parts[*]}"
}

build_text_overlay() {
  local name_at="$1" price_at="$2" tagline_at="$3"
  local name_ov price_ov tagline_ov
  name_ov=$(multiline_text_filter "$FONT_BOLD" "white" "$PRODUCT_FONTSIZE" "200" "$name_at" 0.6 25 "$LINE_HEIGHT_MULT" "${PRODUCT_LINE_PATHS[@]}")
  price_ov=$(multiline_text_filter "$FONT_BOLD" "yellow" "$PRICE_FONTSIZE" "(h/2)" "$price_at" 0.6 25 "$LINE_HEIGHT_MULT" "${PRICE_LINE_PATHS[@]}")
  tagline_ov=$(multiline_text_filter "$FONT_REGULAR" "white" "$TAGLINE_FONTSIZE" "h-200" "$tagline_at" 0.6 20 "$LINE_HEIGHT_MULT" "${TAGLINE_LINE_PATHS[@]}")
  echo "${name_ov},${price_ov},${tagline_ov}"
}

# Trader video may be shorter than the 13s cap -- use its actual length in
# that case so reported duration is accurate and text/audio timing stays
# sane for very short clips (same as server.js's ffprobe duration check).
PROBED_DURATION="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$MEDIA" 2>/dev/null || echo "")"
MODE3_DURATION="$MODE3_MAX_DURATION"
if [[ -n "$PROBED_DURATION" ]] && awk -v d="$PROBED_DURATION" -v cap="$MODE3_MAX_DURATION" 'BEGIN{exit !(d<cap)}'; then
  MODE3_DURATION="$PROBED_DURATION"
fi
echo "Mode 3 duration: ${MODE3_DURATION}s"

# WhatsApp/Twilio videos are sometimes silent (no audio stream at all --
# a known WhatsApp quirk). Referencing [0:a] when there's no audio stream
# crashes ffmpeg outright, so probe first and fall back to music-only when
# silent (same as server.js).
AUDIO_PROBE="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$MEDIA" 2>/dev/null || echo "")"
if [[ -n "$AUDIO_PROBE" ]]; then
  VIDEO_HAS_AUDIO=1
else
  VIDEO_HAS_AUDIO=0
fi
echo "Mode 3: video has audio track = ${VIDEO_HAS_AUDIO}"

# Timing for a 13s-normalized layout, scaled to the actual output duration
# (name@2s, price@6s, tagline@10s at the 13s cap).
NAME_AT=$(awk -v d="$MODE3_DURATION" -v cap="$MODE3_MAX_DURATION" 'BEGIN{printf "%.2f", 2*d/cap}')
PRICE_AT=$(awk -v d="$MODE3_DURATION" -v cap="$MODE3_MAX_DURATION" 'BEGIN{printf "%.2f", 6*d/cap}')
TAGLINE_AT=$(awk -v d="$MODE3_DURATION" -v cap="$MODE3_MAX_DURATION" 'BEGIN{printf "%.2f", 10*d/cap}')

TEXT_OVERLAY="$(build_text_overlay "$NAME_AT" "$PRICE_AT" "$TAGLINE_AT")"

# Per spec: saturation 1.3, contrast 1.1, brightness 0.05.
VIDEO_FILTER="[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,eq=saturation=1.3:contrast=1.1:brightness=0.05,${TEXT_OVERLAY}[v]"

INPUT_ARGS=(-y -i "$MEDIA")
[[ -n "$MUSIC" ]] && INPUT_ARGS+=(-i "$MUSIC")

if [[ -n "$MUSIC" && "$VIDEO_HAS_AUDIO" -eq 1 ]]; then
  # Original video audio at 30%, music at 70%, mixed together.
  FADE_OUT_START=$(awk -v d="$MODE3_DURATION" 'BEGIN{v=d-1; if(v<0) v=0; printf "%.2f", v}')
  FILTER_COMPLEX="${VIDEO_FILTER};[0:a]volume=0.3[a0];[1:a]volume=0.7,afade=t=in:st=0:d=1,afade=t=out:st=${FADE_OUT_START}:d=1[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[a]"
elif [[ -n "$MUSIC" && "$VIDEO_HAS_AUDIO" -eq 0 ]]; then
  # Silent video: just use the (faded) music track.
  FADE_OUT_START=$(awk -v d="$MODE3_DURATION" 'BEGIN{v=d-1; if(v<0) v=0; printf "%.2f", v}')
  FILTER_COMPLEX="${VIDEO_FILTER};[1:a]afade=t=in:st=0:d=1,afade=t=out:st=${FADE_OUT_START}:d=1[a]"
else
  FILTER_COMPLEX="$VIDEO_FILTER"
fi

for CRF in 23 26 28 32; do
  ARGS=("${INPUT_ARGS[@]}" -filter_complex "$FILTER_COMPLEX" -map "[v]")
  OUT_ARGS=(-t "$MODE3_DURATION" -c:v libx264 -preset fast -crf "$CRF" -threads "$FFMPEG_THREADS" -pix_fmt yuv420p)
  if [[ -n "$MUSIC" ]]; then
    ARGS+=(-map "[a]")
    OUT_ARGS+=(-c:a aac -b:a 128k)
  fi
  echo "Rendering mode 3 at CRF ${CRF}..."
  ffmpeg "${ARGS[@]}" "${OUT_ARGS[@]}" "$OUTPUT"

  SIZE_MB=$(awk -v b="$(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT")" 'BEGIN{printf "%.2f", b/1024/1024}')
  echo "Output size: ${SIZE_MB}MB"
  if awk -v s="$SIZE_MB" -v max="$MAX_FILE_SIZE_MB" 'BEGIN{exit !(s>0 && s<=max)}'; then
    echo "Mode 3 render complete: $OUTPUT (${SIZE_MB}MB, CRF ${CRF})"
    exit 0
  fi
done

echo "ERROR: could not get output under ${MAX_FILE_SIZE_MB}MB at any CRF level" >&2
exit 1
