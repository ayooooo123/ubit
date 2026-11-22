// Regression checks for the Swift YouTube, UMP and Safari cookie code.
//
// `tests/swift/run.sh` compiles this file together with every app source except
// `Sources/main.swift` and runs one case per process, each with its own UBIT_CONFIG_DIR.
// A local URLProtocol answers every HTTP request, so no case reaches the network. The
// protocol is put into each ephemeral URLSession configuration (HTTPClient uses
// `URLSessionConfiguration.ephemeral`), and every case first checks that it is in place.
//
// Exit codes: 0 pass, 1 fail, 2 setup failure. A trap (signal) also counts as a failure.

import Foundation
import ObjectiveC

// MARK: - Fixture transport

struct SeenRequest {
    let method: String
    let url: URL
    let time: TimeInterval
    let visitor: String?
    let range: String?
    let status: Int
    let authorization: Bool
}

/// Times that several tasks record.
final class TimeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ time: TimeInterval) { lock.withLock { values.append(time) } }
    func all() -> [TimeInterval] { lock.withLock { values } }
}

final class FixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var mode = ""
    nonisolated(unsafe) private static var seen: [SeenRequest] = []
    nonisolated(unsafe) private static var downloadPhase = false
    nonisolated(unsafe) private static var title = "first"

    static let firstVisitor = "CgtFixtureVisitorFirst00000000000000"
    static let secondVisitor = "CgtFixtureVisitorSecond0000000000000"
    static let mediaBytes = Data("fixture-media-payload-for-the-http-path".utf8)

    static func requests() -> [SeenRequest] { lock.withLock { seen } }
    static func beginDownload() { lock.withLock { downloadPhase = true } }
    static func setTitle(_ value: String) { lock.withLock { title = value } }
    static func playerRequests() -> [SeenRequest] { requests().filter { $0.url.path.hasSuffix("/player") } }

    /// Every session configuration that an HTTPClient built, read after the client set it up.
    nonisolated(unsafe) private static var configs: [URLSessionConfiguration] = []
    static func recordConfig(_ config: URLSessionConfiguration) { lock.withLock { configs.append(config) } }
    /// The proxies that CFNetwork resolves from each configuration, as "type host:port".
    static func resolvedProxies() -> [String] {
        let target = URL(string: "https://www.youtube.com/")! as CFURL
        return lock.withLock { configs }.flatMap { config -> [String] in
            guard let settings = config.connectionProxyDictionary else { return [] }
            let list = CFNetworkCopyProxiesForURL(target, settings as CFDictionary).takeRetainedValue() as? [[String: Any]] ?? []
            return list.map { "\($0[kCFProxyTypeKey as String] ?? "") \($0[kCFProxyHostNameKey as String] ?? ""):\($0[kCFProxyPortNumberKey as String] ?? "")" }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let range = request.value(forHTTPHeaderField: "Range")
        let (playerNumber, phase, title) = Self.lock.withLock {
            (Self.seen.filter { $0.url.path.hasSuffix("/player") }.count + (url.path.hasSuffix("/player") ? 1 : 0),
             Self.downloadPhase, Self.title)
        }
        let mediaNumber = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "n" }?.value.flatMap(Int.init) ?? 0
        let mode = Self.mode
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        var failure: URLError?

        switch (url.host ?? "", url.path) {
        case ("fixture.invalid", "/sanity"):
            data = Data("intercepted".utf8)
        case ("embed.invalid", "/page"):
            data = Data("<html><title>Embed</title><iframe src=\"https://www.youtube.com/embed/Fixture0001\"></iframe></html>".utf8)
            headers["Content-Type"] = "text/html"
        case (_, "/watch"):
            let visitor = mode == "visitor-reuse" ? Self.secondVisitor : Self.firstVisitor
            let player: [String: Any] = ["watch-gate", "wall-unusable-cookie"].contains(mode)
                ? ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"]]
                : ["playabilityStatus": ["status": "OK"]]
            let json = String(data: try! JSONSerialization.data(withJSONObject: player), encoding: .utf8)!
            data = Data("<script>var ytcfg = {\"VISITOR_DATA\":\"\(visitor)\"};</script><script>var ytInitialPlayerResponse = \(json);</script>".utf8)
        case (_, let path) where path.hasSuffix("/player"):
            if mode == "auth-header" && playerNumber % 2 == 1 {
                // Not the bot wall, so extraction goes on to the next client profile.
                data = Self.json(["playabilityStatus": ["status": "UNPLAYABLE", "reason": "fixture refusal"]])
            } else if mode == "pace-retry" && playerNumber == 1 {
                status = 429
            } else if ["player-gate", "pace-concurrent", "pace-retry"].contains(mode)
                        || (mode == "signed-in-wall" && request.value(forHTTPHeaderField: "Authorization") == nil) {
                data = Self.json(["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"]])
            } else {
                let mime = mode == "section" ? "audio/mp4; codecs=\"mp4a.40.2\"" : "audio/webm; codecs=\"opus\""
                var format: [String: Any] = [
                    "itag": 251,
                    "url": "https://media.invalid/media?n=\(playerNumber)&lsig=fixture",
                    "mimeType": mime,
                    "audioSampleRate": "48000",
                ]
                switch mode {
                case "ump-cut": format["contentLength"] = String(Bytes.cutStream.count + 36)   // longer than what UMP returns
                case "ump-complete": format["contentLength"] = String(Bytes.cutStream.count)
                case "ump-unknown-length": break
                default: format["contentLength"] = String(Self.mediaBytes.count)
                }
                data = Self.json([
                    "playabilityStatus": ["status": "OK"],
                    "videoDetails": ["title": "\(title)-\(playerNumber)", "lengthSeconds": "8"],
                    "streamingData": ["adaptiveFormats": [format]],
                ])
            }
        case ("media.invalid", "/media"):
            // The first URL breaks only in the download phase; extraction's tail probe still works.
            // ump-cold refuses every ranged GET from the start.
            let broken = (phase && mediaNumber == 1) || mode == "ump-cold"
            if broken && ["stale", "section", "stale-embed"].contains(mode) {
                status = 403
            } else if broken && ["ump-cut", "ump-complete", "ump-unknown-length", "ump-cold"].contains(mode) {
                // Ranged GETs are refused; the UMP start request answers with a redirect part.
                // In ump-complete the 1-byte probe works, so the HTTP downloader opens its
                // resume files before the refusal and UMP must remove them.
                if method == "POST" {
                    data = Bytes.redirectPart("https://media.invalid/ump-stream")
                } else if mode == "ump-complete" && range == "bytes=0-0" {
                    status = 206
                    data = Data(Bytes.cutStream.prefix(1))
                    headers["Content-Range"] = "bytes 0-0/\(Bytes.cutStream.count)"
                } else {
                    status = 403
                }
            } else if broken && mode == "non-http-error" {
                failure = URLError(.cancelled)
            } else if range == "bytes=0-0" {
                status = 206
                data = Self.mediaBytes.prefix(1)
                headers["Content-Range"] = "bytes 0-0/\(Self.mediaBytes.count)"
            } else {
                data = Self.mediaBytes
            }
        case ("media.invalid", "/ump-stream"):
            // A stream cut between two complete fragments: every box fits, but bytes are missing.
            data = Bytes.umpPart(21, [0] + Bytes.cutStream)
        case ("media.invalid", "/hls.m3u8"):
            // A VOD playlist of 15 segments, 4 s each.
            let segments = (0..<15).map { "#EXTINF:4.0,\nseg-\($0).ts" }.joined(separator: "\n")
            data = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n\(segments)\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", let path) where path.hasPrefix("/seg-"):
            data = Data(path.utf8)
        case ("media.invalid", "/clip.m3u8"):
            // An fMP4 VOD playlist of 15 segments, 4 s each, with four 1 s samples in each segment.
            let segments = (0..<15).map { "#EXTINF:4.0,\nclip-\($0).m4s" }.joined(separator: "\n")
            data = Data("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"clip-init.mp4\"\n\(segments)\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/clip-init.mp4"):
            data = Data(Bytes.clipInit)
        case ("media.invalid", let path) where path.hasPrefix("/clip-"):
            data = Data(Bytes.clipSegment(Int(path.dropFirst(6).dropLast(4)) ?? 0))
        default:
            status = 404   // never forward an unexpected request
        }

        Self.lock.withLock {
            Self.seen.append(SeenRequest(
                method: method, url: url, time: ProcessInfo.processInfo.systemUptime,
                visitor: request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
                range: range, status: failure == nil ? status : -1,
                authorization: request.value(forHTTPHeaderField: "Authorization") != nil
            ))
        }
        if let failure {
            client!.urlProtocol(self, didFailWithError: failure)
            return
        }
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client!.urlProtocol(self, didLoad: data) }
        client!.urlProtocolDidFinishLoading(self)
    }

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

extension URLSessionConfiguration {
    /// Swapped with `ephemeral` at startup; calling it then runs the original getter.
    @objc class func fixtureEphemeral() -> URLSessionConfiguration {
        let config = fixtureEphemeral()
        config.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.recordConfig(config)
        return config
    }
}

// MARK: - Byte fixtures

enum Bytes {
    static func le32(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
    static func be32(_ n: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }

    /// UMP framing integer (not protobuf).
    static func umpInt(_ n: Int) -> [UInt8] {
        if n < 128 { return [UInt8(n)] }
        if n < 16_384 { return [0x80 | UInt8(n & 0x3f), UInt8(n >> 6)] }
        return [0xf0] + le32(UInt32(n))
    }

    static func protobufInt(_ value: Int) -> [UInt8] {
        var n = value
        var out: [UInt8] = []
        repeat {
            let low = UInt8(n & 0x7f)
            n >>= 7
            out.append(n == 0 ? low : low | 0x80)
        } while n != 0
        return out
    }

    static func umpPart(_ type: Int, _ payload: [UInt8]) -> Data {
        Data(umpInt(type) + umpInt(payload.count) + payload)
    }

    /// A UMP redirect part (type 43) whose protobuf payload is `prefix` then field 1 = `url`.
    static func redirectPart(_ url: String, prefix: [UInt8] = []) -> Data {
        let body = Array(url.utf8)
        return umpPart(43, prefix + [0x0a] + protobufInt(body.count) + body)
    }

    /// A one-cookie Safari `Cookies.binarycookies` file.
    static func safariCookies(value: String, expiry: Double) -> Data {
        var record = [UInt8](repeating: 0, count: 56)
        for (i, text) in [".example.invalid", "session", "/", value].enumerated() {
            record.replaceSubrange((16 + i * 4)..<(20 + i * 4), with: le32(UInt32(record.count)))
            record += Array(text.utf8) + [0]
        }
        record.replaceSubrange(0..<4, with: le32(UInt32(record.count)))
        record.replaceSubrange(8..<12, with: le32(1))
        record.replaceSubrange(40..<48, with: (0..<8).map { UInt8(truncatingIfNeeded: expiry.bitPattern >> ($0 * 8)) })
        let page: [UInt8] = [0, 0, 1, 0] + le32(1) + le32(16) + le32(0) + record
        return Data(Array("cook".utf8) + be32(1) + be32(UInt32(page.count)) + page)
    }

    static let ftyp = be32(16) + Array("ftypisom".utf8) + be32(0)

    /// `ftyp` + one `moof`/`mdat` fragment: a valid box chain that stops before the next fragment.
    static let cutStream = ftyp + be32(16) + Array("moof".utf8) + [UInt8](repeating: 0, count: 8)
        + be32(20) + Array("mdat".utf8) + [UInt8](repeating: 7, count: 12)

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload }

    /// Init segment of a one-track audio fMP4: timescale 1000, default sample duration 1000 (1 s),
    /// default sample size 1 byte.
    static let clipInit: [UInt8] = {
        let mdhd = box("mdhd", be32(0) + be32(0) + be32(0) + be32(1000) + be32(0) + be32(0))
        let hdlr = box("hdlr", be32(0) + be32(0) + Array("soun".utf8) + [UInt8](repeating: 0, count: 13))
        let stbl = box("stbl", box("stsd", be32(0) + be32(0)))
        let trak = box("trak", box("mdia", mdhd + hdlr + box("minf", stbl)))
        let trex = box("trex", be32(0) + be32(1) + be32(1) + be32(1000) + be32(1) + be32(0))
        return ftyp + box("moov", trak + box("mvex", trex))
    }()

    /// Media segment `n`: one `moof` with four samples, and an `mdat` whose four bytes are the
    /// stream seconds 4n to 4n+3. The data offset 60 is the `moof` (52 bytes) plus the `mdat` header.
    static func clipSegment(_ n: Int) -> [UInt8] {
        let tfhd = box("tfhd", be32(0x020000) + be32(1))
        let trun = box("trun", be32(0x000001) + be32(4) + be32(60))
        return box("moof", box("traf", tfhd + trun)) + box("mdat", (0..<4).map { UInt8(4 * n + $0) })
    }
}

// MARK: - Cases

@main
struct RegressionChecks {
    static let videoURL = "https://www.youtube.com/watch?v=Fixture0001"

    static func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "PASS" : "FAIL") \(FixtureProtocol.mode): \(message)")
        if !ok { exit(1) }
    }

    static func extract(_ id: String = "Fixture0001", client: HTTPClient = HTTPClient()) async throws -> MediaInfo {
        try await YouTubeExtractor().extract(url: URL(string: "https://www.youtube.com/watch?v=\(id)")!, client: client)
    }

    static func isBotGate(_ id: String) async -> Bool {
        do { _ = try await extract(id); return false }
        catch ExtractorError.botGate { return true }
        catch { print("unexpected error: \(error)"); return false }
    }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Seconds from `start` (taken before the first extraction began) to each /player request.
    static func playerOffsets(from start: TimeInterval) -> [TimeInterval] {
        FixtureProtocol.playerRequests().map { $0.time - start }.sorted()
    }

    /// The first slot is no earlier than `start`, and slot k is 3k s after it. A request never
    /// leaves before its slot; it can only leave late. So request k (from 0) must arrive no
    /// earlier than 3k s after `start`. The bound does not depend on how late any request
    /// was, so a slow machine cannot make it fail. `clockSlack` covers only timer rounding.
    static let clockSlack: TimeInterval = 0.05

    static func keepsSlots(_ offsets: [TimeInterval]) -> Bool {
        offsets.enumerated().allSatisfy { $0.element >= 3.0 * Double($0.offset) - clockSlack }
    }

    /// Extracts, then downloads through `DownloadEngine` with the first media URL broken.
    static func download(audioExt: String, url: String = videoURL) async -> (file: URL?, error: Error?) {
        do {
            let info = url == videoURL ? try await extract() : try await ExtractorRegistry.extract(url: url, client: HTTPClient())
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.cookieSource = "none"
            options.audioOnly = true
            options.connections = 1
            options.targetFormat = audioExt
            options.outputDir = AppPaths.appSupportDir.appendingPathComponent("out").path
            if FixtureProtocol.mode == "section" { options.section = SectionRange(start: 0, end: 4) }
            FixtureProtocol.beginDownload()
            let file = try await DownloadEngine().downloadSingle(url: url, preExtracted: info, settings: settings, options: options)
            return (file, nil)
        } catch {
            return (nil, error)
        }
    }

    static func umpPosts() -> [SeenRequest] {
        FixtureProtocol.requests().filter { $0.url.host == "media.invalid" && $0.method == "POST" }
    }

    static func run(_ mode: String) async throws {
        switch mode {
        // Bot-gate fail-fast and visitor persistence (controls for the carried feature).
        case "watch-gate":
            let gated = await isBotGate("Fixture0001")
            check(gated && FixtureProtocol.playerRequests().isEmpty, "watch-page bot gate stops before any /player request")
        case "player-gate":
            let gated = await isBotGate("Fixture0001")
            check(gated && FixtureProtocol.playerRequests().count == 1, "first /player bot gate stops further client profiles")
        case "visitor-first", "visitor-reuse":
            // run.sh runs these two in order with one shared config directory.
            _ = try await extract()
            let stored = try String(contentsOf: AppPaths.appSupportDir.appendingPathComponent("yt_visitor.txt"), encoding: .utf8)
            let sent = FixtureProtocol.playerRequests().map(\.visitor)
            check(stored == FixtureProtocol.firstVisitor && sent == [FixtureProtocol.firstVisitor],
                  "the first persisted visitor ID is sent; stored=\(stored), sent=\(sent)")

        // Report 1 #1 / report 2 #5: one /player request per 3 s, retries included.
        case "pace-concurrent":
            let start = now()
            check(await isBotGate("Fixture0001"), "seed request returns botGate")
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for id in ["Fixture0002", "Fixture0003", "Fixture0004"] { group.addTask { await isBotGate(id) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            let offsets = playerOffsets(from: start)
            check(results.allSatisfy { $0 } && offsets.count == 4 && keepsSlots(offsets),
                  "concurrent /player requests keep slots 3 s apart; offsets from the start=\(offsets)")
        case "pace-retry":
            let start = now()
            let gated = await isBotGate("Fixture0001")
            let offsets = playerOffsets(from: start)
            check(gated && offsets.count == 2 && keepsSlots(offsets), "the retry after HTTP 429 waits for the next 3 s slot; offsets from the start=\(offsets)")
        case "cancel-slots":
            // A waiter that is cancelled gives its slot back when nobody queued behind it.
            let pacer = YouTubeExtractor.YTGuard()
            try await pacer.pace()
            var waiters: [Task<Void, Error>] = []
            for _ in 0..<3 {
                waiters.append(Task { try await pacer.pace() })
                try await Task.sleep(nanoseconds: 100_000_000)   // reserve the slots in this order
            }
            for waiter in waiters.reversed() {
                waiter.cancel()
                _ = await waiter.result
            }
            let before = now()
            try await pacer.pace()
            let waited = now() - before
            check(waited < 6, "three cancelled waiters give back their slots; the next caller waited \(waited) s (about 2.7 s expected, about 11.7 s if no slot came back)")
        case "cancel-middle":
            // A cancelled waiter with a later caller queued behind it must not free its slot,
            // or two later waits would end in one slot.
            let pacer = YouTubeExtractor.YTGuard()
            let log = TimeLog()
            let start = now()
            try await pacer.pace()
            log.add(now())
            var waiters: [Task<Void, Error>] = []
            for _ in 0..<3 {
                waiters.append(Task { try await pacer.pace(); log.add(now()) })
                try await Task.sleep(nanoseconds: 100_000_000)   // reserve the slots in this order
            }
            waiters[1].cancel()
            _ = await waiters[1].result
            for _ in 0..<2 {
                try await pacer.pace()
                log.add(now())
            }
            _ = await waiters[0].result
            _ = await waiters[2].result
            let offsets = log.all().map { $0 - start }.sorted()
            check(offsets.count == 5 && keepsSlots(offsets),
                  "after a middle waiter is cancelled, every wait still ends in its own 3 s slot; offsets from the start=\(offsets)")
        case "wall-unusable-cookie":
            // An expired or empty SAPISID is never sent, so it must not keep extraction going.
            let expired = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", expires: 1, name: "SAPISID", value: "fixture-only")]))
            let empty = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "")]))
            var stopped = 0
            for client in [expired, empty] {
                do { _ = try await extract(client: client) } catch ExtractorError.botGate { stopped += 1 }
            }
            let players = FixtureProtocol.playerRequests().count
            check(stopped == 2 && players == 0, "an expired or empty sign-in cookie stops at the watch-page wall; stopped=\(stopped), player requests=\(players)")
        case "signed-in-wall":
            // Review of PR #1: a bot wall for the anonymous profiles must not stop the profile
            // that sends the user's sign-in cookies.
            let signedIn = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "fixture-only")]))
            let info = try await extract(client: signedIn)
            let players = FixtureProtocol.playerRequests().count
            check(!info.formats.isEmpty && players == 2,
                  "after the wall only the cookie profile is tried, and it succeeds; player requests=\(players)")
        case "auth-header":
            // The fixture refuses every odd /player request without the bot wall, so each
            // extraction asks two client profiles. Only a usable SAPISID may be sent as SAPISIDHASH.
            let expired = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", expires: 1, name: "SAPISID", value: "fixture-only")]))
            let valid = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "fixture-only")]))
            _ = try await extract(client: expired)
            _ = try await extract(client: valid)
            let sent = FixtureProtocol.playerRequests().map(\.authorization)
            check(sent == [false, false, false, true],
                  "an expired SAPISID sends no Authorization header and a valid one does; Authorization per /player request=\(sent)")

        // Report 1 #5 / report 2 #4: cache is per request context and honours cancellation.
        case "cache":
            let first = try await extract()
            let second = try await extract()
            let before = FixtureProtocol.playerRequests().count
            await YouTubeExtractor.invalidateCache(for: videoURL)
            let third = try await extract()
            let after = FixtureProtocol.playerRequests().count
            check(before == 1 && after == 2 && first.title == second.title && third.title != first.title,
                  "same context reuses the cache, invalidation refreshes it; player requests \(before)->\(after)")
        case "cache-context":
            let signedIn = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "fixture-only")]))
            let first = try await extract(client: signedIn)
            FixtureProtocol.setTitle("second")
            let before = FixtureProtocol.playerRequests().count
            let anonymous = try await extract(client: HTTPClient())
            let proxied = try await extract(client: HTTPClient(proxy: "socks5://127.0.0.1:9"))
            let added = FixtureProtocol.playerRequests().count - before
            check(added == 2 && anonymous.title != first.title && proxied.title != first.title,
                  "other cookies or another proxy do not reuse cached metadata; new player requests=\(added)")
        case "cache-scope":
            // Every request context part changes YouTube's answer: cookies in scope for /watch or
            // only for /player, the extra headers and the User-Agent. The same context is reused.
            func client(_ lang: String, path: String = "/watch", headers: [String: String] = [:], agent: String? = nil) -> HTTPClient {
                HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", path: path, name: "PREF", value: "hl=\(lang)")]),
                           userAgent: agent, extraHeaders: headers)
            }
            _ = try await extract(client: client("fr"))
            _ = try await extract(client: client("en"))
            _ = try await extract(client: client("fr", headers: ["X-Fixture": "1"]))
            _ = try await extract(client: client("fr", path: "/youtubei"))
            _ = try await extract(client: client("en", path: "/youtubei"))
            _ = try await extract(client: client("fr", agent: "FixtureAgent/1"))
            _ = try await extract(client: client("fr", agent: "FixtureAgent/2"))
            _ = try await extract(client: client("fr", agent: "FixtureAgent/1"))
            let players = FixtureProtocol.playerRequests().count
            check(players == 7, "each /watch cookie, /player cookie, extra header and User-Agent gets its own cache entry, and a repeated context reuses it; player requests=\(players) of 8 extractions")
        case "cache-prune":
            let info = try await extract()
            let cache = YouTubeExtractor.YTGuard()
            await cache.store(.init(videoID: "old", context: ""), info, now: Date().addingTimeInterval(-6 * 3600))
            await cache.store(.init(videoID: "new", context: ""), info)
            let entries = await cache.entryCount
            check(entries == 1, "storing an entry drops the expired ones; entries=\(entries)")
        case "cache-cancelled":
            _ = try await extract()
            let task = Task { () throws -> MediaInfo in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await extract()
            }
            do {
                _ = try await task.value
                check(false, "a cancelled extraction returned the cached result")
            } catch {
                check(error is CancellationError, "a cancelled extraction throws CancellationError; got \(error)")
            }

        // Report 1 #2, #3, #6: which download errors reach UMP, and stale-link refresh.
        case "normal":
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            check(error == nil && bytes == FixtureProtocol.mediaBytes && umpPosts().isEmpty,
                  "a working lsig URL downloads over plain HTTP without UMP; error=\(String(describing: error))")
        case "stale":
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let players = FixtureProtocol.playerRequests().count
            check(error == nil && bytes == FixtureProtocol.mediaBytes && players == 2 && umpPosts().count == 1,
                  "403 on HTTP and UMP re-extracts and downloads the fresh URL; players=\(players), umpPosts=\(umpPosts().count), error=\(String(describing: error))")
        case "stale-embed":
            // The user entered a page that embeds the video, so its URL holds no video ID.
            let (file, error) = await download(audioExt: "webm", url: "https://embed.invalid/page")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let players = FixtureProtocol.playerRequests().count
            check(error == nil && bytes == FixtureProtocol.mediaBytes && players == 2,
                  "a stale URL from an embedded video is refreshed; players=\(players), error=\(String(describing: error))")
        case "section":
            _ = await download(audioExt: "m4a")
            let sidxRefused = FixtureProtocol.requests().contains { $0.url.host == "media.invalid" && $0.method == "GET" && $0.status == 403 }
            check(sidxRefused && !umpPosts().isEmpty, "a refused sidx section request reaches the UMP fallback; umpPosts=\(umpPosts().count)")
        case "hls-section-base":
            // The saved HLS timeline starts at 0, so the engine must know where the first kept
            // segment starts in the stream, or the trim cuts the wrong seconds.
            let dest = AppPaths.appSupportDir.appendingPathComponent("hls-section.ts")
            let result = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/hls.m3u8",
                                                            destination: dest, section: SectionRange(start: 20, end: 26))
            let fetched = FixtureProtocol.requests().map(\.url.path).filter { $0.hasPrefix("/seg-") }.sorted()
            check(result.startTime == 16 && fetched == ["/seg-4.ts", "/seg-5.ts", "/seg-6.ts"],
                  "a section of 0:20-0:26 fetches the three overlapping 4 s segments and reports that they start at 16 s; startTime=\(result.startTime), segments=\(fetched)")
        case "hls-section-clip":
            // The whole engine (playlist, segments, demux, trim, mux) must save the samples of
            // stream seconds 20 to 25. Each sample is one byte: its second.
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.cookieSource = "none"
            options.connections = 1
            options.outputDir = AppPaths.appSupportDir.appendingPathComponent("out").path
            options.section = SectionRange(start: 20, end: 26)
            let file = try await DownloadEngine().downloadSingle(url: "https://media.invalid/clip.m3u8", settings: settings, options: options)
            let saved = try Data(contentsOf: file)
            let seconds = saved.range(of: Data("mdat".utf8)).map { saved[$0.upperBound...].map { Int($0) } } ?? []
            let fetched = FixtureProtocol.requests().map(\.url.path).filter { $0.hasSuffix(".m4s") }.sorted()
            check(seconds == [20, 21, 22, 23, 24, 25] && fetched == ["/clip-4.m4s", "/clip-5.m4s", "/clip-6.m4s"],
                  "a 0:20-0:26 section of an HLS stream saves the samples of seconds 20 to 25; saved seconds=\(seconds), segments=\(fetched)")
        case "non-http-error":
            let (_, error) = await download(audioExt: "webm")
            check((error as? URLError)?.code == .cancelled && umpPosts().isEmpty,
                  "a non-HTTP error propagates without UMP; error=\(String(describing: error)), umpPosts=\(umpPosts().count)")
        case "ump-cut":
            // Review of PR #1: a UMP stream cut between complete fragments is not a finished file.
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let players = FixtureProtocol.playerRequests().count
            check(error == nil && bytes == FixtureProtocol.mediaBytes && players == 2,
                  "a short UMP stream is refused and the fresh URL is downloaded; players=\(players), savedBytes=\(bytes?.count ?? -1), error=\(String(describing: error))")
        case "ump-unknown-length":
            // Without an advertised length, nothing shows that a UMP stream is complete.
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let players = FixtureProtocol.playerRequests().count
            check(error == nil && bytes == FixtureProtocol.mediaBytes && players == 2 && umpPosts().isEmpty,
                  "UMP is not tried without a content length and the fresh URL is downloaded; players=\(players), umpPosts=\(umpPosts().count), savedBytes=\(bytes?.count ?? -1)")
        case "ump-complete":
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let outDir = AppPaths.appSupportDir.appendingPathComponent("out")
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).filter { $0.hasSuffix(".part") || $0.hasSuffix(".part.json") }
            check(error == nil && bytes == Data(Bytes.cutStream) && leftovers.isEmpty,
                  "a complete UMP stream is saved and no resume file is left; leftovers=\(leftovers), error=\(String(describing: error))")
        case "ump-cold":
            // Documented boundary: extraction tests byte ranges on one format of each client profile.
            // When every range request is refused from the start and no profile gives an HLS
            // playlist, extraction fails without UMP.
            let info = try? await extract()
            check((info?.formats.isEmpty ?? true) && umpPosts().isEmpty,
                  "refused range probes end extraction without UMP; formats=\(info?.formats.count ?? 0), umpPosts=\(umpPosts().count)")

        // Report 1 #4 / report 2 #2, #1, #3: UMP parsing.
        case "ump-redirect":
            let short = "https://redirect.invalid/media?token=" + String(repeating: "s", count: 10)
            let long = "https://redirect.invalid/media?token=" + String(repeating: "x", count: 250)
            let shortOK = UMP.redirectURL(in: Bytes.redirectPart(short)) == short
            let longGot = UMP.redirectURL(in: Bytes.redirectPart(long))
            let afterScalar = UMP.redirectURL(in: Bytes.redirectPart(short, prefix: [0x10, 0x01]))
            check(shortOK && longGot == long && afterScalar == short,
                  "redirect URLs decode with protobuf lengths; long=\(longGot?.utf8.count ?? 0)/\(long.utf8.count), afterScalar=\(afterScalar != nil)")
        case "ump-oversized-box":
            let media = Bytes.be32(1) + Array("ftyp".utf8) + [UInt8](repeating: 0xff, count: 8)
            check(UMP.assembleMP4(from: Bytes.umpPart(21, [0] + media)) == nil, "a 64-bit box size past the data is rejected without a trap")
        case "ump-truncated":
            let complete = Bytes.ftyp + Bytes.be32(12) + Array("mdat".utf8) + [1, 2, 3, 4]
            let truncated = Bytes.ftyp + Bytes.be32(100) + Array("mdat".utf8) + [1, 2, 3, 4]
            let whole = UMP.assembleMP4(from: Bytes.umpPart(21, [0] + complete))
            let partial = UMP.assembleMP4(from: Bytes.umpPart(21, [0] + truncated))
            check(whole == Data(complete) && partial == nil,
                  "a complete MP4 is returned and a truncated one is rejected; partialBytes=\(partial?.count ?? 0)")
        case "ump-mixed-streams":
            let complete = Bytes.ftyp + Bytes.be32(12) + Array("mdat".utf8) + [1, 2, 3, 4]
            let mixed = Bytes.umpPart(21, [0] + complete) + Bytes.umpPart(21, [1] + Bytes.be32(12) + Array("mdat".utf8) + [5, 6, 7, 8])
            check(UMP.assembleMP4(from: mixed) == nil, "media parts with two header IDs are not merged into one file")

        // Review of PR #1: CLI arguments must not turn into a different target.
        case "cli-flags":
            let unknown = await CLIRunner.run(arguments: ["ubit", "info", "--bogus", "value", "https://fixture.invalid/video"])
            let before = FixtureProtocol.requests().count
            let chromium = await CLIRunner.run(arguments: ["ubit", "info", "--cookies-from-browser", "brave", "https://fixture.invalid/video"])
            let added = FixtureProtocol.requests().count - before
            var settings = Settings()
            let storedBrave = settings.setByKey("cookies", value: "brave")
            let storedPadded = settings.setByKey("cookies", value: " brave ")
            check(unknown == 2 && chromium == 1 && added == 0 && !storedBrave && !storedPadded,
                  "unknown info flag exits 2, a Chromium cookie source fails before any request, settings refuse it even with spaces; unknown=\(unknown), chromium=\(chromium), requests=\(added), stored=\(storedBrave), storedPadded=\(storedPadded)")
        case "proxy-values":
            // A proxy value that cannot be installed must not send the requests directly.
            let before = FixtureProtocol.requests().count
            let target = "https://fixture.invalid/must-not-contact"
            let formats = await CLIRunner.run(arguments: ["ubit", "formats", "--no-cookies", "--proxy", "--bogus", target])
            let info = await CLIRunner.run(arguments: ["ubit", "info", "--proxy", "127.0.0.1:9", target])
            let get = await CLIRunner.run(arguments: ["ubit", "get", "--proxy", "not a proxy", target])
            let socks4 = await CLIRunner.run(arguments: ["ubit", "info", "--proxy", "socks4://127.0.0.1:9", target])
            let socks4a = await CLIRunner.run(arguments: ["ubit", "info", "--proxy", "socks4a://127.0.0.1:9", target])
            let added = FixtureProtocol.requests().count - before
            var settings = Settings()
            let storedBad = settings.setByKey("proxy", value: "bogus")
            let storedSocks4a = settings.setByKey("proxy", value: "socks4a://127.0.0.1:9")
            let storedGood = settings.setByKey("proxy", value: "socks5://127.0.0.1:9")
            _ = await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "--proxy", "socks5://127.0.0.1:9", "https://fixture.invalid/video"])
            _ = await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "--proxy", "SOCKS5://127.0.0.1", "https://fixture.invalid/video"])
            let resolved = FixtureProtocol.resolvedProxies()
            let routed = resolved.contains("\(kCFProxyTypeSOCKS as String) 127.0.0.1:9")
            let capitalPort = resolved.contains("\(kCFProxyTypeSOCKS as String) 127.0.0.1:1080")
            check(formats == 2 && info == 2 && get == 2 && socks4 == 2 && socks4a == 2 && added == 0
                    && !storedBad && !storedSocks4a && storedGood && routed && capitalPort,
                  "invalid proxies exit 2 before any request, settings refuse them, valid ones are installed and a capital SOCKS5 scheme gets port 1080; formats=\(formats), info=\(info), get=\(get), socks4=\(socks4), socks4a=\(socks4a), requests=\(added), storedBad=\(storedBad), storedSocks4a=\(storedSocks4a), resolved=\(resolved)")
        case "proxy-stored":
            // A proxy that was stored before validation existed (or typed into settings.json)
            // must fail the command, not send the request without a proxy.
            var settings = Settings.load()
            settings.proxy = "127.0.0.1:9"
            try settings.save()
            let before = FixtureProtocol.requests().count
            let info = await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "https://fixture.invalid/must-not-contact"])
            let added = FixtureProtocol.requests().count - before
            check(info != 0 && added == 0, "a stored invalid proxy fails the command before any request; exit=\(info), requests=\(added)")

        // Report 1 #7 / report 2 #6, #1: Safari cookie parsing.
        case "safari-values":
            let future = Date().timeIntervalSince1970 + 3600 - 978_307_200
            let normal = SafariBinaryCookies.parse(Bytes.safariCookies(value: "token", expiry: future))
            let empty = SafariBinaryCookies.parse(Bytes.safariCookies(value: "", expiry: future))
            check(normal.first?.value == "token" && empty.count == 1 && empty.first?.value == "" && empty.first?.name == "session",
                  "a cookie with an empty value is kept; normal=\(normal.count), empty=\(empty.count)")
        case "safari-infinite-expiry":
            let parsed = SafariBinaryCookies.parse(Bytes.safariCookies(value: "token", expiry: .infinity))
            check(parsed.isEmpty, "a non-finite expiry is rejected without a trap")
        case "safari-expiry-sentinels":
            let session = SafariBinaryCookies.parse(Bytes.safariCookies(value: "token", expiry: 0))
            let before2001 = SafariBinaryCookies.parse(Bytes.safariCookies(value: "token", expiry: -1))
            let hugeNegative = SafariBinaryCookies.parse(Bytes.safariCookies(value: "token", expiry: -1e300))
            check(session.count == 1 && session.first?.expires == 0 && before2001.isEmpty && hugeNegative.isEmpty,
                  "0 is a session cookie, a negative expiry is expired; session=\(session.count), before2001=\(before2001.count), hugeNegative=\(hugeNegative.count)")
        case "chromium":
            do {
                _ = try CookieVault.load(source: "brave")
                check(false, "an unsupported browser returned a vault")
            } catch CookieError.browserNotSupported(let name) {
                check(name == "brave", "an unsupported browser is reported by name")
            }
        default:
            print("unknown case \(mode)")
            exit(2)
        }
    }

    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("usage: checks <case>")
            exit(2)
        }
        // Some cases write settings.json; without a scratch config directory they would change
        // the user's real settings.
        guard ProcessInfo.processInfo.environment["UBIT_CONFIG_DIR"]?.isEmpty == false else {
            print("SETUP: set UBIT_CONFIG_DIR to a scratch directory (tests/swift/run.sh does this)")
            exit(2)
        }
        FixtureProtocol.mode = CommandLine.arguments[1]
        URLProtocol.registerClass(FixtureProtocol.self)
        guard let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral)),
              let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.fixtureEphemeral)) else {
            print("SETUP: cannot install the fixture transport")
            exit(2)
        }
        method_exchangeImplementations(original, replacement)
        do {
            let (sanity, _) = try await HTTPClient().fetchData(url: "https://fixture.invalid/sanity", retries: 1)
            guard sanity == Data("intercepted".utf8) else {
                print("SETUP: requests bypass the fixture transport")
                exit(2)
            }
            try await run(FixtureProtocol.mode)
        } catch {
            check(false, "unexpected error: \(error)")
        }
        exit(0)
    }
}
