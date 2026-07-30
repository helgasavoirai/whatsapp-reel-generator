#!/bin/bash
# ==============================================================================
# Mode 1 — Single Photo Ken Burns Animated Reel
# ==============================================================================
# Input:  1 product photo + background music track
# Output: 1080x1920 MP4, 15 seconds, Ken Burns zoom+pan, animated text overlay
#
# Usage:
#   ./mode1-ken-burns.sh <photo.jpg> <music.mp3> <product_name.txt> <price.txt> \
#       <tagline.txt> <bold_font.ttf> <regular_font.ttf> <output.mp4> <crf>
#
# This mirrors exactly what server.js's Mode 1 branch builds at runtime.
# ==============================================================================

PHOTO="$1"
MUSIC="$2"
PRODUCT_NAME_FILE="$3"   # plain text file, NOT the raw string — avoids all
                          # shell/ffmpeg escaping issues with quotes/commas
PRICE_FILE="$4"
TAGLINE_FILE="$5"
BOLD_FONT="$6"            # e.g. fonts/NotoSans-Bold.ttf (product name + price)
REGULAR_FONT="$7"         # e.g. fonts/NotoSans-Regular.ttf (tagline)
OUTPUT="$8"
CRF="${9:-23}"            # quality level; server.js retries at 23/26/28/32
                          # until the file is under the 16MB WhatsApp limit

DURATION=15
FPS=25
TOTAL_FRAMES=$((DURATION * FPS))   # 375 frames

# --- Ken Burns motion ---------------------------------------------------
# 1) Pre-scale the photo to a moderate working size (1620x2880) BEFORE
#    zoompan touches it. Running zoompan directly on a full-resolution
#    photo (often 3000px+) was what caused OOM kills on Railway's 1GB
#    container earlier in development — this keeps memory bounded.
# 2) zoompan zooms from 1.0x up to 1.2x over the full 375 frames, while
#    x= pans the crop window left-to-right as zoom increases (giving a
#    combined zoom+pan "Ken Burns" motion, not just a static zoom).
# 3) fade=t=in fades the whole clip in from black over the first second.
KEN_BURNS_FILTER="[0:v]scale=1620:2880:force_original_aspect_ratio=increase,crop=1620:2880,zoompan=z='min(zoom+0.0008,1.2)':x='(iw-iw/zoom)*(on/$((TOTAL_FRAMES-1)))':y='(ih-ih/zoom)/2':d=${TOTAL_FRAMES}:s=1080x1920:fps=${FPS},fade=t=in:st=0:d=1"

# --- Text overlay ---------------------------------------------------------
# Per Trello spec: product name near the TOP (bold, white), price in the
# MIDDLE (bold, YELLOW, largest — the visual focal point), tagline near
# the BOTTOM (regular weight, white, smallest). Each line fades in and
# slides up slightly into position, rather than appearing as a hard cut:
#   - product name: appears at t=2s
#   - price:        appears at t=5s
#   - tagline:       appears at t=8s
# borderw/shadowcolor give readability against any photo background
# WITHOUT a flat grey box behind the text (an earlier, less polished pass
# used box=1:boxcolor=black@0.5, which looked flat and was dropped).
TEXT_FILTER="drawtext=fontfile='${BOLD_FONT}':textfile='${PRODUCT_NAME_FILE}':fontcolor=white:fontsize=60:x=(w-text_w)/2:y='200+25*(1-min(max((t-2)/0.6,0),1))':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='if(lt(t,2),0,min((t-2)/0.6,1))',drawtext=fontfile='${BOLD_FONT}':textfile='${PRICE_FILE}':fontcolor=yellow:fontsize=80:x=(w-text_w)/2:y='(h/2)+25*(1-min(max((t-5)/0.6,0),1))':borderw=3:bordercolor=black@0.85:shadowcolor=black@0.6:shadowx=2:shadowy=2:alpha='if(lt(t,5),0,min((t-5)/0.6,1))',drawtext=fontfile='${REGULAR_FONT}':textfile='${TAGLINE_FILE}':fontcolor=white:fontsize=40:x=(w-text_w)/2:y='h-200+20*(1-min(max((t-8)/0.6,0),1))':borderw=2:bordercolor=black@0.75:shadowcolor=black@0.5:shadowx=2:shadowy=2:alpha='if(lt(t,8),0,min((t-8)/0.6,1))'"

# --- Audio: music fade in/out (1s each) -----------------------------------
AUDIO_FILTER="[1:a]afade=t=in:st=0:d=1,afade=t=out:st=$((DURATION-1)):d=1[a]"

ffmpeg -y \
  -loop 1 -framerate ${FPS} -i "$PHOTO" \
  -i "$MUSIC" \
  -filter_complex "${KEN_BURNS_FILTER},${TEXT_FILTER}[v];${AUDIO_FILTER}" \
  -map "[v]" -map "[a]" -shortest \
  -t ${DURATION} \
  -c:v libx264 -preset fast -crf "${CRF}" \
  -threads 2 \
  -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  "$OUTPUT"

# NOTE on -threads 2:
# Railway containers report far more CPUs than they actually get. Leaving
# FFmpeg to auto-detect threads (sometimes 60+) causes huge memory
# overhead and the process gets OOM-killed mid-render. Pinning to 2
# threads fixed this — do not remove.
