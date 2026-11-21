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
        case (_, "/watch"):
            let visitor = mode == "visitor-reuse" ? Self.secondVisitor : Self.firstVisitor
            let player: [String: Any] = mode == "watch-gate"
                ? ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"]]
                : ["playabilityStatus": ["status": "OK"]]
            let json = String(data: try! JSONSerialization.data(withJSONObject: player), encoding: .utf8)!
            data = Data("<script>var ytcfg = {\"VISITOR_DATA\":\"\(visitor)\"};</script><script>var ytInitialPlayerResponse = \(json);</script>".utf8)
        case (_, let path) where path.hasSuffix("/player"):
            if mode == "pace-retry" && playerNumber == 1 {
                status = 429
            } else if ["player-gate", "pace-concurrent", "pace-retry"].contains(mode) {
                data = Self.json(["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"]])
            } else {
                let mime = mode == "section" ? "audio/mp4; codecs=\"mp4a.40.2\"" : "audio/webm; codecs=\"opus\""
                data = Self.json([
                    "playabilityStatus": ["status": "OK"],
                    "videoDetails": ["title": "\(title)-\(playerNumber)", "lengthSeconds": "8"],
                    "streamingData": ["adaptiveFormats": [[
                        "itag": 251,
                        "url": "https://media.invalid/media?n=\(playerNumber)&lsig=fixture",
                        "mimeType": mime,
                        "contentLength": String(Self.mediaBytes.count),
                        "audioSampleRate": "48000",
                    ]]],
                ])
            }
        case ("media.invalid", "/media"):
            // The first URL breaks only in the download phase; extraction's tail probe still works.
            let broken = phase && mediaNumber == 1
            if broken && ["stale", "section"].contains(mode) {
                status = 403
            } else if broken && mode == "non-http-error" {
                failure = URLError(.cancelled)
            } else if range == "bytes=0-0" {
                status = 206
                data = Self.mediaBytes.prefix(1)
                headers["Content-Range"] = "bytes 0-0/\(Self.mediaBytes.count)"
            } else {
                data = Self.mediaBytes
            }
        default:
            status = 404   // never forward an unexpected request
        }

        Self.lock.withLock {
            Self.seen.append(SeenRequest(
                method: method, url: url, time: ProcessInfo.processInfo.systemUptime,
                visitor: request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
                range: range, status: failure == nil ? status : -1
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

    static func playerGaps() -> [TimeInterval] {
        let times = FixtureProtocol.playerRequests().map(\.time).sorted()
        return zip(times.dropFirst(), times).map { $0 - $1 }
    }

    /// Extracts, then downloads through `DownloadEngine` with the first media URL broken.
    static func download(audioExt: String) async -> (file: URL?, error: Error?) {
        do {
            let info = try await extract()
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
            let file = try await DownloadEngine().downloadSingle(url: videoURL, preExtracted: info, settings: settings, options: options)
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
            check(await isBotGate("Fixture0001"), "seed request returns botGate")
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for id in ["Fixture0002", "Fixture0003", "Fixture0004"] { group.addTask { await isBotGate(id) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            let gaps = playerGaps()
            check(results.allSatisfy { $0 } && gaps.count == 3 && gaps.allSatisfy { $0 >= 2.95 },
                  "concurrent /player requests are at least 3 s apart; gaps=\(gaps)")
        case "pace-retry":
            let gated = await isBotGate("Fixture0001")
            let gaps = playerGaps()
            check(gated && gaps.count == 1 && gaps[0] >= 2.95, "the retry after HTTP 429 waits 3 s; gaps=\(gaps)")

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
        case "section":
            _ = await download(audioExt: "m4a")
            let sidxRefused = FixtureProtocol.requests().contains { $0.url.host == "media.invalid" && $0.method == "GET" && $0.status == 403 }
            check(sidxRefused && !umpPosts().isEmpty, "a refused sidx section request reaches the UMP fallback; umpPosts=\(umpPosts().count)")
        case "non-http-error":
            let (_, error) = await download(audioExt: "webm")
            check((error as? URLError)?.code == .cancelled && umpPosts().isEmpty,
                  "a non-HTTP error propagates without UMP; error=\(String(describing: error)), umpPosts=\(umpPosts().count)")

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
