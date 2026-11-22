# uBit (`ubit` / `uBit.app`)

Download video and audio from the web — a **~1 MB** native macOS desktop app and an **agent-ready CLI** for **macOS (`arm64`)** and **Linux (`x86_64` & `arm64`)**. No Python, no `yt-dlp`, no FFmpeg required for MP4/M4A, and zero Pro paywalls.

- **[Agent & Automation Docs (`docs/agents.md`)](docs/agents.md)** · **[Agent Skill (`skills/ubit/SKILL.md`)](skills/ubit/SKILL.md)** · **[`llms.txt`](llms.txt)** · **[Architecture (`AGENTS.md`)](AGENTS.md)**

**Platform scope.** The `--section` checks and provider-refusal rules in this document describe the native macOS `arm64` Swift CLI. The Linux, Termux/Android and WASM builds and the Rust SDK use a separate C++ engine. Its section path reads only the first segment index, does not check later indexes, and does not preserve the same HLS trim base. It can save a short or shifted clip and exit `0`. Check a non-macOS clip before you rely on its interval. The C++ engine's refusal behavior is not covered by the macOS contract.

---

## Install (macOS Apple Silicon + Linux `x86_64` & `arm64` + Termux / Android `arm64`)

```sh
curl -fsSL https://github.com/ayooooo123/ubit/releases/latest/download/install.sh | sh
```

Or install the skill directly into Claude Code, Codex, OMP, or `.agents`:

```sh
npx skills add https://github.com/ayooooo123/ubit
```

---

## Size & Capability Comparison vs. Downbit 0.2.4

| Metric / Capability | Downbit 0.2.4 | uBit 0.3.1 |
| --- | ---: | ---: |
| macOS `arm64` executable / `.tar.gz` | 17.45 MB / 8.06 MB | **1.62 MB / 869 KB (9.3× smaller)** |
| Linux `x86_64` (`amd64`) binary / `.tar.gz` | ~18 MB / 8.20 MB | **952 KB / 391 KB (20.9× smaller)** |
| Linux `arm64` (`aarch64`) binary / `.tar.gz` | ~17 MB / 7.50 MB | **915 KB / 375 KB (20.0× smaller)** |
| Termux / Android `arm64` Bionic / `.tar.gz` | *(Not supported)* | **935 KB / 381 KB (`libc.so` + `libm.so` + `libdl.so` only)** |
| Linux dynamic runtime linkage (`ldd`) | Go runtime + WebKitGTK | **`libc.so.6` + `libm.so.6` only (`dlopen` TLS/zlib)** |
| Embedded JS AST parser bloat | 158.5 KB (`yt-dlp/ejs`) | **0 B** |
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
ubit get -q 720 --section 0:30-1:00 --no-library --quiet <url> # 30s keyframe clip; sidx byte ranges when the stream has an index
ubit get -a --to wav --no-library --quiet <url>                # zero-FFmpeg 16-bit 44.1 kHz PCM WAV for ASR
ubit get --json <url>                                          # stream NDJSON events: start, info, progress, process, done
```

**Provider refusals.** On the native macOS Swift CLI, a provider access denial (HTTP 403), 410, 429, or a playability/verification challenge ends that URL's operation. uBit does not retry with another URL, client identity or route, and it saves no output for that URL. It does not claim that a provider verification check was completed. Sign-in cookies still authenticate ordinary requests; they do not justify a retry after a refusal.

This also applies to optional requests. For example, if X denies the syndication request, the Swift client reports that error without contacting a second service.

See **[`docs/agents.md`](docs/agents.md)** for full NDJSON schemas, exit codes (`0`, `1`, `2`, `130`), `UBIT_CONFIG_DIR` sandbox isolation, and authentication workflows.


### Embeddable SDKs (Rust, C & Bare/JS)

- **Rust SDK (`ubit` crate, root `Cargo.toml`)**: `ubit = { git = "https://github.com/ayooooo123/ubit" }` links the C++20 extractor and MP4/HLS/DASH/TS mux engine (`linux/src/engine.hpp`) behind `sdk/include/ubit.h`, driving all outbound sockets through `rustls` (`webpki-roots`) and `ubit::is_public_address` SSRF filtering with instant per-call socket cancellation (`ubit::CancelToken`) and zero OpenSSL/FFmpeg/subprocess dependencies.
- **Bare / JavaScript WASM SDK ([`bare-ubit`](https://github.com/ayooooo123/bare-ubit))**: runs `dist/ubit.wasm` inside a jailed WASI preview-1 `/config` + `/out` sandbox with the same IANA public-IP SSRF guard.
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

- **Dynamic Work-Stealing Range Downloader (`Sources/Engine/HTTPClient.swift`)**: Uses one connection when there is no strong ETag. Otherwise it can split a file across up to 32 conditional HTTP `Range` connections. It saves completed ranges in `.part.json` and resumes a `.part` file only when the same URL still has the same strong ETag, and dynamically bisects the slowest worker's remaining byte span when fast workers finish early.
- **Pure-Swift ISO-BMFF & MPEG-TS Muxer (`Sources/Mux/MP4Box.swift`, `TSDemuxer.swift`)**:
  - Reads progressive MP4 (`stbl`), fragmented DASH/HLS fMP4 (`moof`/`traf`/`trun`), and 188-byte MPEG-TS (`PAT`/`PMT`/`PES` H.264 Annex-B + ADTS AAC).
  - Writes fast-start (`moov` before `mdat`) MP4 and M4A containers with `tx3g` timed-text subtitles, QuickTime `chap` + Nero `chpl` chapters, iTunes metadata (`©nam`, `©ART`, `©day`, `©cmt`, `desc`, `covr` JPEG cover art), and macOS Finder `com.apple.metadata:kMDItemWhereFroms`.
  - On the native macOS Swift build, for indexed MP4/M4A, `--section` reads initialization data and the `sidx` index from the start of the file, then requests the overlapping media bytes. This saves transfer only if the server honors byte ranges. Before it saves a trimmed whole-file clip, it checks each top-level index against the file length. HLS uses the overlapping segments and, at an exact start boundary, the previous segment for preroll. A section starting at the end of a playlist has no media and fails. WebM and raw MP3, Opus, FLAC or WAV are not trimmed: uBit saves the entire HTTP file or the selected HLS segments.
- **Built-in Media-Sniffer Browser (`Sources/UI/BrowserWindow.swift`)**: `WKWebView` (`⌘B`) with document-start `fetch` / `XMLHttpRequest` / `<video>` inspection across all frames, `WKContentRuleList` ad/tracker blocking, and automatic cookie export to `~/Library/Application Support/uBit/cookies.txt`.

## Build from Source

```sh
./build.sh
```

Produces `dist/uBit.app`, `dist/ubit`, and `dist/ubit-0.3.3-darwin-arm64.tar.gz`.

## License

MIT
