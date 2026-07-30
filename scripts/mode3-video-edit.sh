#!/bin/bash
# ==============================================================================
# Mode 3 — Trader Video Edit (color grade + text + audio mix)
# ==============================================================================
# Input:  1 trader-recorded product video (5-15s) + background music track
# Output: 1080x1920 MP4, 13 seconds (or shorter if the source video is
#         shorter than 13s — never padded/looped to fill the gap)
#
# Usage:
#   ./mode3-video-edit.sh <video.mp4> <music.mp3> <product_name.txt> \
#       <price.txt> <tagline.txt> <bold_font.ttf> <regular_font.ttf> \
#       <output.mp4> <crf>
# ==============================================================================

VIDEO="$1"; MUSIC="$2"; PRODUCT_NAME_FILE="$3"; PRICE_FILE="$4"
TAGLINE_FILE="$5"; BOLD_FONT="$6"; REGULAR_FONT="$7"; OUTPUT="$8"
CRF="${9:-23}"

MAX_DURATION=13

# --- Duration: cap at 13s, but use the ACTUAL video length if it's shorter -
PROBED_DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$VIDEO")
if (( $(echo "$PROBED_DURATION < $MAX_DURATION" | bc -l) )); then
  DURATION="$PROBED_DURATION"
else
  DURATION="$MAX_DURATION"
fi

# --- Check whether the trader's video has an audio track at all -----------
# WhatsApp videos are sometimes silent (no audio track) — a known platform
# quirk, not a rare edge case. Referencing a nonexistent [0:a] stream in
# the filter_complex crashes ffmpeg outright, so this MUST be checked
# before deciding how to build the audio filter chain below.
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=index \
  -of csv=p=0 "$VIDEO")

# --- Color grade + text overlay --------------------------------------------
# Per Trello spec exactly: saturation=1.3, contrast=1.1, brightness=0.05.
# Text timing differs again from Mode 1/2: name@2s, price@6s, tagline@10s.
VIDEO_FILTER="[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,eq=saturation=1.3:contrast=1.1:brightness=0.05"
TEXT_FILTER="drawtext=fontfile='${BOLD_FONT}':textfile='${PRODUCT_NAME_FILE}':fontcolor=white:fontsize=60:x=(w-text_w)/2:y='200+25*(1-min(max((t-2)/0.6,0),1))':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='if(lt(t,2),0,min((t-2)/0.6,1))',drawtext=fontfile='${BOLD_FONT}':textfile='${PRICE_FILE}':fontcolor=yellow:fontsize=80:x=(w-text_w)/2:y='(h/2)+25*(1-min(max((t-6)/0.6,0),1))':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='if(lt(t,6),0,min((t-6)/0.6,1))',drawtext=fontfile='${REGULAR_FONT}':textfile='${TAGLINE_FILE}':fontcolor=white:fontsize=40:x=(w-text_w)/2:y='h-200+20*(1-min(max((t-10)/0.6,0),1))':borderw=2:bordercolor=black@0.75:shadowcolor=black@0.5:shadowx=2:shadowy=2:alpha='if(lt(t,10),0,min((t-10)/0.6,1))'"

if [ -n "$HAS_AUDIO" ]; then
  # Per Trello spec: original video audio at 30% volume, music at 70%,
  # mixed together (music also fades in/out over 1s each).
  AUDIO_FILTER="[0:a]volume=0.3[a0];[1:a]volume=0.7,afade=t=in:st=0:d=1,afade=t=out:st=$(echo "$DURATION - 1" | bc -l):d=1[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[a]"
else
  # Silent trader video: fall back to music-only (faded), same treatment
  # as Mode 1/2, instead of crashing on a nonexistent audio stream.
  AUDIO_FILTER="[1:a]afade=t=in:st=0:d=1,afade=t=out:st=$(echo "$DURATION - 1" | bc -l):d=1[a]"
fi

ffmpeg -y \
  -i "$VIDEO" \
  -i "$MUSIC" \
  -filter_complex "${VIDEO_FILTER},${TEXT_FILTER}[v];${AUDIO_FILTER}" \
  -map "[v]" -map "[a]" \
  -t "$DURATION" \
  -c:v libx264 -preset fast -crf "${CRF}" \
  -threads 2 \
  -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  "$OUTPUT"

# If output exceeds 16MB (WhatsApp's media size limit), re-run with a
# higher CRF (26, then 28, then 32) — each step trades some quality for a
# smaller file. server.js automates this retry ladder automatically.
