# Using `ubit` from AI Agents & Automated Pipelines

`ubit` is designed as a deterministic, zero-paywall media acquisition and clip-extraction tool for autonomous agents, scripts, multimodal VLM workflows, and ASR pipelines.

A single 1.6 MB native macOS `arm64` binary (`ubit`) handles extraction across 35+ sites, multi-connection work-stealing HTTP `Range` downloads, HLS/DASH segment assembly, `sidx` byte-range clip trimming, ISO-BMFF MP4/M4A muxing, and `AudioToolbox`/`AVFoundation` WAV/FLAC/MOV conversion — with **no Python, no `yt-dlp`, and no `ffmpeg` required** for standard containers.

## Platform scope

The section and YouTube access rules below apply to the macOS Swift client. Linux, Android, WASM and the Rust SDK use a separate C++ engine. On Linux arm64, that engine returned success for a truncated indexed MP4 and saved the wrong interval from an HLS playlist. Check the decoded frames before relying on a clip from that engine.

---

## 1. Quick Discovery (`--llms`)

Any agent can query the installed binary directly for its machine-readable contract:

```sh
ubit --llms
```

Install the agent skill directly into Claude Code, Codex, OMP, or `.agents`:

```sh
npx skills add https://github.com/ayooooo123/ubit
```

---

## 2. Non-Interactive Invocation Patterns for Agents

Always pass `--no-library` for temporary/scratch agent tasks so ephemeral downloads do not clutter the user's GUI history, or set `UBIT_CONFIG_DIR` to isolate state completely.

### Pattern A: One-Shot Path Capture (`--quiet`)
Prints **only** the final absolute path(s) on `stdout` (one path per line) and exits `0`:

```sh
VIDEO_PATH="$(ubit get -q 720 --no-library --quiet -o /tmp/work 'https://www.youtube.com/watch?v=aqz-KE-bpKQ')"
```

### Pattern B: Fast Byte-Range Clip Extraction (`--section`) for Multimodal / VLM Inspection
On the native macOS Swift CLI, `ubit` trims tracks on the native MP4 path before any output conversion. Video starts on the preceding sync keyframe. An M4A input can therefore produce a trimmed WAV, while converting raw MP3 input to M4A does not trim it.

On the native macOS Swift CLI, for indexed MP4/M4A input, `ubit` requests the start of the file through the index (at least 32 KiB, or 64 KiB if the position is unknown). It takes the initialization data from that response and requests the overlapping media bytes. When the first response names a strong ETag, the media request goes to the URL that answered, with `If-Match`, and must return the same edition. Without a strong ETag, two requests can return two different files, so the index, the initialization data and the media must come from one response. When the first response does not reach the end of the clip, `ubit` requests the file again from byte 0 to the end of the clip, and that response must repeat the bytes of the first one. When the end of the file showed that no media follows the index, that response must also report the same file size. A changed or longer file makes the command fail without saving a clip. If a section extends beyond the index, `ubit` checks whether further media can follow. When the references reach the known file end or leave only a single recognized random-access or padding box, it needs no further media bytes to reject a section outside the stream. Otherwise it can fetch the whole file, for example to trim a later fragment. The downloaded file must contain the bytes that the index references, even when the first response did not give the total file size. Without a usable index, or for DASH, the transfer can also include the whole stream. If the server ignores byte ranges, it can send the whole file for each request.

For an indexed MP4 or M4A clip, the selected samples must cover the interval that each index reference declares. Padding cannot stand in for the second half of a reference. If the client downloads the whole file, it checks every top-level segment index, including those after the requested clip. A reference to padding or missing bytes causes the command to fail without saving the clip.

If an indexed fragment has reordered pictures and variable decode durations, the Swift client can fetch the whole file. It uses the next fragment to establish the boundary between displayed pictures. A decode duration is not a display duration.

The Swift muxer can copy or shorten a track with a single normal-speed edit. A frame that the player needs for decoding can remain in the file without being displayed. A video picture is displayed until the next presentation time in the track, not until the end of its decode duration, so a section end cannot display a picture that the clip keeps only for decoding. Reopening the clip does not extend its displayed interval. The muxer rejects multiple edits and nonstandard playback rates rather than silently changing their timeline.

For an explicit HLS byte range, both the initialization data and the media must include every requested byte. An early end of file is an error, even if the server returns HTTP 200 or 206. When a playlist uses one URI more than once, every read of that URI must come from one edition. If every use reads the whole object, the client keeps a SHA-256 digest of the first read, and a later read with other bytes stops the download without a clip. If at least one use is a byte range, an edition is the URL that answered the first read, after redirects, together with its strong ETag. Later reads go to that URL with `If-Match`, and each answer must come from that URL with the same strong ETag. The same ETag text from a different redirect target is a different edition. Without a strong ETag, the client takes every read from one complete copy of the object. A live recording keeps complete copies only for byte ranges, and only up to 64 MiB in total. A single copy larger than 64 MiB is released after it gives its range. After a whole read, and after a copy leaves the playlist or the 64 MiB limit, the recording keeps only a SHA-256 digest of the object. A later read of that URI downloads a new complete copy, and the recording stops when the digest differs.

On that path, for HLS, at least one segment must contain media inside the requested interval. A section that starts at or beyond the end of the playlist fails without fetching a media segment. At an exact segment boundary, `ubit` also keeps the previous segment, if present, for keyframe preroll. WebM and raw MP3, Opus, FLAC or WAV do not go through the MP4 trimmer: `ubit` saves the whole file over plain HTTP, or the selected segments over HLS.

```sh
ubit get -q 720 --section 1:15-1:30 --no-library --quiet -o /tmp/clips "$URL"
```

### Pattern C: Zero-FFmpeg 16-bit PCM WAV Extraction for Whisper / ASR
Extracts audio only and converts directly to `pcm_s16le` 44.1 kHz stereo `.wav` via macOS `AudioToolbox` (zero external dependencies):

```sh
AUDIO_WAV="$(ubit get -a --to wav --section 0:00-5:00 --no-library --quiet -o /tmp/asr "$URL")"
```

### Pattern D: Structured Metadata & Subtitle Probe (`ubit info --json`)
Inspect available qualities, codecs, byte sizes, durations, chapters, playlist items, and subtitle tracks without saving a media file. Extraction can still request stream bytes, and a server that ignores byte ranges sends the whole response. Such a response does not prove that the provider authorized access, and `ubit` does not claim that a provider verification check was completed:

```sh
ubit info --json "$URL"
```

`ubit info` and `ubit formats` accept only `--json`, `--cookies FILE`, `--cookies-from-browser B`, `--no-cookies` and `--proxy URL`. Any other flag exits with code `2`.

Top-level JSON fields returned by `ubit info --json`:

| Field | Type | Description |
| --- | --- | --- |
| `id` | `string` | Canonical platform media/playlist ID |
| `title` | `string` | Decoded media or playlist title |
| `site` | `string` | Extractor name (`"YouTube"`, `"SoundCloud"`, `"X"`, etc.) |
| `webpageURL` | `string` | Canonical source page URL |
| `author` | `string?` | Uploader / channel / artist |
| `uploadDate` | `string?` | ISO date `YYYY-MM-DD` when available |
| `duration` | `number?` | Duration in seconds |
| `isLive` | ` boolean` | `true` for active live streams |
| `isDRM` | `boolean` | `true` when streams are Widevine/FairPlay CENC encrypted |
| `formats` | `MediaFormat[]` | Available video/audio streams (`id`, `ext`, `proto`, `vcodec`, `acodec`, `width`, `height`, `fps`, `bitrate`, `filesize`) |
| `subtitles` | `SubtitleTrack[]` | Available caption tracks (`lang`, `name`, `url`, `ext`, `isAutoGenerated`) |
| `chapters` | `Chapter[]` | Timestamped chapters (`title`, `startTime`, `endTime`) |
| `entries` | `PlaylistEntry[]` | Non-empty for playlists, channels, showcases, sets, and search results |

---

## 3. Streaming NDJSON Event Protocol (`ubit get --json`)

When `--json` is passed to `ubit get`, `stdout` emits strictly valid newline-delimited JSON (one event object per line, sorted keys, no ANSI escape codes):

```json
{"event":"start","url":"https://www.youtube.com/watch?v=aqz-KE-bpKQ"}
{"event":"info","ext":"mp4","live":false,"path":"/tmp/Big Buck Bunny.mp4","quality":"720p60","site":"YouTube","title":"Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film"}
{"event":"progress","downloaded":1835008,"eta":1,"fraction":0.494,"speed":3145728,"total":3716952}
{"event":"process","stage":"Merging"}
{"event":"done","path":"/tmp/Big Buck Bunny.mp4","seconds":2.41,"size":3716952}
```

### Event Types

| `event` | Emitted When | Payload Fields |
| --- | --- | --- |
| `start` | Extraction begins for a URL | `url` |
| `info` | Extractor & format selector resolved | `title`, `site`, `quality`, `ext`, `path`, `live` |
| `progress` | Bytes or segments arrive (~8 Hz max) | `fraction` (`0.0–1.0`), `downloaded`, `total`, `speed` (B/s), optional `eta` (s), optional `live` + `seconds` |
| `process` | Post-download stage begins | `stage` (`"Removing sponsors"`, `"Merging"`, `"Converting to WAV"`, etc.) |
| `stopping` | First `SIGINT` received on a live stream | *(none — live recording is finalizing into a playable MP4)* |
| `done` | Output file atomically committed | `path`, `size` (bytes), `seconds` (wall time) |
| `stopped` | Download paused/interrupted (`SIGINT`) | `url` (`.part` + `.part.json` preserved for resume) |
| `error` | Recoverable or terminal failure | `url`, `error` (human-readable message) |

---

## 4. Exit Codes & Resumability

| Exit Code | Meaning | Agent Action |
| ---: | --- | --- |
| `0` | All URLs succeeded | Read output path from `done.path` or `--quiet` stdout |
| `1` | Extraction, auth, DRM, network, provider refusal, or challenge error | Inspect `error`. A provider refusal or challenge is terminal for that URL: do not retry with another identity or route. For ordinary auth-gated content, pass `--cookies` / `--cookies-from-browser firefox` or ask the user to sign in via `ubit browse <url>` |
| `2` | Invalid CLI usage / flag syntax | Fix invocation flags (check `ubit get --help`) |
| `130` | Interrupted (`SIGINT`) | Run the same command again. The Swift client resumes HTTP media only when the URL, the URL that answered after redirects, and its strong ETag match the saved partial file. Otherwise it starts from byte zero. Without a strong ETag it also uses one HTTP connection, even when `--connections` is larger. With several connections, every range goes to the URL that answered the first request. |

---

## 5. Sandbox Isolation & Authentication

- **Isolated Agent State (`UBIT_CONFIG_DIR`)**:
  Set `UBIT_CONFIG_DIR=/tmp/my-agent-ubit` so concurrent agent workers never contend on `library.json` or `settings.json`.
- **Authenticated / Age-Gated Sites**:
  1. Default (`--cookies builtin`): reads `~/Library/Application Support/uBit/cookies.txt`, automatically populated whenever the user signs into a site inside `ubit browse <url>` (`⌘B`).
  2. Firefox SQLite (`--cookies-from-browser firefox`): copies and queries the active Firefox profile's `cookies.sqlite` read-only.
  2b. Safari (`--cookies-from-browser safari`): reads `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies` (falling back to `~/Library/Cookies`). The file is unencrypted, so no keychain access is needed. Chrome/Brave/Edge are rejected with an explicit error: their cookie values need the browser's keychain password and an AES unwrap.
  3. Explicit Netscape Cookie File (`--cookies /path/to/cookies.txt`).
  4. Cookie-free (`--no-cookies`): forces unauthenticated extraction.
- **YouTube Request Pacing & Challenges**:
  In one `ubit` process, the pacer grants permission for one YouTube `/player` attempt at a time, at least 3 seconds after the previous grant. Retries need a permit too. A caller can pause after it gets permission, so two HTTP requests can start less than 3 seconds apart.

  The process caches a video's metadata for 5.5 hours per request context: the cookies for `/watch` and `/player`, the User-Agent, extra headers and the proxy. Separate processes do not share the pacer or the cache. When YouTube returns a playability or verification challenge, such as "confirm you're not a bot", extraction stops at once with exit code `1` and an error that names the challenge. This stop applies whether or not a sign-in cookie is loaded. `ubit` does not complete the challenge, switch to another client profile or `User-Agent`, invalidate the cache to re-extract the URL, or try another route. Sign-in cookies still authenticate ordinary requests that YouTube allows; they do not turn a refusal or challenge into a retry. Do not retry that URL in a loop.
  A notice on the watch page counts only when a reader can see it. Text in a script, a comment, an attribute, the page title or a hidden element (`hidden`, `aria-hidden="true"`, `display:none`, a closed `<dialog>`, the body of a closed `<details>`) is not a notice. The `<summary>` of a closed `<details>` is visible. A notice is an instruction with the verb "verify" or "confirm" whose object is the reader's age or identity or a statement that the reader is human (for example "verify your age", "confirm your identity" or "verify that you are human"), or a statement that playback is blocked. The object must end there: after it comes the end of the text, a punctuation mark or a word such as "to" or "before". So "verify your agent settings", "confirm your identity provider settings" and "verify the cable is not a bottleneck" are not notices, and text that only explains verification is not a notice. A visible reCAPTCHA widget is a challenge.
- **Provider refusals:** For a media or extraction request, HTTP 403 (access denied), 410 (gone), 429 (rate limited), or a playability or verification challenge ends that URL's operation. On macOS, URLSession can hold a response until some of its body arrives, and how much body it needs is not documented. From the moment URLSession hands the response to `ubit`, the status decides: `ubit` does not wait for the rest of a refused body, so a body that stalls or breaks off cannot cause another request. When a request fails before `ubit` can read its status, `ubit` repeats it only when the task metrics prove that no response had started, for example a connection that is lost before the response headers. Otherwise it reports "No HTTP status" (exit 1) and does not repeat the request, because the response may have been a refusal; this can take until the request timeout of 30 s. In one operation, a request starts only when no other request of that operation waits for its status, so no request starts after a refusal that `ubit` has not read yet; bodies with a known status still arrive in parallel. `ubit` makes no further request for that URL, does not refresh a stale URL, does not switch client identity, and does not try another route. It saves no output for that URL, and it deletes the `.part` and `.part.json` files of a download that was refused or whose status is unknown. A successful byte-range response or an HTTP status from one request is not proof that a provider verification check passed. After a 2xx status, a body that breaks off because of a network error keeps its ordinary retry.
- **YouTube format selection:** Extraction may try more than one client profile for ordinary format selection. A refusal or challenge is not a format-selection failure: it ends extraction instead of advancing to another profile or route. If no direct format is available, HLS requires player data from the watch page or from a profile that named a playlist without direct formats. `ubit` selects the first playlist URL named by a tried profile. It uses the watch-page URL only if no tried profile named one. If the selected URL is unreadable, `ubit` does not try another playlist. Without usable metadata and formats, no media download starts.
- **Cookie headers:** YouTube video extraction rejects an explicit `Cookie` header before the first request, even if the cookie vault is empty. The error does not repeat the value.
- **Proxy Values**: `--proxy` and the `proxy` setting accept only `http://`, `https://`, `socks5://`, `socks5h://` or `socks://` URLs with a host. Every socks scheme uses SOCKS version 5, so `socks4://` and `socks4a://` are refused. Any other value exits with code `2` (or fails the download, for a value that was already stored) before a request is sent, so a mistyped proxy never sends traffic directly. The error does not repeat the value, because a proxy URL can hold a password.
- **Unrecognized JS-Heavy Player Pages**:
  If static/API extraction fails on a custom video host for a reason other than a provider refusal or challenge, hand the URL to the built-in WebKit media-sniffer browser (`ubit browse <url>`), which hooks `fetch`, `XMLHttpRequest`, and `<video>` across all frames to capture dynamic HLS/DASH/MP4 URLs.
