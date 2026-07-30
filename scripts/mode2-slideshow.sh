#!/bin/bash
# ==============================================================================
# Mode 2 — Multi-Photo Slideshow with Cross-Fade
# ==============================================================================
# Input:  3-5 product photos + background music track
# Output: 1080x1920 MP4, 15 seconds EXACT (regardless of photo count),
#         0.5s cross-fade between photos, animated text overlay
#
# Usage:
#   ./mode2-slideshow.sh <music.mp3> <product_name.txt> <price.txt> \
#       <tagline.txt> <bold_font.ttf> <regular_font.ttf> <output.mp4> <crf> \
#       <photo1.jpg> <photo2.jpg> [photo3.jpg] [photo4.jpg] [photo5.jpg]
#
# IMPORTANT CONTEXT: WhatsApp/Twilio delivers each photo the trader sends
# as its OWN separate webhook — even if the trader picks several photos
# together in their gallery, they never arrive bundled in one message.
# The n8n workflow accumulates photo URLs across those separate messages
# (capped at 5) before calling this render step, so by the time this
# script runs it always has the FULL set of photos already downloaded.
# ==============================================================================

MUSIC="$1"; PRODUCT_NAME_FILE="$2"; PRICE_FILE="$3"; TAGLINE_FILE="$4"
BOLD_FONT="$5"; REGULAR_FONT="$6"; OUTPUT="$7"; CRF="${8:-23}"
shift 8
PHOTOS=("$@")   # remaining args: 3-5 photo file paths
N=${#PHOTOS[@]}

DURATION=15
XFADE_DUR=0.5   # per Trello spec: 0.5s cross-fade between photos

# --- Duration math (THIS WAS A REAL BUG — read carefully) -----------------
# For a chain of N xfade stages, each stage's output duration works out to
# (offset + duration of the incoming clip). With offset_k = k*HOLD_DUR, the
# chain's FINAL total duration is:
#       N * HOLD_DUR + XFADE_DUR
# — only ONE transition's worth gets added overall, not (N-1) of them.
# An earlier version of this subtracted XFADE_DUR*(N-1) up front, which
# under-shot the 15s target more and more as photo count grew (5 photos
# produced ~13.5s instead of 15s). Solving for the correct HOLD_DUR:
if [ "$N" -gt 1 ]; then
  HOLD_DUR=$(echo "($DURATION - $XFADE_DUR) / $N" | bc -l)
  CLIP_DUR=$(echo "$HOLD_DUR + $XFADE_DUR" | bc -l)
else
  HOLD_DUR=$DURATION
  CLIP_DUR=$DURATION
fi

# --- Build ffmpeg input args: each photo looped for CLIP_DUR seconds ------
INPUT_ARGS=()
for photo in "${PHOTOS[@]}"; do
  INPUT_ARGS+=(-loop 1 -t "$CLIP_DUR" -i "$photo")
done

# --- Build the per-photo scale/crop filters --------------------------------
FILTER_PARTS=()
for i in "${!PHOTOS[@]}"; do
  FILTER_PARTS+=("[$i:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1[v$i]")
done

# --- Chain the cross-fade transitions between consecutive photos ----------
PREV_LABEL="v0"
if [ "$N" -gt 1 ]; then
  for ((i=1; i<N; i++)); do
    OFFSET=$(echo "$i * $HOLD_DUR" | bc -l)
    OUT_LABEL="vx$i"
    FILTER_PARTS+=("[${PREV_LABEL}][v${i}]xfade=transition=fade:duration=${XFADE_DUR}:offset=${OFFSET}[${OUT_LABEL}]")
    PREV_LABEL="$OUT_LABEL"
  done
fi

# --- Text overlay -----------------------------------------------------------
# Per Trello spec (Mode 2 differs from Mode 1's timing):
#   - product name: shown FROM THE START (t=0), not a delayed appear —
#     it should be visible "throughout" the slideshow
#   - price:        appears at t=5s
#   - tagline:       appears at t=10s (Mode 1 uses t=8s — do not copy that)
# Same top/middle/bottom layout, bold/yellow price, as Mode 1.
TEXT_FILTER="drawtext=fontfile='${BOLD_FONT}':textfile='${PRODUCT_NAME_FILE}':fontcolor=white:fontsize=60:x=(w-text_w)/2:y='200+25*(1-min(max((t-0)/0.6,0),1))':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='if(lt(t,0),0,min((t-0)/0.6,1))',drawtext=fontfile='${BOLD_FONT}':textfile='${PRICE_FILE}':fontcolor=yellow:fontsize=80:x=(w-text_w)/2:y='(h/2)+25*(1-min(max((t-5)/0.6,0),1))':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='if(lt(t,5),0,min((t-5)/0.6,1))',drawtext=fontfile='${REGULAR_FONT}':textfile='${TAGLINE_FILE}':fontcolor=white:fontsize=40:x=(w-text_w)/2:y='h-200+20*(1-min(max((t-10)/0.6,0),1))':borderw=2:bordercolor=black@0.75:shadowcolor=black@0.5:shadowx=2:shadowy=2:alpha='if(lt(t,10),0,min((t-10)/0.6,1))'"
FILTER_PARTS+=("[${PREV_LABEL}]${TEXT_FILTER}[v]")

# --- Audio: music track, index N (after all N photo inputs) ---------------
MUSIC_INDEX=$N
FILTER_PARTS+=("[${MUSIC_INDEX}:a]afade=t=in:st=0:d=1,afade=t=out:st=$((DURATION-1)):d=1[a]")

FILTER_COMPLEX=$(IFS=';'; echo "${FILTER_PARTS[*]}")

ffmpeg -y \
  "${INPUT_ARGS[@]}" \
  -i "$MUSIC" \
  -filter_complex "$FILTER_COMPLEX" \
  -map "[v]" -map "[a]" -shortest \
  -t ${DURATION} \
  -c:v libx264 -preset fast -crf "${CRF}" \
  -threads 2 \
  -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  "$OUTPUT"
