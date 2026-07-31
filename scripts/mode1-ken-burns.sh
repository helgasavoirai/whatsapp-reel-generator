#!/usr/bin/env bash
#
# mode1-ken-burns.sh
#
# Standalone reference implementation of MODE 1 (single photo, Ken Burns
# zoompan) from server.js. This mirrors the Node render logic exactly --
# same per-language font sizing/wrap-width/line-height tuning, same
# zoompan/fade filter, same CRF size-fallback strategy -- so it can be run
# and inspected without spinning up the Express server. Intended as a
# reference/report artifact; the production render path is still the
# Node server (server.js), not this script.
#
# USAGE:
#   ./mode1-ken-burns.sh \
#     --media ./input/photo.jpg \
#     --product-name "Premium non-stick mini frying pan slash skillet" \
#     --price "₹799" \
#     --tagline "Upgrade your daily cooking experience with compact and healthier cooking" \
#     --language english \
#     --music ../music/upbeat.mp3 \
#     --output ./output/mode1-reel.mp4
#
# --music is optional. --media accepts a local file path (this script does
# not handle Twilio-authenticated downloads -- pre-download the photo
# first, same as server.js's downloadFile() step does before this stage).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FONTS_DIR="$SCRIPT_DIR/../fonts"

TARGET_DURATION=15
FRAME_WIDTH=1080
FFMPEG_THREADS=2
MAX_FILE_SIZE_MB=16

MEDIA=""
MUSIC=""
PRODUCT_NAME=""
PRICE=""
TAGLINE=""
LANGUAGE="english"
OUTPUT="./output/mode1-reel.mp4"

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
# charWidthRatio: avg glyph width as a fraction of fontSize (Devanagari/
#   Gujarati run wider than Latin due to conjuncts/matras).
# safeWidthRatio: how much of FRAME_WIDTH is usable for text (rest = margin).
# lineHeightMultiplier: vertical spacing between wrapped lines.
# product/price/tagline scale: per-element fontSize multiplier.
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

# Fall back to Regular weight if the Bold file hasn't been uploaded yet
# (same behavior as boldFontForLanguage() in server.js).
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

# Word-wraps text to at most 2 lines (overflow beyond line 2 gets merged
# into line 2), same rule as wrapText() in server.js. Prints one line per
# output line.
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

# Writes each wrapped line to its own textfile and returns the escaped
# paths (newline-separated). Each line gets rendered as its own drawtext
# call later so it can be centered independently -- a single multi-line
# drawtext would compute text_w once from the widest line, making shorter
# lines render left-shifted instead of centered.
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

# One drawtext filter for a single line, animated (fade + slight slide)
# into its resting position starting at appear_at. y_final_expr is a raw
# ffmpeg expression for the resting y. x=(w-text_w)/2 centers THIS line on
# its own width.
animated_text_filter() {
  local textfile="$1" fontfile="$2" color="$3" fontsize="$4" y_final_expr="$5" appear_at="$6" anim_dur="$7" slide_dist="$8"
  local y_expr="(${y_final_expr})+${slide_dist}*(1-min(max((t-${appear_at})/${anim_dur}\,0)\,1))"
  local alpha_expr="if(lt(t\,${appear_at})\,0\,min((t-${appear_at})/${anim_dur}\,1))"
  echo "drawtext=fontfile='${fontfile}':textfile='${textfile}':fontcolor=${color}:fontsize=${fontsize}:x=(w-text_w)/2:y='${y_expr}':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='${alpha_expr}'"
}

# Builds one drawtext filter PER LINE (comma-joined), stacked vertically
# around y_center_expr using line_height_mult (language-specific), so a
# 1-2 line block reads as one cohesive, independently-centered element.
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

# Same layout as buildTextOverlay() in server.js: product name near top
# (bold, white), price centered mid-frame (bold, yellow, largest), tagline
# near bottom (regular, white). Mode 1 timing: name@2s, price@5s, tagline@8s.
build_text_overlay() {
  local name_at="$1" price_at="$2" tagline_at="$3"
  local name_ov price_ov tagline_ov
  name_ov=$(multiline_text_filter "$FONT_BOLD" "white" "$PRODUCT_FONTSIZE" "200" "$name_at" 0.6 25 "$LINE_HEIGHT_MULT" "${PRODUCT_LINE_PATHS[@]}")
  price_ov=$(multiline_text_filter "$FONT_BOLD" "yellow" "$PRICE_FONTSIZE" "(h/2)" "$price_at" 0.6 25 "$LINE_HEIGHT_MULT" "${PRICE_LINE_PATHS[@]}")
  tagline_ov=$(multiline_text_filter "$FONT_REGULAR" "white" "$TAGLINE_FONTSIZE" "h-200" "$tagline_at" 0.6 20 "$LINE_HEIGHT_MULT" "${TAGLINE_LINE_PATHS[@]}")
  echo "${name_ov},${price_ov},${tagline_ov}"
}

TEXT_OVERLAY="$(build_text_overlay 2 5 8)"

TOTAL_FRAMES=$((TARGET_DURATION * 25))

# Ken Burns: scale up 1.5x oversized (1620x2880) so the zoompan has room to
# pan/zoom without exposing empty edges, crop to that size, then zoompan
# down to the final 1080x1920 output. Slow zoom-in (max 1.2x) + fade-in.
VIDEO_FILTER="[0:v]scale=1620:2880:force_original_aspect_ratio=increase,crop=1620:2880,zoompan=z='min(zoom+0.0008,1.2)':x='(iw-iw/zoom)*(on/$((TOTAL_FRAMES - 1)))':y='(ih-ih/zoom)/2':d=${TOTAL_FRAMES}:s=1080x1920:fps=25,fade=t=in:st=0:d=1,${TEXT_OVERLAY}[v]"

INPUT_ARGS=(-y -loop 1 -framerate 25 -i "$MEDIA")
[[ -n "$MUSIC" ]] && INPUT_ARGS+=(-i "$MUSIC")

if [[ -n "$MUSIC" ]]; then
  FADE_OUT_START=$((TARGET_DURATION - 1))
  FILTER_COMPLEX="${VIDEO_FILTER};[1:a]afade=t=in:st=0:d=1,afade=t=out:st=${FADE_OUT_START}:d=1[a]"
else
  FILTER_COMPLEX="$VIDEO_FILTER"
fi

# CRF fallback ladder: try increasingly aggressive compression until the
# output fits under MAX_FILE_SIZE_MB (same strategy as
# renderWithSizeFallback() in server.js).
for CRF in 23 26 28 32; do
  ARGS=("${INPUT_ARGS[@]}" -filter_complex "$FILTER_COMPLEX" -map "[v]")
  OUT_ARGS=(-t "$TARGET_DURATION" -c:v libx264 -preset fast -crf "$CRF" -threads "$FFMPEG_THREADS" -pix_fmt yuv420p)
  if [[ -n "$MUSIC" ]]; then
    ARGS+=(-map "[a]" -shortest)
    OUT_ARGS+=(-c:a aac -b:a 128k)
  fi
  echo "Rendering mode 1 at CRF ${CRF}..."
  ffmpeg "${ARGS[@]}" "${OUT_ARGS[@]}" "$OUTPUT"

  SIZE_MB=$(awk -v b="$(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT")" 'BEGIN{printf "%.2f", b/1024/1024}')
  echo "Output size: ${SIZE_MB}MB"
  if awk -v s="$SIZE_MB" -v max="$MAX_FILE_SIZE_MB" 'BEGIN{exit !(s>0 && s<=max)}'; then
    echo "Mode 1 render complete: $OUTPUT (${SIZE_MB}MB, CRF ${CRF})"
    exit 0
  fi
done

echo "ERROR: could not get output under ${MAX_FILE_SIZE_MB}MB at any CRF level" >&2
exit 1
