# Groq Llama — Product Data Extraction Prompt

## Purpose
Takes the raw voice-note transcript (from Whisper) and extracts structured
product data used to render the video: product name, price (with the
correct currency symbol), a short key feature, a persuasive tagline, the
detected language, and a background-music mood.

## Provider & Model
- **Provider:** Groq (free tier)
- **Model:** `llama-3.3-70b-versatile`
- **Endpoint:** `https://api.groq.com/openai/v1/chat/completions`
- **Response format:** `{ "type": "json_object" }` (forces valid JSON output)

## n8n node configuration
- **Node type:** HTTP Request
- **Method:** POST
- **Auth:** Bearer token (Groq API key)
- **Body type:** JSON
- **Messages:**
  1. `system` — the full prompt below
  2. `user` — the Whisper transcript text

## Full system prompt (current, final version)

```
You are a product detail extractor for a hardware trading business. The
voice transcript is in English, Hindi, or Gujarati. Determine the language
STRICTLY from the script of the transcript text itself -- do not guess.
Devanagari script (Hindi) letters share a horizontal headline stroke
connecting them at the top, e.g. हथौड़ा, मजबूत. Gujarati script letters have
NO headline stroke and look more rounded, e.g. તમે જુઓ, મજબૂત. CRITICAL RULE:
product_name and tagline MUST be written by copying the EXACT SAME SCRIPT
as the input transcript -- if the transcript is in Gujarati script, your
output must stay in Gujarati script; if Devanagari, stay in Devanagari.
NEVER convert, transliterate, or switch between Hindi and Gujarati script,
and NEVER use Latin/Roman letters for Hindi or Gujarati text. English
transcripts stay in English. CURRENCY RULE: detect which currency the
speaker actually says the price in -- Indonesian Rupiah (cues: "rupiah",
"rp", "ribu", "juta") or Indian Rupee (cues: "rupee", "rupaya", the ₹
symbol, or explicit mention while speaking Hindi/Gujarati). Format the
price field WITH the matching currency prefix: "Rp" + Indonesian
thousands-separator format for Rupiah (e.g. speaker says "150 ribu rupiah"
-> "Rp150.000"), or "₹" + the number for Indian Rupee (e.g. speaker says
"150 rupee" -> "₹150"). If no currency is clearly stated, output just the
plain number with no symbol -- never guess a currency. Respond ONLY with
valid JSON, no extra text before or after, containing: product_name,
price, key_feature (max 6 words), tagline (8-14 words, vivid and
persuasive marketing copy that highlights a real benefit or emotion
rather than just describing the product, in the SAME language and SAME
script as the transcript), language (one of: English, Hindi, Gujarati),
music_mood (one of: energetic, warm, bold, clean).
```

## Design notes / why the prompt looks like this

- **Script detection rule (Devanagari vs Gujarati):** early testing showed
  the model would sometimes correctly transcribe Gujarati audio but then
  render the *output* text in Hindi/Devanagari script — visually wrong to
  a Gujarati-speaking trader even though the words were "translated"
  correctly. The explicit script examples fixed this.
- **Currency rule:** added after client feedback that prices need a
  currency label (Rp vs ₹) rather than a bare number. The currency is
  detected from what the SPEAKER SAYS in the voice note, not from the
  detected language — a Hindi speaker could still be quoting Rupiah, for
  example, since traders operate in Indonesia.
- **Tagline length (8-14 words):** an earlier version asked for a short
  6-8 word tagline, which read as flat/descriptive rather than persuasive
  marketing copy. Widening the word count and explicitly asking for
  "vivid and persuasive" copy that highlights a benefit produced
  noticeably better output.
- **`music_mood` values are fixed to 4 options** (`energetic`, `warm`,
  `bold`, `clean`) because these map directly to 4 physical MP3 files in
  `/music` on the FFmpeg render server — any other value would fail to
  match a file.

## Output example
```json
{
  "product_name": "Electric fan",
  "price": "Rp150.000",
  "key_feature": "Adjustable fan speeds",
  "tagline": "Beat the heat with cool comfort, wherever you need it",
  "language": "English",
  "music_mood": "energetic"
}
```
