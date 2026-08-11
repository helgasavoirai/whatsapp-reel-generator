# WhatsApp Product Video Reel Generator

Turns a trader's WhatsApp message (photo/video + voice note) into a 15-second (13s for Mode 3) branded product reel, automatically delivered back to them on WhatsApp — no editing software required on their end.

> **Week 3/4 update:** this workflow is now one of two "kitchens" behind a single unified WhatsApp trading assistant. Mansi's workflow is the front door (welcome menu, mode selection, and the three GRAPHIC modes); this workflow handles the three VIDEO modes and is reached via a webhook. See **"Merge architecture"** below.

## What it does

A trader messages a WhatsApp Business number and picks one of three modes:

| Mode | Input | Output style |
|------|-------|---------------|
| 1 | 1 photo + voice note | Ken Burns zoom/pan animated photo reel |
| 2 | 3-5 photos + voice note | Slideshow with 0.5s cross-fade transitions |
| 3 | 1 short video (5-15s) + voice note | Color-graded edit of the trader's own video |

> **Note on mode numbers:** the table above is this workflow's own internal numbering (unchanged since Week 2). In the unified 6-mode system after the Week 3/4 merge with Mansi's graphic-only workflow, these correspond to **unified modes 4, 5, and 6** respectively (unified 1-3 are Mansi's static-graphic modes and never reach this workflow). See the webhook contract below for the exact mapping.

All three modes overlay the product name, price, and a short tagline (auto-generated from the voice note), with background music matched to the product's tone, and are limited to WhatsApp's 16MB media cap.

## Pipeline

This workflow has **two entry points** that both feed the same downstream pipeline (mode detection/remap → Groq → FFmpeg render → Twilio delivery → Google Sheets logging):

```
Entry 1 — direct trader traffic:
Twilio WhatsApp webhook
  → Extract fields → Session matching (Google Sheets Sessions tab)
  → Groq Whisper (voice note transcription)
  → Groq Llama 3.3 70B (extract product name / price / tagline / language / music mood)
  → [joins main pipeline below]

Entry 2 — traffic routed from Mansi's workflow (Week 3/4 merge):
POST /video-request webhook
  → Mansi Entry Mapping (remaps her mode 4/5/6 → this workflow's 1/2/3,
    normalizes field names, skips Whisper/Llama since Mansi already sends
    transcript + extracted product data)
  → [joins main pipeline below]

Main pipeline (both entries converge here):
  → Music Mapping → FFmpeg render server (Railway) — builds the final MP4
  → Twilio sends the MP4 back to the trader on WhatsApp
  → Logged to Google Sheets (Logs-Video tab, incl. OutputType/RoutedTo columns)
  → (if routed from Mansi) fires a success callback back to her workflow
```

The original Twilio entry point was not modified by the merge and continues to work independently of the new webhook.

## Webhook contract (for Mansi's workflow)

**Endpoint:** `POST https://n8n-production-770f3.up.railway.app/webhook/3cc66240-2068-4957-9bd7-6bdeb4b35a84/video-request`

**Request body:**
```json
{
  "event": "video_request",
  "session_key": "whatsapp:+91XXXXXXXXXX",
  "mode": "4",
  "media_urls": ["https://..."],
  "voice_note_url": "https://...",
  "transcript": "...",
  "product_name": "...",
  "price": "...",
  "key_feature": "...",
  "tagline": "...",
  "language": "English",
  "music_mood": "clean"
}
```

**Mode mapping** (her unified numbering → this workflow's internal numbering):

| Her `mode` value | Meaning | Internal mode used here |
|---|---|---|
| `"4"` | single photo animated reel | `1` (Ken Burns) |
| `"5"` | slideshow reel | `2` (cross-fade slideshow) |
| `"6"` | product video edit | `3` (color-graded video edit) |

**On success:** this workflow sends the finished MP4 straight to the trader's WhatsApp number (`session_key`), then POSTs a callback to Mansi's workflow: `{"event": "video_delivered", "session_key": "...", "status": "success"}`. (Callback URL still needs to be filled in on our side once Mansi shares it — see Known limitations.)

## Prerequisites

- n8n instance (self-hosted; this project runs on Railway)
- Railway account for the n8n instance AND a separate service for the FFmpeg render server (`whatsapp-reel-ffmpeg-server` repo)
- Twilio account with WhatsApp enabled (sandbox for testing, or an approved Meta Cloud API business number for production — see "Known limitations" below)
- Groq API key (free tier) for Whisper transcription + Llama extraction
- Google Sheets with a `Sessions`, `Logs-Video`, and `Quota-Tracker` tab (see schema below — must match Mansi's Week 2 pipeline exactly, since both are merged in Week 3/4)

## Railway deployment

### n8n service

1. Deploy the official n8n Railway template (single instance + Postgres — avoid the "w/ workers" queue-mode variant, it's unnecessary extra complexity for this workflow's scale)
2. Set environment variables: `N8N_ENCRYPTION_KEY` (generate a long random string and store it somewhere safe — losing it makes all saved credentials unrecoverable), `WEBHOOK_URL`, `GENERIC_TIMEZONE`, plus the Postgres `DB_*` variables Railway auto-fills in
3. Generate a public domain (Settings → Networking → Generate Domain)
4. Import `workflow/reel-generator.json` into the new instance, then re-enter all credentials (Twilio, Groq, Google Sheets OAuth) — these never survive a JSON export/import since they're encrypted per-instance
5. Update the Twilio WhatsApp webhook URL to point at the new n8n domain, and share the `/video-request` webhook URL with Mansi

### FFmpeg render server

1. Separate Railway service, deployed from the `whatsapp-reel-ffmpeg-server` repo (Node.js + Dockerfile)
2. If both services are in the same Railway project, point the n8n Config node's `FfmpegEndpoint` at the FFmpeg service's internal Railway domain (`<service>.railway.internal:<port>`) rather than its public URL — faster and avoids unnecessary public exposure
3. On Railway's free tier, CPU/RAM limits are fixed (2 vCPU / 1GB in testing) and can't be raised without upgrading the plan — the render scripts are tuned to stay within that (see `-threads 2` note in the Mode 1 script). **High memory usage on this service can cause renders to hang indefinitely rather than fail cleanly — if a render seems stuck for more than ~60s, check Railway's Metrics tab and restart/redeploy the service.**

## Font installation

Both Regular and Bold weights are required per language — product name and price use Bold, tagline uses Regular:

- `NotoSans-Regular.ttf` / `NotoSans-Bold.ttf` (English)
- `NotoSansDevanagari-Regular.ttf` / `NotoSansDevanagari-Bold.ttf` (Hindi)
- `NotoSansGujarati-Regular.ttf` / `NotoSansGujarati-Bold.ttf` (Gujarati)

All are free (Google Fonts, OFL license). Download each family from fonts.google.com, extract the `static/` folder, and upload the 6 exact files above into `/fonts` on the FFmpeg render server repo — file names must match exactly (case-sensitive) or the renderer silently falls back to a system font instead of the intended one.

## Trader onboarding message template

Sent automatically when a trader first messages the number, or can be used as a pinned/welcome message:

> Welcome! To create a product video reel, first reply with: 1 — Single photo reel 2 — Multi-photo slideshow (3-5 photos) 3 — Edit your own product video
>
> Then send your photo(s)/video one at a time, followed by a voice note naming the product, its price, and a short description. You'll get your finished video back here within about a minute.

(Traders reaching this workflow via Mansi's unified menu instead see her own onboarding message, covering all 6 modes.)

## Known Mode 3 limitations

- Silent trader videos (no audio track — a known WhatsApp quirk, not rare) are handled by falling back to music-only instead of crashing, but there's no way to warn the trader in advance that their video has no audio.
- If the trader's video is shorter than 13 seconds, the output uses the video's actual length rather than padding or looping to fill the gap.
- Very large source videos (near WhatsApp's 16MB inbound limit) increase render time; there's no separate size/duration validation step before attempting the render.

## Known limitations (Week 3/4 merge)

- The success-callback node to Mansi's workflow (`Notify Mansi Success`) is built but currently **disabled** — it needs her real webhook URL filled into the `Mansi Entry Mapping` code node's `MansiCallbackUrl` field before being switched on.
- Modes 5 and 6 (slideshow / video edit routed from Mansi) have been tested solo with synthetic payloads, not yet jointly with Mansi's live workflow end-to-end.
- The Railway FFmpeg render server's free-tier memory can cause a render to hang rather than fail if a previous request wasn't fully released — see the Railway deployment note above.

## Repo structure

```
/workflow/reel-generator.json   — full n8n workflow export
/scripts/mode1-ken-burns.sh     — Mode 1 FFmpeg command, commented
/scripts/mode2-slideshow.sh     — Mode 2 FFmpeg command, commented
/scripts/mode3-video-edit.sh    — Mode 3 FFmpeg command, commented
/music/                         — background music tracks + LICENCES.md
/fonts/                         — Noto Sans font files (see above)
/prompts/whisper-setup.md       — Whisper transcription setup notes
/prompts/llama-extraction-video.md — full Llama extraction system prompt
/prompts/mansi-webhook-contract.md — webhook contract details for the Week 3/4 merge
```

## Loom walkthrough

(https://www.loom.com/share/474c09ccbcc149a9be7b966285ad5018) — 3-minute walkthrough of all 3 modes end to end, including one Hindi/Gujarati voice note test, showing the MP4 arriving back in WhatsApp.

## Links

- Google Sheets: https://docs.google.com/spreadsheets/d/1Dy5TQA2nEP4enNVfinTzEHUc0SJYQw-K_bZ5_Wm3XYo/edit
- FFmpeg render server repo: `whatsapp-reel-ffmpeg-server`
