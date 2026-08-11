# Mansi webhook contract (Week 3/4 merge)

This document is the standing reference for the handoff between Mansi's workflow (front door / GRAPHIC modes) and this workflow (VIDEO modes), separate from the live discussion on Trello.

## Endpoint

```
POST https://n8n-production-770f3.up.railway.app/webhook/3cc66240-2068-4957-9bd7-6bdeb4b35a84/video-request
Content-Type: application/json
```

## Request body

| Field | Type | Notes |
|---|---|---|
| `event` | string | Always `"video_request"` |
| `session_key` | string | Trader's WhatsApp number, e.g. `whatsapp:+91XXXXXXXXXX` — used as the delivery address for the finished MP4 |
| `mode` | string | `"4"`, `"5"`, or `"6"` — see mapping below |
| `media_urls` | array of strings | One URL for mode 4/6 (single photo/video), 3-5 URLs for mode 5 (slideshow) |
| `voice_note_url` | string | Trader's original voice note (currently unused downstream but passed through) |
| `transcript` | string | Already transcribed by Mansi's workflow — this workflow does not re-run Whisper |
| `product_name` | string | Already extracted by Mansi's workflow |
| `price` | string | Already extracted, with currency symbol/prefix already applied |
| `key_feature` | string | Already extracted (max ~6 words) |
| `tagline` | string | Already extracted (8-14 words, same language/script as the transcript) |
| `language` | string | One of `English`, `Hindi`, `Gujarati` |
| `music_mood` | string | One of `energetic`, `warm`, `bold`, `clean` |

## Mode mapping

| `mode` (Mansi's unified numbering) | Meaning | This workflow's internal mode |
|---|---|---|
| `"4"` | single photo, animated reel | `1` — Ken Burns zoom/pan |
| `"5"` | multi-photo slideshow reel | `2` — 0.5s cross-fade slideshow |
| `"6"` | trader's own video, edited | `3` — color grade + music mix |

Modes `1`, `2`, `3` in Mansi's unified numbering are her own static-graphic modes and are never sent to this webhook.

## What happens on our side

1. `Mansi Entry Mapping` (Code node) remaps the mode, normalizes field names to this workflow's internal convention, and skips straight past the Groq Whisper/Llama steps (since Mansi already provides `transcript` and the extracted fields).
2. The request joins the same rendering pipeline used by direct Twilio traffic: Music Mapping → FFmpeg render (Railway) → Twilio delivery → Google Sheets logging.
3. The finished MP4 is sent directly to `session_key` on WhatsApp.
4. A success callback is POSTed back: `{"event": "video_delivered", "session_key": "...", "status": "success"}`. **This is currently disabled pending Mansi's webhook URL** — see the main README's "Known limitations" section.

## Testing status (as of the Week 3/4 merge day)

- Mode 4 → internal 1: tested end-to-end (real render + real WhatsApp delivery), confirmed working.
- Mode 5 → internal 2: tested end-to-end with a synthetic payload, confirmed working.
- Mode 6 → internal 3: tested end-to-end with a synthetic payload, confirmed working.
- Not yet done: a joint test where Mansi's live workflow actually calls this webhook (all tests so far used manually-constructed payloads standing in for her output).
