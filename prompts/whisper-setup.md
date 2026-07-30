# Groq Whisper — Voice Note Transcription Setup

## Purpose
Transcribes the trader's voice note (product name, price, key feature) into
text, in whichever language the trader speaks it. This transcript is then
passed to the Groq Llama extraction step.

## Provider & Model
- **Provider:** Groq (free tier)
- **Model:** `whisper-large-v3`
- **Endpoint:** `https://api.groq.com/openai/v1/audio/transcriptions`

## Supported languages
English, Hindi, Gujarati — no `language` parameter is forced; Whisper
auto-detects from the audio itself.

## n8n node configuration
- **Node type:** HTTP Request
- **Method:** POST
- **Auth:** Bearer token (Groq API key), via generic credential
- **Body type:** multipart/form-data
- **Body fields:**
  - `file` — the downloaded voice note audio (binary), fetched first from
    the Twilio media URL (Twilio media requires HTTP Basic Auth using the
    Twilio Account SID + Auth Token to download)
  - `model` — `whisper-large-v3`

## Known issue and mitigation
Gujarati voice notes were occasionally misidentified as Hindi by the
downstream Llama extraction step (not Whisper itself — Whisper's raw
transcript is generally accurate; the issue was the *language label*
assigned afterward). This was more pronounced with AI-generated test audio
than with natural human recordings. Mitigated by hardening the Llama
extraction system prompt with explicit script-detection rules (see
`llama-extraction-video.md`) — Devanagari (Hindi) script has a connecting
headline stroke across characters; Gujarati script does not and looks more
rounded. If this still happens with real trader audio, re-verify with
several natural (non-AI-generated) Gujarati samples before assuming it's
resolved.

## Output
The transcript text feeds directly into the Groq Llama Extraction step as
the `content` of the user message — see `llama-extraction-video.md`.
