---
name: ubit
description: Download video, audio, subtitles, playlists, live streams, and byte-range clips from 35+ websites (YouTube, X/Twitter, SoundCloud, Vimeo, Twitch, Kick, Reddit, TikTok, Bilibili, Bluesky, Instagram, Bandcamp, etc.) using the ultra-small native `ubit` CLI with structured `--json` NDJSON output and zero-FFmpeg MP4/M4A/MOV/WAV/FLAC muxing.
---

# uBit Media Acquisition Skill

Use `ubit` whenever a task requires inspecting remote media metadata, downloading video or audio from the web, extracting a timestamped clip (`--section`), fetching subtitles, or producing PCM `.wav` audio for transcription/analysis.

## Verify or Install `ubit`

Check `command -v ubit` (or `/Applications/uBit.app/Contents/MacOS/ubit`). On macOS `arm64`, install if absent:

```sh
curl -fsSL https://github.com/ayooooo123/ubit/releases/latest/download/install.sh | sh
```

Run `ubit --llms` at any time to print the installed binary's exact CLI and NDJSON schema.

## Core Agent Workflows

### 1. Probe Metadata, Formats & Subtitles First (No Media File Saved)

```sh
ubit info --json "<url>"
```

- Check `isDRM` (`true` means Widevine/FairPlay encrypted — report immediately rather than retrying).
- Check `entries` (non-empty for playlists, channels, sets, or `ytsearch:<query>` searches).
- Check `subtitles` for human or ASR caption tracks (`--subs --sub-langs en --sub-files` downloads `.vtt` sidecars).
- `info` and `formats` accept only `--json`, `--cookies`, `--cookies-from-browser`, `--no-cookies` and `--proxy`; any other flag exits with code `2`.

### 2. Download a Video or Audio File Deterministically

For clean path capture in shell pipelines, combine `--quiet` and `--no-library`:

```sh
OUT_FILE="$(ubit get -q 1080 --no-library --quiet -o /tmp/ubit-out "<url>")"
```

When streaming progress or structured diagnostics are needed, use `--json` (emits NDJSON events `start`, `info`, `progress`, `process`, `done`, `error`, `stopped`):

```sh
ubit get -q 720 --no-library --json -o /tmp/ubit-out "<url>"
```

### 3. Extract Only a Specific Time Window (`--section`)

Never download a multi-gigabyte video when only a short segment is needed. `--section` uses MP4 `sidx` HTTP byte-range planning to fetch only the `init` box and overlapping segment bytes, trimmed on the preceding sync keyframe:

```sh
ubit get -q 720 --section 1:30-2:00 --no-library --quiet -o /tmp/ubit-out "<url>"
```

### 4. Produce Clean 16-bit 44.1 kHz WAV for ASR / Audio Analysis (Zero FFmpeg)

`ubit` converts directly to `.wav`, `.aiff`, `.flac`, `.m4a`, and `.mov` via native macOS `AudioToolbox`/`AVFoundation`:

```sh
WAV_FILE="$(ubit get -a --to wav --no-library --quiet -o /tmp/ubit-out "<url>")"
```

### 5. Search YouTube Directly Without an API Key

```sh
ubit info --json "ytsearch:blender open movie"
```

### 6. Handle Auth-Gated Links & Resume

- **Provider refusals**: HTTP 401, 403, 407, 410, 429 or 451, or a YouTube playability or verification challenge, ends that URL's operation, also for optional requests such as cover art or subtitles. `ubit` does not retry with another URL, client identity or route. Do not retry that URL with another identity or route yourself. A request that fails before `ubit` reads its status is repeated only when the request provably never reached the server; a timeout gives a "No HTTP status" error with no repeat. A refusal that sends only headers ends after the 30 s request timeout.
- **YouTube notices**: Only three visible watch-page sentences stop extraction: "Sign in to confirm you're not a bot", "Sign in to confirm your age" and "Our systems have detected unusual traffic from your computer network". A reCAPTCHA widget or a redirect to a Google challenge, sign-in or consent page also stops it. `docs/agents.md` has the exact rule.
- YouTube video extraction does not accept a raw `Cookie` header. This applies even with `--no-cookies`.
- **Cookies**: `ubit` uses `~/Library/Application Support/uBit/cookies.txt` by default (shared with `ubit browse`), or pass `--cookies-from-browser safari`, `--cookies-from-browser firefox`, `--cookies /path/to/cookies.txt`, or `--no-cookies`. Chrome/Brave/Edge are refused with an explicit error (keychain + AES unwrap not implemented). Cookies authenticate ordinary requests; they do not justify a retry after a refusal or challenge.
- **YouTube pacing**: Each process grants permits for `/player` attempts at least 3 seconds apart. This interval applies to permits, not HTTP starts.
- **Proxy values**: A `--proxy` value must be an `http://`, `https://`, `socks5://`, `socks5h://` or `socks://` URL with a host (all socks schemes use SOCKS version 5); any other value exits with code `2`, and the error does not repeat the value.
- **Sandbox Isolation**: Set `UBIT_CONFIG_DIR=/tmp/agent-ubit-$$` when running parallel workers.
- **Exit Codes**: `0` = done, `1` = download/extractor error (including a provider refusal or challenge), `2` = bad CLI flags, `130` = interrupted (`.part` + `.part.json` saved; re-running the identical command resumes at byte-level).
