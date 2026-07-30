# WhatsApp Product Video Reel Generator (Week 2)

Turns a trader's WhatsApp message (photo/video + voice note) into a
15-second (13s for Mode 3) branded product reel, automatically delivered
back to them on WhatsApp — no editing software required on their end.

## What it does

A trader messages a WhatsApp Business number and picks one of three modes:

| Mode | Input | Output style |
|---|---|---|
| **1** | 1 photo + voice note | Ken Burns zoom/pan animated photo reel |
| **2** | 3-5 photos + voice note | Slideshow with 0.5s cross-fade transitions |
| **3** | 1 short video (5-15s) + voice note | Color-graded edit of the trader's own video |

All three modes overlay the product name, price, and a short tagline
(auto-generated from the voice note), with background music matched to
the product's tone, and are limited to WhatsApp's 16MB media size cap.

### Pipeline
```
Twilio WhatsApp webhook
  → n8n: mode detection & session matching (Google Sheets)
  → Groq Whisper (voice note transcription)
  → Groq Llama 3.3 70B (extract product name / price / tagline / language / music mood)
  → FFmpeg render server (Railway) — builds the final MP4
  → Twilio sends the MP4 back to the trader on WhatsApp
  → Logged to Google Sheets (Logs-Video tab)
```

## Prerequisites

- **n8n** instance (self-hosted; this project runs on Railway)
- **Railway** account for the n8n instance AND a separate service for the
  FFmpeg render server (`whatsapp-reel-ffmpeg-server` repo)
- **Twilio** account with WhatsApp enabled (sandbox for testing, or an
  approved Meta Cloud API business number for production — see
  "Known limitations" below)
- **Groq API key** (free tier) for Whisper transcription + Llama extraction
- **Google Sheets** with a `Sessions`, `Logs-Video`, and `Quota-Tracker` tab
  (see schema below — must match Mansi's Week 2 pipeline exactly, since
  both are merged in Week 3)

## Railway deployment

### n8n service
1. Deploy the official **n8n** Railway template (single instance +
   Postgres — avoid the "w/ workers" queue-mode variant, it's unnecessary
   extra complexity for this workflow's scale)
2. Set environment variables: `N8N_ENCRYPTION_KEY` (generate a long
   random string and store it somewhere safe — losing it makes all saved
   credentials unrecoverable), `WEBHOOK_URL`, `GENERIC_TIMEZONE`, plus the
   Postgres `DB_*` variables Railway auto-fills in
3. Generate a public domain (Settings → Networking → Generate Domain)
4. Import `workflow/reel-generator.json` into the new instance, then
   re-enter all credentials (Twilio, Groq, Google Sheets OAuth) — these
   never survive a JSON export/import since they're encrypted per-instance
5. Update the Twilio WhatsApp webhook URL to point at the new n8n domain

### FFmpeg render server
1. Separate Railway service, deployed from the
   `whatsapp-reel-ffmpeg-server` repo (Node.js + Dockerfile)
2. If both services are in the same Railway project, point the n8n
   Config node's `FFmpegEndpoint` at the FFmpeg service's **internal**
   Railway domain (`<service>.railway.internal:<port>`) rather than its
   public URL — faster and avoids unnecessary public exposure
3. On Railway's free tier, CPU/RAM limits are fixed (2 vCPU / 1GB in
   testing) and can't be raised without upgrading the plan — the render
   scripts are tuned to stay within that (see `-threads 2` note in the
   Mode 1 script)

## Font installation

Both **Regular** and **Bold** weights are required per language — product
name and price use Bold, tagline uses Regular:

- `NotoSans-Regular.ttf` / `NotoSans-Bold.ttf` (English)
- `NotoSansDevanagari-Regular.ttf` / `NotoSansDevanagari-Bold.ttf` (Hindi)
- `NotoSansGujarati-Regular.ttf` / `NotoSansGujarati-Bold.ttf` (Gujarati)

All are free (Google Fonts, OFL license). Download each family from
fonts.google.com, extract the `static/` folder, and upload the 6 exact
files above into `/fonts` on the FFmpeg render server repo — file names
must match exactly (case-sensitive) or the renderer silently falls back
to a system font instead of the intended one.

## Trader onboarding message template

Sent automatically when a trader first messages the number, or can be
used as a pinned/welcome message:

> Welcome! To create a product video reel, first reply with:
> **1** — Single photo reel
> **2** — Multi-photo slideshow (3-5 photos)
> **3** — Edit your own product video
>
> Then send your photo(s)/video one at a time, followed by a voice note
> naming the product, its price, and a short description. You'll get
> your finished video back here within about a minute.

## Known Mode 3 limitations

- Silent trader videos (no audio track — a known WhatsApp quirk, not
  rare) are handled by falling back to music-only instead of crashing,
  but there's no way to warn the trader in advance that their video has
  no audio.
- If the trader's video is shorter than 13 seconds, the output uses the
  video's actual length rather than padding or looping to fill the gap.
- Very large source videos (near WhatsApp's 16MB inbound limit) increase
  render time; there's no separate size/duration validation step before
  attempting the render.

## Repo structure
```
/workflow/reel-generator.json     — full n8n workflow export
/scripts/mode1-ken-burns.sh       — Mode 1 FFmpeg command, commented
/scripts/mode2-slideshow.sh       — Mode 2 FFmpeg command, commented
/scripts/mode3-video-edit.sh      — Mode 3 FFmpeg command, commented
/music/                           — background music tracks + LICENCES.md
/fonts/                           — Noto Sans font files (see above)
/prompts/whisper-setup.md         — Whisper transcription setup notes
/prompts/llama-extraction-video.md — full Llama extraction system prompt
```

## Loom walkthrough
[Add link here] — 3-minute walkthrough of all 3 modes end to end,
including one Hindi/Gujarati voice note test, showing the MP4 arriving
back in WhatsApp.

## Links
- Google Sheets: https://docs.google.com/spreadsheets/d/1Dy5TQA2nEP4enNVfinTzEHUc0SJYQw-K_bZ5_Wm3XYo/edit
- FFmpeg render server repo: `whatsapp-reel-ffmpeg-server`
