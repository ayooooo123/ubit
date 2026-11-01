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

### 1. Probe Metadata, Formats & Subtitles First (Zero Media Bytes Downloaded)

```sh
ubit info --json "<url>"
```

- Check `isDRM` (`true` means Widevine/FairPlay encrypted — report immediately rather than retrying).
- Check `entries` (non-empty for playlists, channels, sets, or `ytsearch:<query>` searches).
- Check `subtitles` for human or ASR caption tracks (`--subs --sub-langs en --sub-files` downloads `.vtt` sidecars).

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

- **Cookies**: `ubit` uses `~/Library/Application Support/uBit/cookies.txt` by default (shared with `ubit browse`), or pass `--cookies-from-browser firefox`, `--cookies /path/to/cookies.txt`, or `--no-cookies`.
- **Sandbox Isolation**: Set `UBIT_CONFIG_DIR=/tmp/agent-ubit-$$` when running parallel workers.
- **Exit Codes**: `0` = done, `1` = download/extractor error, `2` = bad CLI flags, `130` = interrupted (`.part` + `.part.json` saved; re-running the identical command resumes at byte-level).
