// Regression checks for the Swift YouTube, fail-closed HTTP and Safari cookie code.
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
    /// A fail-closed HTTP denial on one stage of the YouTube path. `deny` covers an HTTP status;
    /// `denyPlayability` covers an explicit playability status with usable streaming data.
    nonisolated(unsafe) private static var deniedStage = ""
    nonisolated(unsafe) private static var deniedStatus = 0
    nonisolated(unsafe) private static var forcedStage = ""
    nonisolated(unsafe) private static var forcedPlayability: String?
    nonisolated(unsafe) private static var retryRequests = 0

    static func requests() -> [SeenRequest] { lock.withLock { seen } }
    static func beginDownload() { lock.withLock { downloadPhase = true } }
    static func endDownload() { lock.withLock { downloadPhase = false } }
    static func setTitle(_ value: String) { lock.withLock { title = value } }
    static func playerRequests() -> [SeenRequest] { requests().filter { $0.url.path.hasSuffix("/player") } }
    static func playerCount() -> Int { playerRequests().count }

    static func deny(stage: String, status: Int) {
        lock.withLock {
            deniedStage = stage
            deniedStatus = status
            forcedStage = ""
            forcedPlayability = nil
        }
    }

    static func denyPlayability(stage: String, status: String) {
        lock.withLock {
            forcedStage = stage
            forcedPlayability = status
            deniedStage = ""
            deniedStatus = 0
        }
    }

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

    // Loopback requests go to a real socket (`WireOrigin`): some faults need a real connection.
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host != "127.0.0.1" }
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
        let (deniedStage, deniedStatus, forcedStage, forcedPlayability) = Self.lock.withLock {
            (Self.deniedStage, Self.deniedStatus, Self.forcedStage, Self.forcedPlayability)
        }
        let mode = Self.mode
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        var failure: Error?
        var lostAfterResponse = false
        var deliveredURL = url

        switch (url.host ?? "", url.path) {
        case ("cdn.syndication.twimg.com", "/tweet-result"), ("instance.invalid", "/api/v1/videos/fixture"), ("i.imgur.com", "/abc123.mp4"):
            status = 403
        case ("metadata.invalid", _), ("sponsor.ajay.app", _):
            status = 403
        case ("media.invalid", "/lost-after-headers"):
            // A 403 response, and then the connection is lost before any body byte.
            status = 403
            lostAfterResponse = true
        case ("segments.invalid", let path) where path.hasSuffix(".mpd"):
            data = Data(#"<MPD mediaPresentationDuration="PT3S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v"><SegmentTemplate duration="1" timescale="1" media="piece-$Number$.m4s"/></Representation></AdaptationSet></Period></MPD>"#.utf8)
        case ("segments.invalid", "/denied/piece-2.m4s"):
            status = 403
        case ("segments.invalid", let path) where path.hasSuffix(".m4s"):
            data = Data(path.utf8)
        case ("fixture.invalid", "/sanity"):
            data = Data("intercepted".utf8)
        case ("fixture.invalid", "/retry-status"):
            let n = Self.lock.withLock { Self.retryRequests += 1; return Self.retryRequests }
            if mode == "retry-5xx" {
                if n == 1 { status = 500 }
                else if n == 2 { status = 503 }
                else { data = Data("retried".utf8) }
            } else {
                status = 429
            }
        case ("fixture.invalid", "/transport"):
            let n = Self.lock.withLock { Self.seen.filter { $0.url.path == "/transport" }.count }
            if mode == "transport-timeout" {
                failure = URLError(.timedOut)
            } else if n == 0 {
                failure = URLError(.cannotConnectToHost)
            } else {
                data = Data("reached".utf8)
            }
        case ("i.imgur.com", "/abc405.mp4"):
            status = 405
        case ("imgur.com", "/abc405"):
            data = Data("<html><head><meta property=\"og:video\" content=\"https://media.invalid/media.mp4\"></head></html>".utf8)
        case ("i.imgur.com", "/abcreset.mp4"):
            // A connection reset before the status that URLSession reports as a POSIX error.
            failure = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        case (_, let path) where path.hasPrefix("/embed/"):
            // Embedding is disabled, so the page carries its own UNPLAYABLE decision.
            let decision = #"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"Playback on other websites has been disabled by the video owner."}}"#
            data = Data("<html><body><script>var ytInitialPlayerResponse = \(decision);</script><script>\"jsUrl\":\"/s/player/fixture/base.js\"</script></body></html>".utf8)
        case (_, "/s/player/fixture/base.js"):
            data = Data(#"var xx={aa:function(a){a.reverse()}}; var decipher=function(a){a=a.split("");xx.aa(a,1);return a.join("")};"#.utf8)
        case (_, "/watch"):
            if deniedStage == "watch" {
                status = deniedStatus
            } else {
                var player: [String: Any]? = Self.playerPayload(status: "OK", streaming: nil, title: title)
                switch mode {
                case "watch-gate", "wall-unusable-cookie", "watch-challenge-cookie":
                    player = Self.challengePlayer(1, title: title)
                case "notice-bot-text":
                    player = nil
                case let notice where notice.hasPrefix("notice-"):
                    player = Self.playerPayload(status: "OK", streaming: Self.directStreaming(1, hls: true), title: title)
                case "hls-fallback-watchlist":
                    player = Self.hlsOnlyPlayer(title: title, playlist: Self.watchPlaylist)
                case "hls-fallback":
                    // Both the watch page and the profiles advertise a playlist.
                    player = Self.hlsOnlyPlayer(title: title, playlist: Self.watchPlaylist)
                case "hls-fallback-nowatch", "hls-fallback-lateprofile":
                    player = nil
                case "ok-reason":
                    player = Self.playerPayload(status: "OK", reason: "Sign in to confirm your age", streaming: nil, title: title)
                default:
                    break
                }
                if forcedStage == "watch", let forcedPlayability {
                    player = Self.playerPayload(
                        status: forcedPlayability,
                        reason: "fixture denial",
                        streaming: Self.directStreaming(1, hls: true),
                        title: title
                    )
                }
                let omitVisitor = forcedStage == "watch"
                    || ["watch-gate", "wall-unusable-cookie", "watch-challenge-cookie"].contains(mode)
                    || mode.hasPrefix("notice-")
                let visitor = omitVisitor ? nil : (mode == "visitor-reuse" ? Self.secondVisitor : Self.firstVisitor)
                switch mode {
                case let notice where notice.hasPrefix("notice-"):
                    data = Self.wallPage(player: player, mode: mode)
                case let plain where plain.hasPrefix("plain-"):
                    data = Self.inertTextPage(player: mode == "plain-no-state" ? nil : player, visitor: visitor, mode: mode)
                default:
                    data = Self.watchPage(player: player, visitor: visitor)
                }
                if mode == "cancel-watch" { failure = URLError(.cancelled) }
                if mode == "redirect-google" { deliveredURL = URL(string: "https://accounts.google.com/ServiceLogin")! }
                if mode == "redirect-ordinary" { deliveredURL = URL(string: "https://fixture.invalid/sorry/article")! }
            }
        case (_, let path) where path.hasSuffix("/player"):
            if mode == "watch-flags" {
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while body.count < 32_768 {
                        let n = stream.read(&buffer, maxLength: buffer.count)
                        if n <= 0 { break }
                        body.append(contentsOf: buffer.prefix(n))
                    }
                }
                let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                guard payload?["videoId"] != nil, payload?["contentCheckOk"] == nil, payload?["racyCheckOk"] == nil else {
                    status = 403; break
                }
            }
            if deniedStage == "player" {
                status = deniedStatus
            } else if forcedStage == "player", let forcedPlayability {
                data = Self.json(Self.playerPayload(
                    status: forcedPlayability,
                    reason: "fixture denial",
                    streaming: Self.directStreaming(playerNumber, hls: true),
                    title: "\(title)-\(playerNumber)"
                ))
            } else if mode == "player-body-lost" && playerNumber == 1 {
                // HTTP 200 and half of an ordinary body, then the connection breaks. Trailing
                // spaces make the half larger than the 512 bytes that URLSession can hold back to
                // sniff the content type.
                data = Self.json(Self.normalPlayer(playerNumber, title: title)) + Data(repeating: 0x20, count: 8192)
                lostAfterResponse = true
            } else if mode == "player-timeout" {
                failure = URLError(.timedOut)
            } else if mode == "pace-retry" && playerNumber == 1 {
                status = 503
            } else if ["watch-gate", "player-gate", "pace-concurrent", "wall-unusable-cookie", "watch-challenge-cookie", "player-challenge-cookie", "pace-retry"].contains(mode) {
                data = Self.json(Self.challengePlayer(playerNumber, title: "\(title)-\(playerNumber)"))
            } else if mode == "auth-header" && playerNumber % 2 == 1 {
                // An ordinary empty response, not a denial: extraction goes on to the next profile.
                data = Self.json(Self.emptyPlayer(title: title))
            } else if mode == "hls-fallback" {
                data = Self.json(Self.hlsOnlyPlayer(title: title, playlist: Self.profilePlaylist))
            } else if mode == "hls-fallback-lateprofile" && playerNumber > 1 {
                data = Self.json(Self.hlsOnlyPlayer(title: title, playlist: Self.profilePlaylist))
            } else if mode == "hls-fallback-lateprofile" {
                data = Self.json(Self.missingFormatPlayer(playerNumber, title: title))
            } else if ["hls-fallback-nowatch", "hls-fallback-watchlist"].contains(mode) {
                data = Self.json(Self.emptyPlayer(title: title))
            } else if mode == "embed-disabled" {
                data = Self.json(Self.cipherPlayer(title: title))
            } else {
                data = Self.json(Self.normalPlayer(playerNumber, title: title))
            }
            if mode == "cancel-player" { failure = URLError(.cancelled) }
        case ("media.invalid", "/media"):
            if mode == "cancel-probe" {
                failure = URLError(.cancelled)
            } else if deniedStage == "probe" {
                status = deniedStatus
            } else if deniedStage == "download" && phase {
                status = deniedStatus
            } else if mode == "cancel-download" && phase {
                failure = URLError(.cancelled)
            } else if range == "bytes=0-0" {
                status = 206
                data = Self.mediaBytes.prefix(1)
                headers["Content-Range"] = "bytes 0-0/\(Self.mediaBytes.count)"
            } else if deniedStage == "stream" && phase {
                status = deniedStatus
            } else {
                data = Self.mediaBytes
            }
        case ("media.invalid", let path) where path.hasSuffix(".m3u8"):
            // An HLS playlist of 15 fragmented MP4 segments, 4 s each. Extraction reads only the playlist.
            let segments = (0..<15).map { "#EXTINF:4.0,\nclip-\($0).m4s" }.joined(separator: "\n")
            data = Data("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"clip-init.mp4\"\n\(segments)\n#EXT-X-ENDLIST\n".utf8)
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
        let response = HTTPURLResponse(url: deliveredURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if lostAfterResponse {
            guard !data.isEmpty else {
                client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            // Half of the body, then the connection breaks a moment later, after URLSession has
            // handed over the response.
            client!.urlProtocol(self, didLoad: data.prefix(data.count / 2))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        if !data.isEmpty { client!.urlProtocol(self, didLoad: data) }
        client!.urlProtocolDidFinishLoading(self)
    }

    static func directStreaming(_ n: Int, hls: Bool = false) -> [String: Any] {
        var streaming: [String: Any] = ["adaptiveFormats": [[
            "itag": 251,
            "url": "https://media.invalid/media?n=\(n)&lsig=fixture",
            "mimeType": "audio/webm; codecs=\"opus\"",
            "audioSampleRate": "48000",
            "contentLength": String(mediaBytes.count),
        ]]]
        if hls { streaming["hlsManifestUrl"] = "https://media.invalid/clip.m3u8" }
        return streaming
    }

    static let watchPlaylist = "https://media.invalid/watch.m3u8"
    static let profilePlaylist = "https://media.invalid/profile.m3u8"

    static func hlsStreaming(_ playlist: String = "https://media.invalid/clip.m3u8") -> [String: Any] {
        ["hlsManifestUrl": playlist]
    }

    static func playerPayload(
        status: String,
        reason: String? = nil,
        streaming: [String: Any]?,
        title: String
    ) -> [String: Any] {
        var playability: [String: Any] = ["status": status]
        if let reason { playability["reason"] = reason }
        var payload: [String: Any] = [
            "playabilityStatus": playability,
            "videoDetails": ["title": title, "lengthSeconds": "8"],
        ]
        if let streaming { payload["streamingData"] = streaming }
        return payload
    }

    static func normalPlayer(_ n: Int, title: String) -> [String: Any] {
        playerPayload(status: "OK", streaming: directStreaming(n), title: "\(title)-\(n)")
    }

    /// A format whose URL needs the player script: the extractor must read the embed page.
    static func cipherPlayer(title: String) -> [String: Any] {
        let streaming: [String: Any] = ["adaptiveFormats": [[
            "itag": 251,
            "signatureCipher": "url=https%3A%2F%2Fmedia.invalid%2Fmedia&s=abcd&sp=sig",
            "mimeType": "audio/webm; codecs=\"opus\"",
            "audioSampleRate": "48000",
            "contentLength": String(mediaBytes.count),
        ]]]
        return playerPayload(status: "OK", streaming: streaming, title: title)
    }

    static func emptyPlayer(title: String) -> [String: Any] {
        playerPayload(status: "OK", streaming: ["adaptiveFormats": [Any]()], title: title)
    }

    static func hlsOnlyPlayer(title: String, playlist: String) -> [String: Any] {
        playerPayload(status: "OK", streaming: hlsStreaming(playlist), title: title)
    }

    static func missingFormatPlayer(_ n: Int, title: String) -> [String: Any] {
        let streaming: [String: Any] = ["adaptiveFormats": [[
            "itag": 251,
            "url": "https://media.invalid/missing",
            "mimeType": "audio/webm; codecs=\"opus\"",
            "audioSampleRate": "48000",
            "contentLength": String(mediaBytes.count),
        ]]]
        return playerPayload(status: "OK", streaming: streaming, title: "\(title)-\(n)")
    }

    /// A bot challenge that also carries usable streaming data, so an extractor that trusts the
    /// data instead of the playability status would continue.
    static func challengePlayer(_ n: Int, title: String) -> [String: Any] {
        playerPayload(
            status: "LOGIN_REQUIRED",
            reason: "Sign in to confirm you're not a bot",
            streaming: directStreaming(n, hls: true),
            title: title
        )
    }

    static func watchPage(player: [String: Any]?, visitor: String?) -> Data {
        var html = ""
        if let visitor {
            html += "<script>var ytcfg = {\"VISITOR_DATA\":\"\(visitor)\"};</script>"
        }
        if let player {
            let json = String(data: try! JSONSerialization.data(withJSONObject: player), encoding: .utf8)!
            html += "<script>var ytInitialPlayerResponse = \(json);</script>"
        }
        return Data(html.utf8)
    }

    /// A verification wall that shows one listed notice or a reCAPTCHA widget. Most modes also
    /// embed player metadata that reports ordinary playback, which the notice must outrank.
    static func wallPage(player: [String: Any]?, mode: String) -> Data {
        var html = "<html><head><title>YouTube</title></head><body>"
        switch mode {
        case "notice-bot":
            html += "<main role=\"alert\"><p>Sign in to confirm you’re not a bot.</p><p>This helps protect our community.</p></main>"
        case "notice-entity":
            html += "<p>Sign in to confirm you&rsquo;re not a bot.</p>"
        case "notice-entity-number":
            html += "<p>Sign&#32;in to confirm you&#x2019;re not a bot.</p>"
        case "notice-bot-text":
            html += "<div>Sign in to confirm you're not a bot</div>"
        case "notice-age":
            html += "<p>Sign in to confirm your age. This video may be inappropriate for some users.</p>"
        case "notice-traffic":
            html += "<div>Our systems have detected unusual traffic from your computer network. This page checks to see if it's really you sending the requests, and not a robot.</div>"
        case "notice-summary":
            html += "<details><summary>Sign in to confirm your age</summary><p>Help</p></details>"
        case "notice-widget":
            html += "<form><div class=\"g-recaptcha\" data-sitekey=\"fixture\"></div></form>"
        default:
            fatalError("unknown notice mode \(mode)")
        }
        if let player {
            let json = String(data: try! JSONSerialization.data(withJSONObject: player), encoding: .utf8)!
            html += "<script>var ytInitialPlayerResponse = \(json);</script>"
        }
        return Data((html + "</body></html>").utf8)
    }

    /// An ordinary page: challenge words appear only where a reader cannot see them, that is in
    /// the title, the meta description, the video description, page code and a comment. Some
    /// modes add visible text that is not one of the listed notice sentences, or listed
    /// sentences and a widget under hidden elements.
    static func inertTextPage(player: [String: Any]?, visitor: String?, mode: String) -> Data {
        var html = "<html><head>"
        html += "<title>How to verify your account - YouTube</title>"
        html += "<meta name=\"description\" content=\"Verify your account: unusual traffic and not a bot, explained.\">"
        if let visitor {
            html += "<script>var ytcfg = {\"VISITOR_DATA\":\"\(visitor)\"};</script>"
        }
        if var player {
            var details = player["videoDetails"] as? [String: Any] ?? [:]
            details["shortDescription"] = "How to proceed when a page asks you to verify your account after unusual traffic. This is not a bot."
            player["videoDetails"] = details
            let json = String(data: try! JSONSerialization.data(withJSONObject: player), encoding: .utf8)!
            html += "<script>var ytInitialPlayerResponse = \(json);</script>"
        }
        html += "</head><body>"
        html += "<!-- Confirm your age appears only in this comment. -->"
        switch mode {
        case "plain-closed-details":
            html += "<h1>Music lesson</h1><details><summary>Help</summary><p>Sign in to confirm your age.</p></details>"
        case "plain-secondary-summary":
            // A browser shows only the first summary of a closed details element.
            html += "<h1>Music lesson</h1><details><summary>Help</summary><summary>Sign in to confirm your age</summary></details>"
        case "plain-unlisted":
            // Wording that the earlier sentence guesser treated as a notice. None is listed.
            html += "<main role=\"alert\"><p>Please verify your age to play this video.</p><p>Playback is blocked.</p>"
            html += "<p>Confirm you're not a bot</p><p>Sign in to confirm your identity.</p></main>"
        case "plain-lessons":
            html += "<article><p>Verify your age family settings before saving.</p>"
            html += "<p>Confirm your identity reply in the webhook log.</p>"
            html += "<p>Playback is blocked? Check your speaker mute switch.</p>"
            html += "<p>This lesson explains why a server displays the text: sign in to confirm you're not a bot.</p>"
            html += "<p>This tutorial explains why shared NAT networks trigger a detected unusual traffic alert.</p></article>"
        case "plain-hidden":
            html += "<!-- Optional g-recaptcha component not loaded. -->"
            html += "<div hidden><p>Sign in to confirm your age.</p></div>"
            html += "<dialog><p>Sign in to confirm you're not a bot</p></dialog>"
            html += "<div style=\"display: none\"><div class=\"g-recaptcha\"></div></div>"
        default: break
        }
        html += "<script>var notice = \"Verify your identity before playback can continue\";</script>"
        html += "<h1>Verify your audio settings</h1></body></html>"
        return Data(html.utf8)
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

// MARK: - Loopback origin

/// A real HTTP/1.1 origin on 127.0.0.1, for faults that a URLProtocol cannot model: a response
/// body that breaks off or stalls after the headers. `reply` receives the connection and the
/// number of the request (from 1), after the request head has arrived.
final class WireOrigin: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }

    init(reply: @escaping @Sendable (Int32, Int, String) -> Void) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listener, $0, length)
                _ = getsockname(listener, $0, &length)
            }
        }
        listen(listener, 16)
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var head: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 4096)
                while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
                    let got = read(connection, &buffer, buffer.count)
                    if got <= 0 { break }
                    head += buffer[0..<got]
                }
                let number = lock.withLock { count += 1; return count }
                let request = String(decoding: head, as: UTF8.self)
                Thread.detachNewThread { reply(connection, number, request) }
            }
        }
    }

    static func transmit(_ connection: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes[sent...].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            if wrote <= 0 { return }
            sent += wrote
        }
    }

    /// Closes with a TCP reset instead of an orderly close.
    static func reset(_ connection: Int32) {
        var abort = linger(l_onoff: 1, l_linger: 0)
        setsockopt(connection, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
        close(connection)
    }
}

// MARK: - Byte fixtures

enum Bytes {
    static func le32(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
    static func be32(_ n: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }

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

    static func extractError(_ client: HTTPClient = HTTPClient()) async -> Error? {
        do { _ = try await extract(client: client); return nil } catch { return error }
    }

    static func httpStatus(_ error: Error?) -> Int? {
        guard let error, let http = error as? HTTPError, case .status(let code, _) = http else { return nil }
        return code
    }

    static func closedByBotGate(_ error: Error?) -> Bool {
        guard let error, let extractor = error as? ExtractorError, case .botGate = extractor else { return false }
        return true
    }

    static func isExtractorError(_ error: Error?) -> Bool {
        guard let error else { return false }
        return error is ExtractorError
    }

    /// Every file in the download directory, hidden ones included.
    static func savedOutputs() -> [String] {
        let out = AppPaths.appSupportDir.appendingPathComponent("out")
        return (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
    }

    /// Final files in the download directory; a cancelled download may keep a hidden resume file.
    static func finalOutputs() -> [String] {
        savedOutputs().filter { !$0.hasPrefix(".") }
    }

    static func watchQueryNames() -> [String] {
        FixtureProtocol.requests()
            .filter { $0.url.path == "/watch" }
            .flatMap { (URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name) }
    }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Runs `body` with this process's standard error sent to a file, and returns what it wrote.
    static func capturingStderr<T>(_ body: () async throws -> T) async rethrows -> (T, String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let fd = open(file.path, O_WRONLY)
        fflush(stderr)
        let saved = dup(2)
        dup2(fd, 2)
        defer {
            fflush(stderr)
            dup2(saved, 2)
            close(saved)
            close(fd)
        }
        let result = try await body()
        fflush(stderr)
        return (result, (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

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

    /// Extracts, then downloads through `DownloadEngine`. A distinct `client` context makes the
    /// extraction miss the metadata cache.
    static func download(audioExt: String, client: HTTPClient = HTTPClient()) async -> (file: URL?, error: Error?) {
        do {
            let info = try await extract(client: client)
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.cookieSource = "none"
            options.audioOnly = true
            options.connections = 1
            options.targetFormat = audioExt
            options.outputDir = AppPaths.appSupportDir.appendingPathComponent("out").path
            FixtureProtocol.beginDownload()
            defer { FixtureProtocol.endDownload() }
            let file = try await DownloadEngine().downloadSingle(url: videoURL, preExtracted: info, settings: settings, options: options)
            return (file, nil)
        } catch {
            return (nil, error)
        }
    }

    static func run(_ mode: String) async throws {
        switch mode {
        case "metadata-refusal":
            let out = AppPaths.appSupportDir.appendingPathComponent("out")
            for stage in ["cover", "subtitles", "sponsors"] {
                let media = MediaFormat(id: "video", url: "https://media.invalid/media", ext: "webm", proto: .http, vcodec: "vp9", acodec: "opus")
                var info = MediaInfo(id: "fixture", title: stage, site: "YouTube", webpageURL: videoURL, formats: [media])
                if stage == "cover" { info.thumbnail = "https://metadata.invalid/cover" }
                if stage != "sponsors" { info.subtitles = [SubtitleTrack(lang: "en", name: "English", url: "https://metadata.invalid/subtitles")] }
                var settings = Settings()
                settings.embedMetadata = true
                var options = DownloadRequestOptions()
                options.cookieSource = "none"
                options.outputDir = out.path
                options.targetFormat = "webm"
                options.downloadSubtitles = true
                options.sponsorMode = "mark"
                options.connections = 1
                let before = FixtureProtocol.requests().count
                var failure: Error?
                do { _ = try await DownloadEngine().downloadSingle(url: videoURL, preExtracted: info, settings: settings, options: options) }
                catch { failure = error }
                let seen = FixtureProtocol.requests().dropFirst(before)
                let wanted = stage == "sponsors" ? seen.last?.url.host == "sponsor.ajay.app" : seen.last?.url.path == "/" + stage
                check(httpStatus(failure) == 403 && wanted && seen.dropLast().allSatisfy { $0.url.host == "media.invalid" } && finalOutputs().isEmpty,
                      "no final file or later request after denied \(stage): \(seen.map { $0.url.path }), output=\(finalOutputs())")
            }
        case "optional-refusal":
            let out = AppPaths.appSupportDir.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (target, host, path) in [("https://x.com/fixture/status/123", "cdn.syndication.twimg.com", "/tweet-result"),
                                         ("https://instance.invalid/w/fixture", "instance.invalid", "/api/v1/videos/fixture"),
                                         ("https://imgur.com/abc123", "i.imgur.com", "/abc123.mp4")] {
                let before = FixtureProtocol.requests().count
                let (code, message) = await capturingStderr { await CLIRunner.run(arguments: [
                    "ubit", "get", "--quiet", "--no-cookies", "--no-library", "-o", out.path, target
                ]) }
                let seen = FixtureProtocol.requests().dropFirst(before)
                let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
                check(code == 1 && message.contains("403") && seen.count == 1 && seen.first?.url.host == host
                      && seen.first?.url.path == path && files.isEmpty,
                      "\(host) refusal: exit=\(code), requests=\(seen.map { $0.url.absoluteString }), output=\(files)")
            }
        // The embed page only supplies the player script. Its own UNPLAYABLE decision is about
        // embedding, so it must not end extraction of the watch URL.
        case "embed-disabled":
            let info = try await extract()
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            let url = info.formats.first?.url ?? ""
            check(url.hasPrefix("https://media.invalid/media") && url.contains("sig=dcba")
                    && paths.contains("/embed/Fixture0001") && paths.contains("/s/player/fixture/base.js"),
                  "a disabled embed still supplies the player script; url=\(url), paths=\(paths)")
        // A 405 on Imgur's optional direct probe is not a refusal: the page extractor runs.
        case "imgur-405":
            let info = try await ImgurExtractor().extract(url: URL(string: "https://imgur.com/abc405")!, client: HTTPClient())
            let hosts = FixtureProtocol.requests().filter { $0.url.path != "/sanity" }.compactMap(\.url.host)
            check(info.formats.first?.url == "https://media.invalid/media.mp4" && hosts == ["i.imgur.com", "imgur.com"],
                  "a 405 probe falls back to the page; formats=\(info.formats.map(\.url)), hosts=\(hosts)")
        // A reset before the status that is not a URLError still leaves the status unknown, so
        // Imgur's optional direct probe ends the operation instead of moving on to the page.
        case "imgur-reset":
            var failure: Error?
            do { _ = try await ImgurExtractor().extract(url: URL(string: "https://imgur.com/abcreset")!, client: HTTPClient()) }
            catch { failure = error }
            let hosts = FixtureProtocol.requests().filter { $0.url.path != "/sanity" }.compactMap(\.url.host)
            var unknown = false
            if case HTTPError.noStatus? = failure as? HTTPError { unknown = true }
            check(unknown && hosts == ["i.imgur.com"],
                  "a POSIX reset before the status is an unknown status that allows no later request; error=\(String(describing: failure)), hosts=\(hosts)")
        // An OK playability status allows playback. A listed sentence as its reason is only
        // information, so extraction goes on to the player.
        case "ok-reason":
            let error = await extractError()
            check(error == nil && FixtureProtocol.playerCount() == 1,
                  "OK with a listed reason and no visible notice is not a challenge; error=\(String(describing: error)), players=\(FixtureProtocol.playerCount())")
        // A watch page that ends on Google's sign-in host is a challenge. A `/sorry/` path on
        // another host is an ordinary page.
        case "redirect-google", "redirect-ordinary":
            let error = await extractError()
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            if mode == "redirect-google" {
                check(closedByBotGate(error) && paths == ["/watch"],
                      "a watch page that ends on accounts.google.com stops at once; error=\(String(describing: error)), paths=\(paths)")
            } else {
                check(error == nil && FixtureProtocol.playerCount() == 1,
                      "a /sorry/ path on a host that is not Google is not a challenge; error=\(String(describing: error)), paths=\(paths)")
            }
        // A /player body that breaks off after HTTP 200 had a known status, so the player tries
        // again in its next pacing slot. A timeout before the status is not tried again.
        case "player-body-lost", "player-timeout":
            let start = now()
            let error = await extractError()
            let offsets = playerOffsets(from: start)
            if mode == "player-body-lost" {
                check(error == nil && offsets.count == 2 && keepsSlots(offsets),
                      "a broken 2xx body is tried again in the next 3 s slot; error=\(String(describing: error)), offsets from the start=\(offsets)")
            } else {
                var unknown = false
                if case HTTPError.noStatus? = error as? HTTPError { unknown = true }
                check(unknown && offsets.count == 1,
                      "a /player timeout before the status is not tried again; error=\(String(describing: error)), offsets from the start=\(offsets)")
            }
        case "cancel-watch", "cancel-player", "cancel-probe":
            do {
                _ = try await extract()
                check(false, "extraction returned metadata after cancellation")
            } catch let error as URLError where error.code == .cancelled {}
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            let steps = ["/watch", "/youtubei/v1/player", "/media"]
            let limit = mode == "cancel-watch" ? 1 : (mode == "cancel-player" ? 2 : 3)
            check(paths == Array(steps.prefix(limit)), "the cancelled request was the last request: \(paths)")
        // Bot-gate fail-fast and visitor persistence (controls for the carried feature).
        case "watch-gate":
            let error = await extractError()
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check(closedByBotGate(error) && paths == ["/watch"],
                  "a watch-page bot gate with streaming data stops before visitor and /player; error=\(String(describing: error)), paths=\(paths)")
        // A listed notice or a visible widget outranks embedded metadata. Only the listed
        // sentences count; other visible text, hidden text and page code are not notices.
        case let notice where notice.hasPrefix("notice-"):
            let before = FixtureProtocol.requests().count
            let error = await extractError()
            let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
            check(closedByBotGate(error) && paths == ["/watch"] && savedOutputs().isEmpty,
                  "a listed notice stops after the first response, even when the page embeds ordinary player metadata; error=\(String(describing: error)), paths=\(paths), saved=\(savedOutputs())")
        case let plain where plain.hasPrefix("plain-"):
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check(error == nil && bytes == FixtureProtocol.mediaBytes,
                  "text that is not a listed notice, or that a reader cannot see, does not stop an ordinary page; error=\(String(describing: error)), paths=\(paths)")
        case "player-gate":
            let error = await extractError()
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check(closedByBotGate(error) && paths == ["/watch", "/youtubei/v1/player"],
                  "the first /player bot gate with streaming data stops further profiles, media and HLS; error=\(String(describing: error)), paths=\(paths)")

        // Every listed HTTP status fails closed on each stage, with no later request.
        case "watch-status":
            for code in [401, 403, 407, 410, 429, 451] {
                FixtureProtocol.deny(stage: "watch", status: code)
                let before = FixtureProtocol.requests().count
                let error = await extractError()
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                check(httpStatus(error) == code && paths == ["/watch"],
                      "HTTP \(code) on the watch page stops before visitor or player requests; error=\(String(describing: error)), paths=\(paths)")
            }
            check(savedOutputs().isEmpty, "watch denials save no output; saved=\(savedOutputs())")
        case "player-status":
            for code in [401, 403, 407, 410, 429, 451] {
                FixtureProtocol.deny(stage: "player", status: code)
                let before = FixtureProtocol.requests().count
                let error = await extractError()
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                check(httpStatus(error) == code && paths == ["/watch", "/youtubei/v1/player"],
                      "HTTP \(code) on the first /player stops before another profile, media or HLS; error=\(String(describing: error)), paths=\(paths)")
            }
            check(savedOutputs().isEmpty, "player denials save no output; saved=\(savedOutputs())")
        case "probe-status":
            for code in [401, 403, 407, 410, 429, 451] {
                FixtureProtocol.deny(stage: "probe", status: code)
                let before = FixtureProtocol.requests().count
                let error = await extractError()
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                check(httpStatus(error) == code && paths == ["/watch", "/youtubei/v1/player", "/media"],
                      "HTTP \(code) on the range probe stops before HLS or download; error=\(String(describing: error)), paths=\(paths)")
            }
            check(savedOutputs().isEmpty, "probe denials save no output; saved=\(savedOutputs())")
        case "download-status":
            for code in [401, 403, 407, 410, 429, 451] {
                FixtureProtocol.deny(stage: "download", status: code)
                let fresh = HTTPClient(userAgent: "FixtureAgent/\(code)")
                let before = FixtureProtocol.requests().count
                let beforePlayers = FixtureProtocol.playerCount()
                let (file, error) = await download(audioExt: "webm", client: fresh)
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                let players = FixtureProtocol.playerCount() - beforePlayers
                check(file == nil && httpStatus(error) == code
                        && paths == ["/watch", "/youtubei/v1/player", "/media", "/media"] && players == 1,
                      "HTTP \(code) on the download probe stops without a new player request; error=\(String(describing: error)), paths=\(paths), players=\(players)")
            }
            check(savedOutputs().isEmpty, "download denials save no output; saved=\(savedOutputs())")
        case "download-stream-status":
            // The probe succeeds and the single-stream GET is refused, so the streaming read must
            // throw the status too, not re-extract.
            for code in [401, 403, 407, 410, 429, 451] {
                FixtureProtocol.deny(stage: "stream", status: code)
                let fresh = HTTPClient(userAgent: "FixtureAgent/\(code)")
                let before = FixtureProtocol.requests().count
                let beforePlayers = FixtureProtocol.playerCount()
                let (file, error) = await download(audioExt: "webm", client: fresh)
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                let players = FixtureProtocol.playerCount() - beforePlayers
                check(file == nil && httpStatus(error) == code
                        && paths == ["/watch", "/youtubei/v1/player", "/media", "/media", "/media"] && players == 1,
                      "HTTP \(code) on the download stream stops without a new player request; error=\(String(describing: error)), paths=\(paths), players=\(players)")
            }
            check(finalOutputs().isEmpty, "download stream denials save no final file; saved=\(finalOutputs())")

        // Any explicit non-OK playability status fails closed even with usable streaming data.
        case "playability-status":
            for stage in ["watch", "player"] {
                for code in ["LOGIN_REQUIRED", "UNPLAYABLE", "ERROR"] {
                    FixtureProtocol.denyPlayability(stage: stage, status: code)
                    let before = FixtureProtocol.requests().count
                    let error = await extractError()
                    let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                    let expected = stage == "watch" ? ["/watch"] : ["/watch", "/youtubei/v1/player"]
                    check(isExtractorError(error) && paths == expected,
                          "\(code) with streaming data on the \(stage) fails closed; error=\(String(describing: error)), paths=\(paths)")
                }
            }
            check(savedOutputs().isEmpty, "playability denials save no output; saved=\(savedOutputs())")

        // A bot challenge is not recoverable with cookies or streaming data.
        case "watch-challenge-cookie":
            let signedIn = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "fixture-only")]))
            let error = await extractError(signedIn)
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check(closedByBotGate(error) && paths == ["/watch"] && savedOutputs().isEmpty,
                  "a watch-page bot challenge with a sign-in cookie and streaming data stops before visitor or player requests; error=\(String(describing: error)), paths=\(paths), saved=\(savedOutputs())")
        case "player-challenge-cookie":
            let signedIn = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "fixture-only")]))
            let error = await extractError(signedIn)
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check(closedByBotGate(error) && paths == ["/watch", "/youtubei/v1/player"] && savedOutputs().isEmpty,
                  "a /player bot challenge with a sign-in cookie and streaming data stops before media or HLS; error=\(String(describing: error)), paths=\(paths), saved=\(savedOutputs())")

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
            let error = await extractError()
            let offsets = playerOffsets(from: start)
            check(closedByBotGate(error) && offsets.count == 2 && keepsSlots(offsets),
                  "the retry after HTTP 503 waits for the next 3 s slot; error=\(String(describing: error)), offsets from the start=\(offsets)")
        case "retry-5xx":
            let before = FixtureProtocol.requests().count
            let (data, _) = try await HTTPClient().fetchData(url: "https://fixture.invalid/retry-status", retries: 3)
            let attempts = FixtureProtocol.requests().count - before
            check(data == Data("retried".utf8) && attempts == 3,
                  "HTTP 500 and then 503 are retried; attempts=\(attempts), data=\(String(decoding: data, as: UTF8.self))")
        case "retry-429":
            let before = FixtureProtocol.requests().count
            var status = 0
            do {
                _ = try await HTTPClient().fetchData(url: "https://fixture.invalid/retry-status", retries: 3)
            } catch HTTPError.status(let code, _) {
                status = code
            }
            let attempts = FixtureProtocol.requests().count - before
            check(status == 429 && attempts == 1,
                  "HTTP 429 is not retried; status=\(status), attempts=\(attempts)")
        // A refusal whose explanation breaks off or stalls after the headers is still the refusal:
        // one request and its status. A connection lost before any response leaves the status
        // unknown, and uBit does not send the request again.
        case "refusal-body-reset", "refusal-body-stall", "lost-before-response":
            let explanation = String(repeating: "Not available. ", count: 200)
            let origin = WireOrigin { connection, number, _ in
                switch mode {
                case "refusal-body-reset":
                    WireOrigin.transmit(connection, "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nbb8\r\n" + explanation + "\r\n")
                    usleep(100_000)
                    WireOrigin.reset(connection)
                case "refusal-body-stall" where number == 1:
                    WireOrigin.transmit(connection, "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 50000\r\nConnection: close\r\n\r\n" + explanation)
                    sleep(45)
                    close(connection)
                case "refusal-body-stall":
                    WireOrigin.transmit(connection, "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 3000\r\nConnection: close\r\n\r\n" + explanation)
                    close(connection)
                default:
                    WireOrigin.reset(connection)
                }
            }
            var status = 0
            var failure: Error?
            do {
                _ = try await HTTPClient().fetchData(url: "http://127.0.0.1:\(origin.port)/unavailable", retries: 3)
            } catch HTTPError.status(let code, _) {
                status = code
            } catch { failure = error }
            if mode == "lost-before-response" {
                // URLSession itself can repeat a request whose connection closed before any
                // response byte, and how often depends on the OS. A raw URLSession request on
                // the same runtime is the control: uBit may add no attempt of its own.
                let control = WireOrigin { connection, _, _ in WireOrigin.reset(connection) }
                _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(control.port)/unavailable")!)
                var unknown = false
                if case HTTPError.noStatus? = failure as? HTTPError { unknown = true }
                check(status == 0 && unknown && origin.requests == control.requests,
                      "a connection lost before any status ends with an unknown status and no attempt of uBit's own; requests=\(origin.requests), one-request control=\(control.requests), error=\(String(describing: failure))")
            } else {
                check(status == 403 && origin.requests == 1,
                      "a 403 ends the request at its headers, whatever happens to its body; status=\(status), requests=\(origin.requests), error=\(String(describing: failure))")
            }
        // A refused range ends the whole transfer: no worker requests that range again, and no
        // final file is left. The other ranges answer only after the refusal.
        case "range-refusal":
            final class Ranges: @unchecked Sendable {
                private let lock = NSLock()
                private var seen: [String: Int] = [:]
                private var refusedRange: String?
                /// Records `range` and returns true when it is the first range after the probe.
                func add(_ range: String) -> Bool {
                    lock.withLock {
                        seen[range, default: 0] += 1
                        guard range != "bytes=0-0", refusedRange == nil || refusedRange == range else { return false }
                        refusedRange = range
                        return true
                    }
                }
                var all: [String: Int] { lock.withLock { seen } }
                var refused: String? { lock.withLock { refusedRange } }
            }
            let ranges = Ranges()
            let size = 1 << 20
            let refusal = DispatchSemaphore(value: 0)
            let origin = WireOrigin { connection, _, request in
                let range = request.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("range:") }
                    .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
                let refuse = ranges.add(range)
                if range == "bytes=0-0" {
                    WireOrigin.transmit(connection, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/\(size)\r\nETag: \"e1\"\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
                } else if refuse {
                    WireOrigin.transmit(connection, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    refusal.signal()
                } else {
                    _ = refusal.wait(timeout: .now() + 5)
                    refusal.signal()
                    usleep(400_000)
                    let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                    if bounds.count == 2 {
                        let length = bounds[1] - bounds[0] + 1
                        WireOrigin.transmit(connection, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(bounds[0])-\(bounds[1])/\(size)\r\nETag: \"e1\"\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: length))
                    }
                }
                close(connection)
            }
            let file = AppPaths.appSupportDir.appendingPathComponent("range-refusal.bin")
            var failure: Error?
            do {
                try await HTTPClient().downloadFile(url: "http://127.0.0.1:\(origin.port)/refused.bin", destination: file, connections: 2)
            } catch { failure = error }
            let seen = ranges.all
            let refused = ranges.refused ?? ""
            check(httpStatus(failure) == 403 && seen[refused] == 1 && !FileManager.default.fileExists(atPath: file.path),
                  "a refused range is requested once and ends the transfer without a final file; refused=\(refused), ranges=\(seen), error=\(String(describing: failure))")
        // URLSession can hold a response until some of its body arrives. A 403 that sends its
        // headers and then no body reaches uBit as a timeout, so its status is unknown; neither
        // fetchData, a probe, a parallel range worker nor a single stream sends that request
        // again. A repeated request would get the whole refusal at once.
        case "refusal-headers-only":
            final class Counts: @unchecked Sendable {
                private let lock = NSLock()
                private var seen: [String: Int] = [:]
                func add(_ key: String) -> Int { lock.withLock { seen[key, default: 0] += 1; return seen[key]! } }
                var all: [String: Int] { lock.withLock { seen } }
            }
            let refusal = "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 16\r\nConnection: close\r\n\r\n"
            let single = WireOrigin { connection, number, _ in
                WireOrigin.transmit(connection, refusal)
                if number == 1 { sleep(45) } else { WireOrigin.transmit(connection, "Not available.\r\n") }
                close(connection)
            }
            let ranges = Counts()
            let size = 1 << 20
            let parallel = WireOrigin { connection, _, request in
                let range = request.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("range:") }
                    .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
                if range == "bytes=0-0" {
                    WireOrigin.transmit(connection, "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/\(size)\r\nETag: \"e1\"\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
                } else if ranges.add(range) == 1 {
                    WireOrigin.transmit(connection, refusal)
                    sleep(45)
                } else {
                    WireOrigin.transmit(connection, refusal + "Not available.\r\n")
                }
                close(connection)
            }
            // Every request to `probe` gets the refusal headers. `stream` answers its probe without
            // byte ranges, so the download uses one stream, and that stream gets them.
            let probe = WireOrigin { connection, _, _ in
                WireOrigin.transmit(connection, refusal)
                sleep(45)
                close(connection)
            }
            let stream = WireOrigin { connection, number, _ in
                if number == 1 {
                    WireOrigin.transmit(connection, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd")
                } else {
                    WireOrigin.transmit(connection, refusal)
                    sleep(45)
                }
                close(connection)
            }
            let file = AppPaths.appSupportDir.appendingPathComponent("headers-only.bin")
            let probeFile = AppPaths.appSupportDir.appendingPathComponent("headers-only-probe.bin")
            let streamFile = AppPaths.appSupportDir.appendingPathComponent("headers-only-stream.bin")
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            async let fetchFailure: Error? = {
                do { _ = try await HTTPClient().fetchData(url: "http://127.0.0.1:\(single.port)/unavailable", retries: 3) } catch { return error }
                return nil
            }()
            async let downloadFailure: Error? = {
                do { try await HTTPClient().downloadFile(url: "http://127.0.0.1:\(parallel.port)/unavailable.bin", destination: file, connections: 2) } catch { return error }
                return nil
            }()
            async let probeFailure: Error? = {
                do { try await HTTPClient().downloadFile(url: "http://127.0.0.1:\(probe.port)/unavailable.bin", destination: probeFile, connections: 2) } catch { return error }
                return nil
            }()
            async let streamFailure: Error? = {
                do { try await HTTPClient().downloadFile(url: "http://127.0.0.1:\(stream.port)/unavailable.bin", destination: streamFile, connections: 2) } catch { return error }
                return nil
            }()
            func unknownStatus(_ error: Error?) -> Bool {
                if case HTTPError.noStatus? = error as? HTTPError { return true }
                return false
            }
            let (first, second, third, fourth) = await (fetchFailure, downloadFailure, probeFailure, streamFailure)
            check(unknownStatus(first) && single.requests == 1,
                  "fetchData does not repeat a request whose headers arrived without a body; requests=\(single.requests), error=\(String(describing: first))")
            let seen = ranges.all
            check(unknownStatus(second) && !seen.isEmpty && seen.values.allSatisfy { $0 == 1 },
                  "a range worker does not repeat a range whose headers arrived without a body; ranges=\(seen), error=\(String(describing: second))")
            check(unknownStatus(third) && probe.requests == 1,
                  "a probe whose status is unknown is not repeated; requests=\(probe.requests), error=\(String(describing: third))")
            check(unknownStatus(fourth) && stream.requests == 2,
                  "a single stream whose status is unknown is not repeated; requests=\(stream.requests), error=\(String(describing: fourth))")
        // A 403 whose connection is lost before uBit reads the status is not repeated.
        case "lost-after-headers":
            var failure: Error?
            do {
                _ = try await HTTPClient().fetchData(url: "https://media.invalid/lost-after-headers", retries: 3)
            } catch { failure = error }
            let attempts = FixtureProtocol.requests().filter { $0.url.path == "/lost-after-headers" }.count
            var unknown = false
            if case HTTPError.noStatus? = failure as? HTTPError { unknown = true }
            check(unknown && attempts == 1,
                  "a lost connection before the status allows no other request; attempts=\(attempts), error=\(String(describing: failure))")
        // Only a failure that proves that the request never reached the server is repeated.
        // A timeout proves nothing, so it ends the request after one attempt.
        case "transport-unreached", "transport-timeout":
            var failure: Error?
            var body = Data()
            do {
                body = try await HTTPClient().fetchData(url: "https://fixture.invalid/transport", retries: 3).0
            } catch { failure = error }
            let attempts = FixtureProtocol.requests().filter { $0.url.path == "/transport" }.count
            if mode == "transport-unreached" {
                check(failure == nil && body == Data("reached".utf8) && attempts == 2,
                      "a connection that could not open is tried again; attempts=\(attempts), error=\(String(describing: failure))")
            } else {
                var unknown = false
                if case HTTPError.noStatus? = failure as? HTTPError { unknown = true }
                check(unknown && attempts == 1,
                      "a timeout before the status is not repeated; attempts=\(attempts), error=\(String(describing: failure))")
            }
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
            // The waiter that reserved before cancellation must precede the newcomer.
            let pacer = YouTubeExtractor.YTGuard()
            let start = now()
            try await pacer.pace()
            var waiters: [Task<TimeInterval, Error>] = []
            for _ in 0..<3 {
                waiters.append(Task { try await pacer.pace(); return now() })
                try await Task.sleep(nanoseconds: 100_000_000)   // reserve the slots in this order
            }
            waiters[1].cancel()
            _ = await waiters[1].result
            try await pacer.pace()
            let newcomer = now()
            let first = try await waiters[0].value
            let older = try await waiters[2].value
            let offsets = [start, first, older, newcomer].map { $0 - start }
            check(first < older && older < newcomer && keepsSlots(offsets),
                  "the older waiter receives its permit before the newcomer; offsets in reservation order=\(offsets)")
        case "pace-late-wake":
            // Delay the waiters for the 3 s and 6 s slots until both can resume.
            // Record when each caller returns from pace(), not when HTTP starts.
            // Require a late wake-up to exercise the second check, and allow 0.5 s
            // for scheduling between the permit grant and its observation here.
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
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                _ = Task.detached { usleep(7_000_000) }
            }
            for waiter in waiters { _ = await waiter.result }
            let offsets = log.all().map { $0 - start }.sorted()
            let gaps = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
            check(offsets.count == 4 && offsets[1] > 6 && gaps.allSatisfy { $0 >= 2.5 },
                  "late waiters observe separate pacing permits; return offsets=\(offsets), gaps=\(gaps)")
        case "wall-unusable-cookie":
            // The bot wall is terminal for every cookie form: an expired or empty SAPISID, or a
            // nonempty root SAPISID that an empty /youtubei SAPISID shadows.
            let expired = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", expires: 1, name: "SAPISID", value: "fixture-only")]))
            let empty = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "")]))
            let shadowed = HTTPClient(cookies: CookieVault(entries: [
                CookieEntry(domain: ".youtube.com", path: "/", name: "SAPISID", value: "fixture-only"),
                CookieEntry(domain: ".youtube.com", path: "/youtubei", name: "SAPISID", value: ""),
            ]))
            var stopped = 0
            for client in [expired, empty, shadowed] {
                let error = await extractError(client)
                if closedByBotGate(error) { stopped += 1 }
            }
            let players = FixtureProtocol.playerRequests().count
            check(stopped == 3 && players == 0,
                  "an expired, empty or shadowed sign-in cookie still stops at the watch-page wall; stopped=\(stopped), player requests=\(players)")
        case "auth-header":
            // The fixture answers every odd /player request with an ordinary empty result, so each
            // extraction asks two client profiles. Only a usable SAPISID may be sent as SAPISIDHASH.
            let expired = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", expires: 1, name: "SAPISID", value: "fixture-only")]))
            let valid = HTTPClient(cookies: CookieVault(entries: [CookieEntry(domain: ".youtube.com", name: "SAPISID", value: "fixture-only")]))
            for vault in [CookieVault(), valid.cookies] {
                let override = HTTPClient(cookies: vault, extraHeaders: ["cOoKiE": "theme=light"])
                let before = FixtureProtocol.requests().count
                var refused = false
                do { _ = try await extract(client: override) } catch ExtractorError.unsupported { refused = true }
                check(refused && FixtureProtocol.requests().count == before,
                      "an explicit Cookie header makes no request, with or without stored cookies")
            }
            _ = try await extract(client: expired)
            _ = try await extract(client: valid)
            let sent = FixtureProtocol.playerRequests().map(\.authorization)
            check(sent == [false, false, false, true],
                  "an expired SAPISID sends no Authorization header and a valid one does; Authorization per /player request=\(sent)")

        // Report 1 #5 / report 2 #4: cache is per request context and honours cancellation.
        case "cache":
            let first = try await extract()
            FixtureProtocol.setTitle("second")
            let second = try await extract()
            let players = FixtureProtocol.playerRequests().count
            check(players == 1 && first.title == second.title,
                  "the same request context reuses cached metadata; player requests=\(players)")
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

        // A valid direct download still works, and the watch request makes no verification claim.
        case "normal":
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            check(error == nil && bytes == FixtureProtocol.mediaBytes,
                  "a working direct URL downloads over plain HTTP; error=\(String(describing: error))")
        case "watch-flags":
            _ = try await extract()
            let names = watchQueryNames()
            check(!names.contains("has_verified"),
                  "the watch request sends no unconfirmed verification flag; query flags=\(names)")
        case "cancel-download":
            let (file, error) = await download(audioExt: "webm")
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check((error as? URLError)?.code == .cancelled && file == nil && finalOutputs().isEmpty
                    && paths == ["/watch", "/youtubei/v1/player", "/media", "/media"],
                  "transport cancellation stops the download, makes no later request and saves no final output; error=\(String(describing: error)), paths=\(paths), saved=\(finalOutputs())")
        case "hls-fallback", "hls-fallback-nowatch", "hls-fallback-watchlist", "hls-fallback-lateprofile":
            // The fallback uses an ordinary empty format list or a not-found direct format, never a
            // denial. Player data and a playlist can come from the watch page or a /player response.
            // Only hls-fallback-nowatch has neither, so only it fails.
            var formats: [String] = []
            var failure = ""
            do {
                formats = try await extract().formats.map { "\($0.id):\($0.proto.rawValue)" }
            } catch ExtractorError.notFound(let message) {
                failure = message
            }
            let missing = FixtureProtocol.requests().filter { $0.url.path == "/missing" }
            let denied = FixtureProtocol.requests().filter {
                $0.url.path == "/media" && [401, 403, 407, 410, 429, 451].contains($0.status)
            }
            let playlists = FixtureProtocol.requests().map(\.url.path).filter { $0.hasSuffix(".m3u8") }
            // A profile playlist outranks the watch-page playlist; the watch-page playlist is
            // used only when no profile has one.
            let expected = ["hls-fallback": ["/profile.m3u8"], "hls-fallback-lateprofile": ["/profile.m3u8"],
                            "hls-fallback-watchlist": ["/watch.m3u8"], "hls-fallback-nowatch": []][mode] ?? []
            let ok = mode == "hls-fallback-nowatch"
                ? formats.isEmpty && !failure.isEmpty && missing.isEmpty && denied.isEmpty
                : !formats.isEmpty && formats.allSatisfy { $0.hasSuffix(":hls") } && failure.isEmpty
                    && denied.isEmpty && (mode != "hls-fallback-lateprofile" || missing.count == 1)
            check(ok && playlists == expected,
                  "the HLS playlist is used after an ordinary empty or not-found miss, never a denial, and a profile playlist outranks the watch page; formats=\(formats), failure=\(failure), missing=\(missing.count), denied=\(denied.map(\.status)), playlists=\(playlists)")
        case "dash-refusal":
            let dir = AppPaths.appSupportDir.appendingPathComponent("out")
            let file = dir.appendingPathComponent("video.mp4")
            func transfer(_ folder: String) async throws {
                try await DASHEngine.downloadRepresentation(client: HTTPClient(), mpdURL: "https://segments.invalid/\(folder)/clip.mpd", formatID: "dash-v", destination: file, connections: 1)
            }
            do { try await transfer("denied"); check(false, "DASH accepted a denied segment") }
            catch HTTPError.status(403, _) {}
            let afterFailure = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
            let requests = FixtureProtocol.requests().filter { $0.url.host == "segments.invalid" }.map(\.url.path)
            check(afterFailure.isEmpty && requests == ["/denied/clip.mpd", "/denied/piece-1.m4s", "/denied/piece-2.m4s"], "DASH stops at the denied segment without a final file: \(requests), \(afterFailure)")
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
        // One SIGINT while a command waits for metadata stops it at once with exit code 130, not
        // with a late success. One signal for each process: the second SIGINT ends the process.
        case "sigint-info", "sigint-formats", "sigint-get":
            let hold = DispatchSemaphore(value: 0)
            let origin = WireOrigin { connection, number, _ in
                if number == 1 { hold.wait() }
                let body = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nordinary.ts\n#EXT-X-ENDLIST\n"
                WireOrigin.transmit(connection, "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
                close(connection)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { hold.signal() }
            let command = String(mode.dropFirst("sigint-".count))
            var arguments = ["ubit", command, "--json", "--no-cookies"]
            if command == "get" { arguments += ["--no-library", "--keep-sponsors", "-o", AppPaths.appSupportDir.appendingPathComponent("out").path] }
            let run = Task { await CLIRunner.run(arguments: arguments + ["http://127.0.0.1:\(origin.port)/session.m3u8"]) }
            while origin.requests == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            let started = Date()
            kill(getpid(), SIGINT)
            let code = await run.value
            let elapsed = Date().timeIntervalSince(started)
            check(code == 130 && elapsed < 0.5,
                  "one SIGINT during the metadata request of \(command) exits 130 at once; code=\(code), elapsed=\(elapsed), requests=\(origin.requests)")
        case "proxy-values":
            // A proxy value that cannot be installed must not send the requests directly.
            let before = FixtureProtocol.requests().count
            let target = "https://fixture.invalid/must-not-contact"
            let formats = await CLIRunner.run(arguments: ["ubit", "formats", "--no-cookies", "--proxy", "--bogus", target])
            let info = await CLIRunner.run(arguments: ["ubit", "info", "--proxy", "127.0.0.1:9", target])
            let get = await CLIRunner.run(arguments: ["ubit", "get", "--proxy", "not a proxy", target])
            // A refused proxy URL can hold a password, so no message may repeat the value.
            let marker = "pw-marker-7f3a"
            let ((socks4, socks4a, getSocks4, settingsSocks4a), stderrText) = await capturingStderr {
                (await CLIRunner.run(arguments: ["ubit", "info", "--proxy", "socks4://user:\(marker)@127.0.0.1:9", target]),
                 await CLIRunner.run(arguments: ["ubit", "info", "--proxy", "socks4a://user:\(marker)@127.0.0.1:9", target]),
                 await CLIRunner.run(arguments: ["ubit", "get", "--proxy", "socks4://user:\(marker)@127.0.0.1:9", target]),
                 await CLIRunner.run(arguments: ["ubit", "settings", "proxy", "socks4a://user:\(marker)@127.0.0.1:9"]))
            }
            // A port outside 1...65535 cannot be installed either.
            let (highPort, zeroPort) = (
                await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "--proxy", "socks5://127.0.0.1:65536", target]),
                await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "--proxy", "http://127.0.0.1:0", target]))
            let added = FixtureProtocol.requests().count - before
            var settings = Settings()
            let storedBad = settings.setByKey("proxy", value: "bogus")
            let storedSocks4a = settings.setByKey("proxy", value: "socks4a://127.0.0.1:9")
            let storedHighPort = settings.setByKey("proxy", value: "socks5://127.0.0.1:65536")
            let storedGood = settings.setByKey("proxy", value: "socks5://127.0.0.1:9")
            _ = await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "--proxy", "socks5://127.0.0.1:9", "https://fixture.invalid/video"])
            _ = await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "--proxy", "SOCKS5://127.0.0.1", "https://fixture.invalid/video"])
            let resolved = FixtureProtocol.resolvedProxies()
            let routed = resolved.contains("\(kCFProxyTypeSOCKS as String) 127.0.0.1:9")
            let capitalPort = resolved.contains("\(kCFProxyTypeSOCKS as String) 127.0.0.1:1080")
            let leaked = stderrText.contains(marker)
            check(formats == 2 && info == 2 && get == 2 && socks4 == 2 && socks4a == 2 && getSocks4 == 2 && settingsSocks4a == 2
                    && highPort == 2 && zeroPort == 2
                    && added == 0 && !leaked && stderrText.contains("invalid")
                    && !storedBad && !storedSocks4a && !storedHighPort && storedGood && routed && capitalPort,
                  "invalid proxies exit 2 before any request without repeating the value, settings refuse them, valid ones are installed and a capital SOCKS5 scheme gets port 1080; formats=\(formats), info=\(info), get=\(get), socks4=\(socks4), socks4a=\(socks4a), getSocks4=\(getSocks4), settings=\(settingsSocks4a), port 65536=\(highPort), port 0=\(zeroPort), requests=\(added), password in stderr=\(leaked), storedBad=\(storedBad), storedSocks4a=\(storedSocks4a), storedHighPort=\(storedHighPort), resolved=\(resolved)")
        case "proxy-stored":
            // A proxy that was stored before validation existed (or typed into settings.json)
            // must fail the command, not send the request without a proxy. Its error must not
            // repeat the stored value, which can hold a password.
            let marker = "pw-marker-c41e"
            var settings = Settings.load()
            settings.proxy = "socks4://user:\(marker)@127.0.0.1:9"
            try settings.save()
            let before = FixtureProtocol.requests().count
            let (info, stderrText) = await capturingStderr {
                await CLIRunner.run(arguments: ["ubit", "info", "--no-cookies", "https://fixture.invalid/must-not-contact"])
            }
            let added = FixtureProtocol.requests().count - before
            let leaked = stderrText.contains(marker)
            check(info != 0 && added == 0 && !leaked && stderrText.contains("invalid proxy"),
                  "a stored invalid proxy fails the command before any request without repeating the value; exit=\(info), requests=\(added), password in stderr=\(leaked), stderr=\(stderrText)")

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
