# uBit (`ubit` / `uBit.app`)

Download video and audio from the web — a **1.6 MB** native macOS app and an **agent-ready CLI** in one pure-Swift binary. No Python, no `yt-dlp`, no FFmpeg required, and zero Pro paywalls.

- **[Agent & Automation Docs (`docs/agents.md`)](docs/agents.md)** · **[Agent Skill (`skills/ubit/SKILL.md`)](skills/ubit/SKILL.md)** · **[`llms.txt`](llms.txt)** · **[Architecture (`AGENTS.md`)](AGENTS.md)**

---

## Install (macOS Apple Silicon)

```sh
curl -fsSL https://github.com/ayooooo123/ubit/releases/latest/download/install.sh | sh
```

Or install the skill directly into Claude Code, Codex, OMP, or `.agents`:

```sh
npx skills add https://github.com/ayooooo123/ubit
```

---

## Size & Capability Comparison vs. Downbit 0.2.4 (`arm64`)

| Metric / Capability | Downbit 0.2.4 (`arm64`) | uBit 0.3.0 (`arm64`) |
| --- | ---: | ---: |
| Main executable (`Contents/MacOS/*`) | 17,450,944 B (17.45 MB) | **1,615,360 B (1.62 MB — 10.8× smaller)** |
| Unpacked `.app` bundle | 18.02 MB | **1.60 MiB (11.2× smaller)** |
| Release `.tar.gz` archive | 8,055,425 B (8.06 MB) | **~883 KB (9.1× smaller)** |
| Embedded JS AST parser bloat | 158.5 KB (`yt-dlp/ejs`) | **0 B (native `JavaScriptCore`)** |
| App icon (`AppIcon.icns`) | 947 KB | **60 KB (programmatic vector)** |
| CLI downloading (`get`) | $19 Pro paywall | **Free & unlocked** |
| Max concurrent downloads / connections | 2 / 4 (Free), 8 / 16 (Pro) | **16 / 32 + dynamic work-stealing** |
| Keyframe section trimming (`--section`) | $19 Pro paywall | **Free (`sidx` byte-range fast cut)** |
| SponsorBlock remove / chapters | $19 Pro paywall | **Free (k-anonymous SHA-256 prefix API)** |
| Channel & playlist subscriptions | $19 Pro paywall | **Free (`ubit subs` + UI tab)** |
| Native zero-FFmpeg conversion | MP4 & M4A only | **MP4, M4A, MOV, WAV, AIFF, FLAC** |
| Built-in site extractors | 31 | **35 (+ Mastodon, GitHub, Coub, 9GAG)** |
| Browser cookie import | Built-in WebView or file | **Built-in WebView, Firefox SQLite, Netscape file** |

---

## For AI Agents & Scripts

Every command supports `--json`, and `ubit --llms` prints the complete machine-readable contract directly from the binary:

```sh
ubit --llms                                                    # full agent CLI + NDJSON schema
ubit info --json "https://www.youtube.com/watch?v=aqz-KE-bpKQ" # probe formats, subs, chapters
ubit get -q 720 --section 0:30-1:00 --no-library --quiet <url> # fetch 30s keyframe clip via sidx byte ranges
ubit get -a --to wav --no-library --quiet <url>                # zero-FFmpeg 16-bit 44.1 kHz PCM WAV for ASR
ubit get --json <url>                                          # stream NDJSON events: start, info, progress, process, done
```

See **[`docs/agents.md`](docs/agents.md)** for full NDJSON schemas, exit codes (`0`, `1`, `2`, `130`), `UBIT_CONFIG_DIR` sandbox isolation, and authentication workflows.

---

## Interactive CLI Usage

```sh
ubit                                    # open the native macOS app
ubit <url>                              # download with shared app settings
ubit get -a <url>                       # audio only (M4A with cover art & tags)
ubit get -q 1080 -o ~/Movies <url>      # up to 1080p into ~/Movies
ubit get --sponsors-remove default <url># cut SponsorBlock segments at keyframes
ubit formats <url>                      # list stream IDs for -f 299+140
ubit list                               # show app + CLI download library
ubit subs add <channel-or-playlist-url> # subscribe to new uploads
ubit open <url>                         # enqueue in the running GUI app
ubit browse <url>                       # open in the WebKit media-sniffer browser
```

---

## Engine Highlights

- **Dynamic Work-Stealing Range Downloader (`Sources/Engine/HTTPClient.swift`)**: Splits files across up to 32 parallel HTTP `Range` connections, persists `.part` + `.part.json` byte maps for instant Ctrl-C/crash resume, and dynamically bisects the slowest worker's remaining byte span when fast workers finish early.
- **Pure-Swift ISO-BMFF & MPEG-TS Muxer (`Sources/Mux/MP4Box.swift`, `TSDemuxer.swift`)**:
  - Reads progressive MP4 (`stbl`), fragmented DASH/HLS fMP4 (`moof`/`traf`/`trun`), and 188-byte MPEG-TS (`PAT`/`PMT`/`PES` H.264 Annex-B + ADTS AAC).
  - Writes fast-start (`moov` before `mdat`) MP4 and M4A containers with `tx3g` timed-text subtitles, QuickTime `chap` + Nero `chpl` chapters, iTunes metadata (`©nam`, `©ART`, `©day`, `©cmt`, `desc`, `covr` JPEG cover art), and macOS Finder `com.apple.metadata:kMDItemWhereFroms`.
  - Uses `sidx` Segment Index boxes so `--section start-end` fetches only the `init` box and overlapping segment byte ranges.
- **Built-in Media-Sniffer Browser (`Sources/UI/BrowserWindow.swift`)**: `WKWebView` (`⌘B`) with document-start `fetch` / `XMLHttpRequest` / `<video>` inspection across all frames, `WKContentRuleList` ad/tracker blocking, and automatic cookie export to `~/Library/Application Support/uBit/cookies.txt`.

## Build from Source

```sh
./build.sh
```

Produces `dist/uBit.app`, `dist/ubit`, and `dist/ubit-0.3.0-darwin-arm64.tar.gz`.

## License

MIT
