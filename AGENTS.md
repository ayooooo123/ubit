# uBit Development Guide (`AGENTS.md`)

`uBit` is an ultra-small (~1.6 MB binary, ~862 KB `.tar.gz`), zero-dependency native macOS (`arm64`) video/audio downloader app and CLI written in pure Swift. One executable (`uBit.app/Contents/MacOS/ubit`) serves both as the native `AppKit`/`SwiftUI`/`WebKit` desktop app (when launched with no arguments) and as the script/agent CLI (when invoked with arguments).

## Layout

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | Dual-mode entry point: dispatches to `CLIRunner` when arguments are passed (ignoring macOS `-psn_*`/`-NS*` launch flags), otherwise starts `NSApplication` with `UBitAppDelegate` |
| `Sources/Core/Models.swift` | Core types (`MediaInfo`, `MediaFormat`, `SubtitleTrack`, `Chapter`, `PlaylistEntry`, `Settings`, `LibraryItem`, `Subscription`, `SectionRange`, `AppPaths`, filename template sanitizer) |
| `Sources/Core/Cookies.swift` | `CookieVault`: Netscape `cookies.txt` parser/writer, read-only Firefox `cookies.sqlite` importer (`libsqlite3`), Safari `Cookies.binarycookies` reader (`SafariBinaryCookies`), and `WKHTTPCookieStore` exporter; Chromium-family names throw `CookieError.browserNotSupported` |
| `Sources/Core/QueueAndSubs.swift` | Thread-safe `LibraryStore`, `SubscriptionStore`, `@MainActor QueueManager`, `IOKit` idle-sleep assertion (`IOPMAssertionCreateWithName`), Dock progress badge, and `AF_UNIX` socket IPC (`LocalIPC`) |
| `Sources/Engine/HTTPClient.swift` | Ephemeral `URLSession` client (SOCKS5/HTTP proxy, token-bucket `RateLimiter`, retry/backoff) and `WorkStealingQueue` multi-connection HTTP `Range` downloader (`pwrite` into `.part` + `.part.json`) |
| `Sources/Engine/HLS.swift` | Master & media M3U8 parser (`#EXT-X-STREAM-INF`, `#EXT-X-MEDIA` separate audio renditions, `#EXT-X-MAP`, `#EXT-X-BYTERANGE`, `CommonCrypto` `AES-128-CBC` decryption, parallel segment worker pool, live HLS recorder) |
| `Sources/Engine/DASH.swift` | MPEG-DASH `.mpd` XML parser (`AdaptationSet`, `Representation`, `SegmentTemplate` `$Number$`/`$Time$`, `SegmentTimeline`), parallel segment fetcher |
| `Sources/Mux/MP4Box.swift` | Zero-dependency ISO-BMFF reader/writer: parses `stbl` + fragmented `moof`/`traf`/`trun` + `sidx`, plans byte-range sections, trims at sync keyframes, excises SponsorBlock sample intervals, builds `tx3g` subtitle & `chap`/`chpl` chapter tracks, writes `ilst` metadata (`©nam`, `©ART`, `©day`, `©cmt`, `desc`, `covr`), and emits fast-start MP4/M4A (`ftyp` + `moov` + `mdat`) |
| `Sources/Mux/TSDemuxer.swift` | Pure-Swift 188-byte MPEG-TS (`PAT`/`PMT`/`PES`) demuxer converting Annex-B H.264 (`SPS`/`PPS` → `avcC`) and ADTS AAC (`esds`) into `MP4Track`s |
| `Sources/Engine/SponsorBlock.swift` | Privacy-preserving 4-hex SHA-256 prefix SponsorBlock client, description chapter parser, WebVTT/SRT/XML subtitle parser, and timeline squeezer |
| `Sources/Engine/Converter.swift` | Native `AVFoundation`/`AudioToolbox` converter (`mov`, `m4a`, `wav`, `aiff`, `flac`), `ImageIO` baseline JPEG cover normalizer, `com.apple.metadata:kMDItemWhereFroms` binary plist `setxattr`, Music/TV AppleScript importer, and optional system `ffmpeg` passthrough (`mp3`, `opus`, `mkv`, `webm`) |
| `Sources/Engine/DownloadEngine.swift` | Full download pipeline (`FormatSelector`, `sidx` fast section fetch, provider-refusal handling: HTTP 403, 410, 429 or a playability challenge ends the operation; no stale refresh, identity fallback or route fallback; muxing, sidecars, `DownloadEventPayload` emission) |
| `Sources/Extractors/Extractor.swift` | `SiteExtractor` protocol, `ExtractorRegistry` (35 extractors + direct URLs + `ytsearch:`), balanced-JSON/HTML utilities, and `GenericExtractor` (OpenGraph, JSON-LD, `<video>`, inline `.m3u8`/`.mpd`) |
| `Sources/Extractors/YouTubeExtractor.swift` | Multi-client InnerTube (visionOS, TV, iOS and web player profiles; web playlists, channels and search), `SAPISIDHASH` cookie auth (from the `SAPISID` that the request sends, chosen by `CookieVault.effectiveCookies`), `JavaScriptCore` `base.js` cipher solver, and `YTGuard` (persisted visitor ID, 5.5 h metadata cache keyed by video and request context (cookies for `/watch` and `/player`, User-Agent, extra headers, proxy), permits at least 3 s apart for `/player` attempts including retries, no minimum gap between HTTP starts, and a provider challenge stop that tries no other client identity or route) |
| `Sources/Extractors/SitesA.swift` | Vimeo (+ showcases), SoundCloud (dynamic `client_id` + sets/artists), Bilibili (BV/av/multi-part), Twitch (GQL live/VOD/clip), Kick, Reddit (`v.redd.it` + embed fallback), X/Twitter (syndication token + `api.vxtwitter.com` fallback) |
| `Sources/Extractors/SitesB.swift` | Bluesky (ATProto), TikTok, Instagram, Facebook, Threads, Bandcamp, Mixcloud, Dailymotion, Rumble, Odysee, PeerTube, Internet Archive, Streamable, Loom, TED, Imgur, Tumblr, Pinterest, VK, Douyin, Kuaishou, Weibo, Xiaohongshu, GitHub, Mastodon, Coub, 9GAG |
| `Sources/CLI/CLI.swift` | Complete CLI (`get`, `info`, `formats`, `list`, `subs`, `settings`, `sites`, `open`, `browse`, `version`, `--llms`) with NDJSON streaming, ANSI progress bar, and two-stage `SIGINT` handler |
| `Sources/UI/MainWindow.swift` | Native dark-onyx `AppKit` + `SwiftUI` main window, live link preview card, grayscale-to-vivid progress artwork (`ColorFillArtworkView`), `QLPreviewPanel` Quick Look, Settings window, Menu Bar item |
| `Sources/UI/BrowserWindow.swift` | `WKWebView` built-in browser (`⌘B`) with document-start `fetch`/`XHR`/media element sniffer across all frames, `WKContentRuleList` adblocker, and automatic cookie export |
| `build.sh` | Compiles `arm64-apple-macos14.0` with `-Osize -whole-module-optimization -gnone -Xlinker -dead_strip`, strips non-global symbols, generates programmatic `AppIcon.icns`, ad-hoc signs `dist/uBit.app`, and packs `dist/ubit-0.3.3-darwin-arm64.tar.gz` |
| `tests/swift/run.sh` | Builds `tests/swift/RegressionChecks.swift` with the app sources and runs each Swift regression case in its own process against a local `URLProtocol` fixture (no network) |
| `tests/home-paths.sh` | Fails when a binary or rlib holds the home-directory path of the machine that built it; CI runs it on the macOS, Linux and Android binaries and on the SDK rlibs |
| `sdk/cargo.sh` | Runs `cargo` with `--remap-path-prefix` (rustc) and `-ffile-prefix-map` plus `-fdebug-prefix-map` (C/C++ and the assembler; gcc before 12 needs the second for ring's `.S` files) for `$HOME` and the checkout, so that uBit and its dependencies build without home-directory paths |

## Architectural Rules & Invariants

1. **Zero Third-Party Dependencies**: Link only macOS system frameworks (`AppKit`, `SwiftUI`, `WebKit`, `JavaScriptCore`, `AVFoundation`, `AudioToolbox`, `QuickLookUI`, `IOKit`, `ImageIO`, `UniformTypeIdentifiers`, `CryptoKit`, `CommonCrypto`, `libsqlite3`). Keep the stripped `arm64` binary under 2 MB and the `.tar.gz` under 1 MB.
2. **Two-Pass `co64` Fast-Start MP4 Invariant**: `MP4Muxer.buildMoov` always emits 64-bit `co64` chunk offsets so pass 1 (`chunkBaseOffset = 0`) and pass 2 (`chunkBaseOffset = ftyp + moov + mdatHeader`) have identical byte lengths. Never switch pass 2 between `stco` and `co64` dynamically or sample offsets will drift.
3. **4-Byte Raw iTunes `ilst` Atoms**: QuickTime/iTunes metadata tags (`©nam`, `©ART`, `©day`, `©cmt`) start with byte `0xA9` (ISO-8859-1 `©`), NOT 2-byte UTF-8 `0xC2 0xA9`. Always write them via `BinaryBuffer.boxRaw([0xA9, ...])`.
4. **Pure Swift CLI Formatting**: Never pass Swift `String` values to C `%s` in `String(format:)`; use pure Swift string interpolation and `pad(_:_:)`.
5. **CLI Machine Contract Compatibility**: Keep NDJSON event names (`start`, `info`, `progress`, `process`, `stopping`, `done`, `stopped`, `error`) and exit codes (`0`, `1`, `2`, `130`) stable; update `ubit --llms`, `docs/agents.md`, and `skills/ubit/SKILL.md` together whenever CLI flags or JSON fields change.
6. **Terminal Provider Refusals (macOS Swift CLI)**: An HTTP 403 (access denied), 410, 429 or a playability or verification challenge ends that URL's operation. Do not add a retry with a different URL, client identity or route after a refusal. Do not present a byte-range probe as a completed provider verification. Sign-in cookies remain valid for ordinary authenticated requests.
7. **Platform Scope**: The invariants above describe the Swift macOS app and CLI. `linux/src/` is a separate C++ engine for the Linux, Termux/Android and WASM builds and the Rust SDK. Its section path reads only the first segment index, does not check later indexes, and does not preserve the same HLS trim base. Do not copy macOS section or refusal guarantees into the C++ engine docs, and do not report a non-Swift clip as verified without a separate check.

## Build & E2E Verification Commands

```sh
# Build stripped release app bundle + CLI symlink + .tar.gz archive
./build.sh

# Verify agent manifest & extractor registry
./dist/ubit --llms
./dist/ubit sites --json

# Offline Swift regression checks (YouTube pacing/cache/sign-in, provider refusals, proxy values, Safari cookies)
./tests/swift/run.sh

# No home-directory path in the shipped binary
./tests/home-paths.sh dist/uBit.app/Contents/MacOS/ubit

# Live E2E: sidx byte-range clip download + native ISO-BMFF MP4 mux + metadata
UBIT_CONFIG_DIR=/tmp/ubit-e2e ./dist/ubit get -q 720 --section 0:05-0:15 --no-library --json -o /tmp/ubit-e2e 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'

# Live E2E: zero-FFmpeg AudioToolbox WAV conversion
UBIT_CONFIG_DIR=/tmp/ubit-e2e ./dist/ubit get -a --section 0:00-0:08 --to wav --no-library --quiet -o /tmp/ubit-e2e 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'

# Live E2E: GUI window render smoke check
UBIT_CONFIG_DIR=/tmp/ubit-e2e UBIT_SMOKE_SCREENSHOT=/tmp/ubit-e2e/window.png ./dist/uBit.app/Contents/MacOS/ubit
```

## WebAssembly Build (`linux/build_wasm.sh`)

`WASI_SDK_PATH=/path/to/wasi-sdk sh linux/build_wasm.sh` compiles the Linux C++ CLI (`linux/src/main.cpp`) for `wasm32-wasip1` into `dist/ubit.wasm` (~1 MB), after checking `linux/src/softcrypto.hpp` (SHA-1, SHA-256, AES-128-CBC, which replace OpenSSL there) against `linux/tests/softcrypto_test.cpp`. The module has no sockets, threads, signals, `system()` or desktop UI: the host gives it TCP/TLS through the `ubit_net` imports (`linux/src/wasi.hpp`), its linear memory (imported, so the host sets the ceiling), and WASI preview 1 files. Worker pools run their workers one after another, so downloads use one connection; ffmpeg conversions report an error. Exceptions use the standard `exnref` encoding (`-mllvm -wasm-use-legacy-eh=false`): wasi-sdk's libc++ is built with it, and V8 refuses a module that mixes it with the legacy one. `bare-ubit` is the host (Bare ≥ 1.36, for JS Promise Integration).

## Embeddable C & Rust SDK (`sdk/`, `Cargo.toml`)

`Cargo.toml` + `build.rs` compile `sdk/src/ubit_sdk.cpp` (`-std=c++20 -DUBIT_SDK`, backed by `linux/src/engine.hpp` + `softcrypto.hpp` with zero `dlopen` or `system()` calls) into the `ubit` Rust crate (`sdk/rust/lib.rs`, `sdk/rust/net.rs`). Every outbound connection goes through `ubit_net_vtable` (`sdk/include/ubit.h`) into `rustls` + `webpki-roots` and `ubit::is_public_address` (IANA special-purpose IPv4/IPv6 SSRF filter), while `WorkStealingDownloader` and `HLSEngine` keep native `std::thread` parallelism and per-call `ubit_cancel_t` + socket shutdown cancellation. Verify with `sdk/cargo.sh test`. Build through `sdk/cargo.sh`, not plain `cargo`: a plain build puts the Cargo registry path under `$HOME` into the rlibs of rustls, tokio and the other dependencies. Then `find target -name '*.rlib' -print0 | xargs -0 ./tests/home-paths.sh` must pass and print one `ok` line for each rlib. Use `find`, not `target/debug/deps/*.rlib`: the Cargo on the CI runner did not put the dependency rlibs in that folder. When `find` finds no rlib, GNU `xargs` (CI) exits 123, but macOS `xargs` does not run the check and exits 0 with no output, so on macOS look for the `ok` lines. A project that uses the `ubit` crate as a dependency builds it with its own flags, so it needs the same `--remap-path-prefix` flags.
