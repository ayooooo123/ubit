# uBit Development Guide (`AGENTS.md`)

`uBit` is an ultra-small (~1.6 MB binary, ~862 KB `.tar.gz`), zero-dependency native macOS (`arm64`) video/audio downloader app and CLI written in pure Swift. One executable (`uBit.app/Contents/MacOS/ubit`) serves both as the native `AppKit`/`SwiftUI`/`WebKit` desktop app (when launched with no arguments) and as the script/agent CLI (when invoked with arguments).

## Layout

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | Dual-mode entry point: dispatches to `CLIRunner` when arguments are passed (ignoring macOS `-psn_*`/`-NS*` launch flags), otherwise starts `NSApplication` with `UBitAppDelegate` |
| `Sources/Core/Models.swift` | Core types (`MediaInfo`, `MediaFormat`, `SubtitleTrack`, `Chapter`, `PlaylistEntry`, `Settings`, `LibraryItem`, `Subscription`, `SectionRange`, `AppPaths`, filename template sanitizer) |
| `Sources/Core/Cookies.swift` | `CookieVault`: Netscape `cookies.txt` parser/writer, read-only Firefox `cookies.sqlite` importer (`libsqlite3`), and `WKHTTPCookieStore` exporter |
| `Sources/Core/QueueAndSubs.swift` | Thread-safe `LibraryStore`, `SubscriptionStore`, `@MainActor QueueManager`, `IOKit` idle-sleep assertion (`IOPMAssertionCreateWithName`), Dock progress badge, and `AF_UNIX` socket IPC (`LocalIPC`) |
| `Sources/Engine/HTTPClient.swift` | Ephemeral `URLSession` client (SOCKS5/HTTP proxy, token-bucket `RateLimiter`, retry/backoff) and `WorkStealingQueue` multi-connection HTTP `Range` downloader (`pwrite` into `.part` + `.part.json`) |
| `Sources/Engine/HLS.swift` | Master & media M3U8 parser (`#EXT-X-STREAM-INF`, `#EXT-X-MEDIA` separate audio renditions, `#EXT-X-MAP`, `#EXT-X-BYTERANGE`, `CommonCrypto` `AES-128-CBC` decryption, parallel segment worker pool, live HLS recorder) |
| `Sources/Engine/DASH.swift` | MPEG-DASH `.mpd` XML parser (`AdaptationSet`, `Representation`, `SegmentTemplate` `$Number$`/`$Time$`, `SegmentTimeline`), parallel segment fetcher |
| `Sources/Mux/MP4Box.swift` | Zero-dependency ISO-BMFF reader/writer: parses `stbl` + fragmented `moof`/`traf`/`trun` + `sidx`, plans byte-range sections, trims at sync keyframes, excises SponsorBlock sample intervals, builds `tx3g` subtitle & `chap`/`chpl` chapter tracks, writes `ilst` metadata (`©nam`, `©ART`, `©day`, `©cmt`, `desc`, `covr`), and emits fast-start MP4/M4A (`ftyp` + `moov` + `mdat`) |
| `Sources/Mux/TSDemuxer.swift` | Pure-Swift 188-byte MPEG-TS (`PAT`/`PMT`/`PES`) demuxer converting Annex-B H.264 (`SPS`/`PPS` → `avcC`) and ADTS AAC (`esds`) into `MP4Track`s |
| `Sources/Engine/SponsorBlock.swift` | Privacy-preserving 4-hex SHA-256 prefix SponsorBlock client, description chapter parser, WebVTT/SRT/XML subtitle parser, and timeline squeezer |
| `Sources/Engine/Converter.swift` | Native `AVFoundation`/`AudioToolbox` converter (`mov`, `m4a`, `wav`, `aiff`, `flac`), `ImageIO` baseline JPEG cover normalizer, `com.apple.metadata:kMDItemWhereFroms` binary plist `setxattr`, Music/TV AppleScript importer, and optional system `ffmpeg` passthrough (`mp3`, `opus`, `mkv`, `webm`) |
| `Sources/Engine/DownloadEngine.swift` | Full download pipeline (`FormatSelector`, `sidx` fast section fetch, stale-URL 403/410 re-extraction, muxing, sidecars, `DownloadEventPayload` emission) |
| `Sources/Extractors/Extractor.swift` | `SiteExtractor` protocol, `ExtractorRegistry` (35 extractors + direct URLs + `ytsearch:`), balanced-JSON/HTML utilities, and `GenericExtractor` (OpenGraph, JSON-LD, `<video>`, inline `.m3u8`/`.mpd`) |
| `Sources/Extractors/YouTubeExtractor.swift` | Multi-client InnerTube (`IOS` direct-URL fast path + `WEB` captions/playlists/channels/search + `TVHTML5_SIMPLY_EMBEDDED_PLAYER` fallback), `SAPISIDHASH` cookie auth, and `JavaScriptCore` `base.js` cipher solver |
| `Sources/Extractors/SitesA.swift` | Vimeo (+ showcases), SoundCloud (dynamic `client_id` + sets/artists), Bilibili (BV/av/multi-part), Twitch (GQL live/VOD/clip), Kick, Reddit (`v.redd.it` + embed fallback), X/Twitter (syndication token + `api.vxtwitter.com` fallback) |
| `Sources/Extractors/SitesB.swift` | Bluesky (ATProto), TikTok, Instagram, Facebook, Threads, Bandcamp, Mixcloud, Dailymotion, Rumble, Odysee, PeerTube, Internet Archive, Streamable, Loom, TED, Imgur, Tumblr, Pinterest, VK, Douyin, Kuaishou, Weibo, Xiaohongshu, GitHub, Mastodon, Coub, 9GAG |
| `Sources/CLI/CLI.swift` | Complete CLI (`get`, `info`, `formats`, `list`, `subs`, `settings`, `sites`, `open`, `browse`, `version`, `--llms`) with NDJSON streaming, ANSI progress bar, and two-stage `SIGINT` handler |
| `Sources/UI/MainWindow.swift` | Native dark-onyx `AppKit` + `SwiftUI` main window, live link preview card, grayscale-to-vivid progress artwork (`ColorFillArtworkView`), `QLPreviewPanel` Quick Look, Settings window, Menu Bar item |
| `Sources/UI/BrowserWindow.swift` | `WKWebView` built-in browser (`⌘B`) with document-start `fetch`/`XHR`/media element sniffer across all frames, `WKContentRuleList` adblocker, and automatic cookie export |
| `build.sh` | Compiles `arm64-apple-macos14.0` with `-Osize -whole-module-optimization -gnone -Xlinker -dead_strip`, strips non-global symbols, generates programmatic `AppIcon.icns`, ad-hoc signs `dist/uBit.app`, and packs `dist/ubit-0.3.0-darwin-arm64.tar.gz` |

## Architectural Rules & Invariants

1. **Zero Third-Party Dependencies**: Link only macOS system frameworks (`AppKit`, `SwiftUI`, `WebKit`, `JavaScriptCore`, `AVFoundation`, `AudioToolbox`, `QuickLookUI`, `IOKit`, `ImageIO`, `UniformTypeIdentifiers`, `CryptoKit`, `CommonCrypto`, `libsqlite3`). Keep the stripped `arm64` binary under 2 MB and the `.tar.gz` under 1 MB.
2. **Two-Pass `co64` Fast-Start MP4 Invariant**: `MP4Muxer.buildMoov` always emits 64-bit `co64` chunk offsets so pass 1 (`chunkBaseOffset = 0`) and pass 2 (`chunkBaseOffset = ftyp + moov + mdatHeader`) have identical byte lengths. Never switch pass 2 between `stco` and `co64` dynamically or sample offsets will drift.
3. **4-Byte Raw iTunes `ilst` Atoms**: QuickTime/iTunes metadata tags (`©nam`, `©ART`, `©day`, `©cmt`) start with byte `0xA9` (ISO-8859-1 `©`), NOT 2-byte UTF-8 `0xC2 0xA9`. Always write them via `BinaryBuffer.boxRaw([0xA9, ...])`.
4. **Pure Swift CLI Formatting**: Never pass Swift `String` values to C `%s` in `String(format:)`; use pure Swift string interpolation and `pad(_:_:)`.
5. **CLI Machine Contract Compatibility**: Keep NDJSON event names (`start`, `info`, `progress`, `process`, `stopping`, `done`, `stopped`, `error`) and exit codes (`0`, `1`, `2`, `130`) stable; update `ubit --llms`, `docs/agents.md`, and `skills/ubit/SKILL.md` together whenever CLI flags or JSON fields change.

## Build & E2E Verification Commands

```sh
# Build stripped release app bundle + CLI symlink + .tar.gz archive
./build.sh

# Verify agent manifest & extractor registry
./dist/ubit --llms
./dist/ubit sites --json

# Live E2E: sidx byte-range clip download + native ISO-BMFF MP4 mux + metadata
UBIT_CONFIG_DIR=/tmp/ubit-e2e ./dist/ubit get -q 720 --section 0:05-0:15 --no-library --json -o /tmp/ubit-e2e 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'

# Live E2E: zero-FFmpeg AudioToolbox WAV conversion
UBIT_CONFIG_DIR=/tmp/ubit-e2e ./dist/ubit get -a --section 0:00-0:08 --to wav --no-library --quiet -o /tmp/ubit-e2e 'https://www.youtube.com/watch?v=aqz-KE-bpKQ'

# Live E2E: GUI window render smoke check
UBIT_CONFIG_DIR=/tmp/ubit-e2e UBIT_SMOKE_SCREENSHOT=/tmp/ubit-e2e/window.png ./dist/uBit.app/Contents/MacOS/ubit
```
