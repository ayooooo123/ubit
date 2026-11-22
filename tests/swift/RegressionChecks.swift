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
    static let parallelBytes = Data((0..<614_400).map { UInt8(truncatingIfNeeded: ($0 / 1021) ^ $0) })
    static let mediaBytes = Data("fixture-media-payload-for-the-http-path".utf8)
    /// An untagged object 1 MiB larger than the live recorder's 64 MiB copy budget. Its first
    /// KiB holds "A" and its last KiB holds "Z".
    static let oversized: Data = {
        var bytes = Data(count: 65 << 20)
        bytes.replaceSubrange(0..<1024, with: Data(repeating: 0x41, count: 1024))
        bytes.replaceSubrange((bytes.count - 1024)..<bytes.count, with: Data(repeating: 0x5A, count: 1024))
        return bytes
    }()
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
        var failure: URLError?
        var redirect: URL?
        var lostAfterResponse = false

        switch (url.host ?? "", url.path) {
        case ("cdn.syndication.twimg.com", "/tweet-result"), ("instance.invalid", "/api/v1/videos/fixture"), ("i.imgur.com", "/abc123.mp4"):
            status = 403
        case ("metadata.invalid", _), ("sponsor.ajay.app", _):
            status = 403
        case ("media.invalid", "/live-editions.m3u8"):
            let seq = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
            let segment = mode.hasPrefix("hls-live-whole")
                ? (seq == 0 ? "pack.ts" : "#EXT-X-BYTERANGE:2@2\npack.ts\n#EXT-X-ENDLIST")
                : (seq == 0 ? "#EXT-X-BYTERANGE:2@0\npack.ts" : (seq == 1 ? "other.ts" : "#EXT-X-BYTERANGE:2@2\npack.ts\n#EXT-X-ENDLIST"))
            data = Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(seq)\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n\(segment)\n".utf8)
        case ("media.invalid", "/other.ts"): data = Data("xx".utf8)
        case ("media.invalid", "/hop.m3u8"):
            data = Data("#EXTM3U\n#EXTINF:2,\n#EXT-X-BYTERANGE:2@0\nhop.ts\n#EXTINF:2,\n#EXT-X-BYTERANGE:2@2\nhop.ts\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/hop-live.m3u8"):
            // The first poll lists the whole object; the second lists a range of it and ends.
            let seq = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
            let segment = seq == 0 ? "hop.ts" : "#EXT-X-BYTERANGE:2@2\nhop.ts\n#EXT-X-ENDLIST"
            data = Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(seq)\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n\(segment)\n".utf8)
        case ("media.invalid", "/hop.ts"), ("media.invalid", "/hop.bin"):
            // A redirector that alternates between two mirrors. Both mirrors name their copy
            // with the same ETag text, but the copies hold different bytes.
            let n = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
            redirect = URL(string: "https://media.invalid/mirror-\(n % 2 == 0 ? "a" : "b").\(url.pathExtension)")
        case ("media.invalid", let path) where path.hasPrefix("/mirror-"):
            let second = path.hasPrefix("/mirror-b")
            let body = path.hasSuffix(".ts")
                ? Data((second ? "BBBB" : "AAAA").utf8)
                : (second ? Data(Self.parallelBytes.map { ~$0 }) : Self.parallelBytes)
            headers["ETag"] = "\"same\""
            if let range {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2 else { status = 400; break }
                let high = min(bounds[1], body.count - 1)
                status = 206
                headers["Content-Range"] = "bytes \(bounds[0])-\(high)/\(body.count)"
                data = body.subdata(in: bounds[0]..<(high + 1))
            } else { data = body }
        case ("media.invalid", "/event.m3u8"):
            // An EVENT playlist keeps every past entry. The first poll lists three
            // entries; the second lists all of them and ends the recording.
            let poll = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
            if mode == "hls-event-oversized" {
                // One untagged object larger than the copy budget, read in two ranges at its ends.
                let tail = "#EXTINF:1,\n#EXT-X-BYTERANGE:1024@\(Self.oversized.count - 1024)\nbig.bin\n#EXT-X-ENDLIST\n"
                data = Data(("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n"
                    + "#EXTINF:1,\n#EXT-X-BYTERANGE:1024@0\nbig.bin\n" + (poll == 0 ? "" : tail)).utf8)
                break
            }
            let ranged = mode == "hls-event-ranged"
            let count = poll == 0 ? 3 : (ranged ? 70 : 64)
            var text = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n"
            for i in 0..<count { text += "#EXTINF:1,\n" + (ranged ? "#EXT-X-BYTERANGE:1024@0\n" : "") + "ev-\(i).bin\n" }
            if poll > 0 {
                if ranged { text += "#EXTINF:1,\n#EXT-X-BYTERANGE:1024@1024\nev-0.bin\n" }
                text += "#EXT-X-ENDLIST\n"
            }
            data = Data(text.utf8)
        case ("media.invalid", "/big.bin"):
            if let range {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2 else { status = 400; break }
                status = 206
                headers["Content-Range"] = "bytes \(bounds[0])-\(bounds[1])/\(Self.oversized.count)"
                data = Self.oversized.subdata(in: bounds[0]..<(bounds[1] + 1))
            } else { data = Self.oversized }
        case ("media.invalid", let path) where path.hasPrefix("/ev-"):
            // 1 MiB untagged objects; object N holds only the byte N.
            let body = Data(repeating: UInt8(Int(path.dropFirst(4).dropLast(4)) ?? 255), count: 1 << 20)
            if let range {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2 else { status = 400; break }
                status = 206
                headers["Content-Range"] = "bytes \(bounds[0])-\(bounds[1])/\(body.count)"
                data = body.subdata(in: bounds[0]..<(bounds[1] + 1))
            } else { data = body }
        case ("media.invalid", "/clock/master.m3u8"):
            data = Data("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"main\",DEFAULT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=700000,RESOLUTION=128x96,CODECS=\"avc1.42c00a,mp4a.40.2\",AUDIO=\"a\"\nvideo.m3u8\n".utf8)
        case ("media.invalid", let path) where path.hasPrefix("/clock/"):
            let name = url.deletingPathExtension().lastPathComponent
            let audio = name.hasPrefix("audio"), mux = name.hasPrefix("mux")
            switch url.pathExtension {
            case "m3u8":
                let durations = audio ? ["0.618667", "0.597333", "0.597333", "0.597333", "1.6"] : ["2", "2"]
                var text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MAP:URI=\"\(name).mp4\"\n"
                for (i, duration) in durations.enumerated() { text += "#EXTINF:\(duration),\n\(name)-\(i).m4s\n" }
                data = Data((text + "#EXT-X-ENDLIST\n").utf8)
            case "mp4":
                let tracks = (audio ? [] : Bytes.clipTrak(timescale: 10, video: true, id: 1))
                    + (audio || mux ? Bytes.clipTrak(timescale: 48000, video: false, id: 2) : [])
                data = Data(Bytes.ftyp + Bytes.box("moov", tracks))
            case "m4s":
                let i = Int(name.split(separator: "-").last!)!
                func fragment(_ range: Range<Int>, _ id: UInt32, _ duration: UInt32) -> [UInt8] {
                    // Nonzero decode epochs: subtract the first tfdt, not an assumed zero.
                    let time = UInt32(range.lowerBound) * duration + id * 50000
                    return Bytes.renditionFragment(range.map(UInt8.init), video: id == 1, trackID: id, ticks: duration, start: time)
                }
                let bounds = audio ? [0, 29, 57, 85, 113, 188] : [0, 94, 188]
                let pictures = audio ? [] : fragment(i*20..<(i+1)*20, 1, 1)
                let sound = audio || mux ? fragment(bounds[i]..<bounds[i+1], 2, 1024) : []
                data = Data(pictures + sound)
            default: status = 404
            }
        case ("media.invalid", "/paired.m3u8"):
            data = Data("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"main\",DEFAULT=YES,URI=\"sound.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=700000,RESOLUTION=128x96,CODECS=\"avc1.42c00a,mp4a.40.2\",AUDIO=\"a\"\npicture.m3u8\n".utf8)
        case ("media.invalid", "/picture.m3u8"), ("media.invalid", "/sound.m3u8"):
            let picture = url.path == "/picture.m3u8"
            let first = Bytes.renditionFragment([0, 1, 2, 3], video: true).count
            let unit = Bytes.renditionFragment([40], video: false).count
            var list = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"\(picture ? "picture" : "sound").mp4\"\n"
            for i in 0..<(picture ? 1 : 4) {
                list += "#EXTINF:\(picture ? 4 : 1),\n#EXT-X-BYTERANGE:\(picture ? first : unit)@\(picture ? 0 : first + unit*i)\npaired.pack\n"
            }
            data = Data((list + "#EXT-X-ENDLIST\n").utf8)
        case ("media.invalid", "/picture.mp4"), ("media.invalid", "/sound.mp4"):
            data = Data(Bytes.clipInit(sampleTicks: 1000, video: url.path == "/picture.mp4"))
        case ("media.invalid", "/paired.pack"):
            let changed = mode.contains("changed") && Self.lock.withLock { Self.seen.contains { $0.url.path == "/sound.m3u8" } }
            let base: UInt8 = changed || mode.hasSuffix("-b") ? 100 : 0
            let body = Bytes.renditionFragment((0..<4).map { base + $0 }, video: true)
                + (40..<44).flatMap { Bytes.renditionFragment([base + $0], video: false) }
            if mode.contains("tagged") { headers["ETag"] = "\"\(base)\"" }
            if let range {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] < body.count else { status = 416; break }
                let last = min(bounds[1], body.count - 1)
                headers["Content-Range"] = "bytes \(bounds[0])-\(last)/\(body.count)"
                status = 206
                data = Data(body[bounds[0]...last])
            } else { data = Data(body) }
        case ("media.invalid", "/editions.m3u8"):
            data = Data("#EXTM3U\n#EXTINF:2,\n#EXT-X-BYTERANGE:2@0\npack.ts\n#EXTINF:2,\n#EXT-X-BYTERANGE:2@2\npack.ts\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/repeat.m3u8"):
            data = Data("#EXTM3U\n#EXTINF:2,\npack.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\npack.ts\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/alias.m3u8"):
            // Four spellings of one HTTP resource: a fragment, empty user information and a default port.
            data = Data("#EXTM3U\n#EXTINF:2,\npack.ts\n#EXTINF:2,\npack.ts#\n#EXTINF:2,\nhttps://@media.invalid/pack.ts\n#EXTINF:2,\nhttps://media.invalid:443/pack.ts\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/alias-userinfo.m3u8"):
            // Empty user information does not reach the origin: both lines request one resource.
            data = Data("#EXTM3U\n#EXTINF:2,\npack.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\nhttps://@media.invalid/pack.ts\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/live-alias.m3u8"):
            let seq = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
            let segment = seq == 0 ? "pack.ts" : "https://@media.invalid/pack.ts\n#EXT-X-ENDLIST"
            data = Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(seq)\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n\(segment)\n".utf8)
        case ("media.invalid", "/routes.m3u8"):
            data = Data("#EXTM3U\n#EXTINF:2,\nroute.ts?object=ab%2fCD\n#EXTINF:2,\nroute.ts?object=ab%2FCD\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/route.ts"):
            // Two request targets that differ only in the case of an escape hold different objects.
            switch URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery {
            case "object=ab%2fCD": data = Data("AAAA".utf8)
            case "object=ab%2FCD": data = Data("BBBB".utf8)
            default: status = 404
            }
        case ("media.invalid", "/dots.m3u8"):
            data = Data("#EXTM3U\n#EXTINF:2,\n#EXT-X-BYTERANGE:2@0\nhttps://media.invalid/a/../dots.ts\n#EXTINF:2,\n#EXT-X-BYTERANGE:2@0\ndots.ts\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/live-dots.m3u8"):
            let seq = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
            let segment = seq == 0 ? "#EXT-X-BYTERANGE:2@0\nhttps://media.invalid/a/../dots.ts" : "#EXT-X-BYTERANGE:2@0\ndots.ts\n#EXT-X-ENDLIST"
            data = Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(seq)\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n\(segment)\n".utf8)
        case ("media.invalid", "/v6.m3u8"):
            // hls-v6-scope reads one loopback address with and without a zone, whole. hls-v6-forms
            // reads byte ranges from two spellings of one address that send different Host fields.
            let (first, second, range) = mode == "hls-v6-scope" ? ("[::1]", "[::1%25lo0]", "") : ("[::1]", "[0:0:0:0:0:0:0:1]", "#EXT-X-BYTERANGE:2@0\n")
            data = Data("#EXTM3U\n#EXTINF:2,\n\(range)https://\(first)/v6.ts\n#EXTINF:2,\n\(range)https://\(second)/v6.ts\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/live-v6.m3u8"):
            let seq = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
            let segment = seq == 0 ? "https://[::1]/v6.ts" : "https://[::1%25lo0]/v6.ts\n#EXT-X-ENDLIST"
            data = Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(seq)\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n\(segment)\n".utf8)
        case ("media.invalid", "/dots.ts"), ("media.invalid", "/a/../dots.ts"), (_, "/v6.ts"):
            // URLSession sends an absolute path with dot segments as written, so this origin
            // routes the two targets separately. Neither object changes; only hls-live-dot-tagged
            // sends an ETag. Under a scoped and an unscoped address, /v6.ts is one object that
            // changes after its first read; under two Host forms, it is two fixed objects.
            let object: Data
            if url.path == "/v6.ts" {
                let reads = Self.lock.withLock { Self.seen.filter { $0.url.path == url.path }.count }
                object = Data((mode == "hls-v6-forms" ? url.host == "::1" : reads == 0) ? "AAAA".utf8 : "BBBB".utf8)
            } else {
                object = Data((url.path == "/dots.ts" && ["hls-dot-routes", "hls-live-dot-routes"].contains(mode) ? "BBBB" : "AAAA").utf8)
            }
            if mode == "hls-live-dot-tagged" { headers["ETag"] = "\"A\"" }
            if let range {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2 else { status = 400; break }
                status = 206
                headers["Content-Range"] = "bytes \(bounds[0])-\(bounds[1])/4"
                data = object.subdata(in: bounds[0]..<(bounds[1]+1))
            } else { data = object }
        case ("media.invalid", "/lost-after-headers"):
            // A 403 response, and then the connection is lost before any body byte.
            status = 403
            lostAfterResponse = true
        case ("media.invalid", "/pack.ts"):
            // hls-live-whole-changed: every read after the first comes from a new edition.
            let changed = range == "bytes=2-3" || Self.lock.withLock {
                (mode == "hls-live-changed" && Self.seen.contains { $0.url.path == url.path && $0.range == nil })
                    || (["hls-live-whole-changed", "hls-repeat-changed", "hls-alias-changed", "hls-userinfo-changed", "hls-live-userinfo"].contains(mode) && Self.seen.contains { $0.url.path == url.path })
            }
            let edition = Data((changed ? "BBBB" : "AAAA").utf8)
            if mode != "hls-untagged-edition" && !mode.hasPrefix("hls-live-") { headers["ETag"] = changed ? "\"B\"" : "\"A\"" }
            if let range {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2 else { status = 400; break }
                status = 206
                headers["Content-Range"] = "bytes \(bounds[0])-\(bounds[1])/4"
                data = edition.subdata(in: bounds[0]..<(bounds[1]+1))
            } else { data = edition }
        case ("media.invalid", "/parallel.bin"):
            if mode == "parallel-unvalidated", range == nil { data = Self.parallelBytes; break }
            if mode != "parallel-unvalidated" { headers["ETag"] = "\"stable-fixture\"" }
            guard let bounds = range?.dropFirst(6).split(separator: "-"), bounds.count == 2,
                  let low = Int(bounds[0]), let requested = Int(bounds[1]) else { status = 400; break }
            if mode == "parallel-cancel" && requested > 0 { failure = URLError(.cancelled); break }
            let high = mode == "parallel-short" ? min(low + 65_535, requested) : requested
            status = 206
            headers["Content-Range"] = "bytes \(low)-\(high)/\(Self.parallelBytes.count)"
            if mode == "parallel-unvalidated" && low > 0 {
                data = Data(repeating: 0, count: high - low + 1)
            } else { data = Self.parallelBytes.subdata(in: low..<(high + 1)) }
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
        case (_, "/watch"):
            if deniedStage == "watch" {
                status = deniedStatus
            } else {
                var player: [String: Any]? = Self.playerPayload(status: "OK", streaming: nil, title: title)
                switch mode {
                case "watch-gate", "wall-unusable-cookie", "watch-challenge-cookie":
                    player = Self.challengePlayer(1, title: title)
                case "watch-wall-text", "watch-blocked-text":
                    player = nil
                case "watch-wall-metadata", "watch-human-notice", "watch-age-notice", "watch-inline-age", "watch-blocked-notice", "watch-header-age",
                     "watch-verify-human", "watch-open-details", "watch-details-summary", "watch-confirm-identity",
                     "watch-identity-phone", "watch-age-device", "watch-age-parenthesis", "watch-identity-dash", "watch-identity-online",
                     "watch-identity-right-now", "watch-age-upon", "watch-age-footnote", "watch-purpose-clause", "watch-second-sentence", "watch-blocked-statement", "watch-blocked-video":
                    player = Self.playerPayload(status: "OK", streaming: Self.directStreaming(1, hls: true), title: title)
                case "hls-fallback-watchlist":
                    player = Self.hlsOnlyPlayer(title: title)
                case "hls-fallback-nowatch", "hls-fallback-lateprofile":
                    player = nil
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
                    || ["watch-gate", "wall-unusable-cookie", "watch-challenge-cookie",
                        "watch-wall-text", "watch-wall-metadata"].contains(mode)
                let visitor = omitVisitor ? nil : (mode == "visitor-reuse" ? Self.secondVisitor : Self.firstVisitor)
                switch mode {
                case "watch-wall-text", "watch-wall-metadata", "watch-human-notice", "watch-age-notice", "watch-inline-age",
                     "watch-blocked-text", "watch-blocked-notice", "watch-header-age", "watch-verify-human", "watch-open-details",
                     "watch-details-summary", "watch-confirm-identity", "watch-identity-phone", "watch-age-device",
                     "watch-age-parenthesis", "watch-identity-dash", "watch-identity-online", "watch-identity-right-now",
                     "watch-age-upon", "watch-age-footnote", "watch-purpose-clause", "watch-second-sentence", "watch-blocked-statement", "watch-blocked-video":
                    data = Self.wallPage(player: player, mode: mode)
                case "watch-inert-text", "watch-lesson-no-state", "watch-hidden-notice", "watch-closed-details", "watch-verification-lesson",
                     "watch-agent-settings", "watch-ordinary-objects", "watch-blocked-lesson":
                    data = Self.inertTextPage(player: mode == "watch-lesson-no-state" ? nil : player, visitor: visitor, mode: mode)
                default:
                    data = Self.watchPage(player: player, visitor: visitor)
                }
                if mode == "cancel-watch" { failure = URLError(.cancelled) }
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
            } else if mode == "pace-retry" && playerNumber == 1 {
                status = 503
            } else if ["watch-gate", "player-gate", "pace-concurrent", "wall-unusable-cookie", "watch-challenge-cookie", "player-challenge-cookie", "pace-retry"].contains(mode) {
                data = Self.json(Self.challengePlayer(playerNumber, title: "\(title)-\(playerNumber)"))
            } else if mode == "auth-header" && playerNumber % 2 == 1 {
                // An ordinary empty response, not a denial: extraction goes on to the next profile.
                data = Self.json(Self.emptyPlayer(title: title))
            } else if mode == "hls-fallback" {
                data = Self.json(Self.hlsOnlyPlayer(title: title))
            } else if mode == "hls-fallback-lateprofile" && playerNumber > 1 {
                data = Self.json(Self.hlsOnlyPlayer(title: title))
            } else if mode == "hls-fallback-lateprofile" {
                data = Self.json(Self.missingFormatPlayer(playerNumber, title: title))
            } else if ["hls-fallback-nowatch", "hls-fallback-watchlist"].contains(mode) {
                data = Self.json(Self.emptyPlayer(title: title))
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
        case ("media.invalid", "/hls.m3u8"):
            // A VOD playlist of 15 segments, 4 s each.
            let segments = (0..<15).map { "#EXTINF:4.0,\nseg-\($0).ts" }.joined(separator: "\n")
            data = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n\(segments)\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", let path) where path.hasPrefix("/partial/"):
            status = 206
            data = Data("bc".utf8)
            switch path {
            case "/partial/eof": headers["Content-Range"] = "bytes 1-2/3"
            case "/partial/short": headers["Content-Range"] = "bytes 1-2/6"
            case "/partial/shifted": headers["Content-Range"] = "bytes 2-3/4"
            default: headers["Content-Range"] = "bytes 1-3/4"
            }
        case ("media.invalid", let path) where path.hasPrefix("/seg-"):
            data = Data(path.utf8)
        case ("media.invalid", "/clip.m3u8"):
            // An HLS playlist of 15 fragmented MP4 segments, 4 s each, with four 1 s samples in each
            // segment. The boxes are the smallest tree that uBit's reader accepts, not a file that
            // a standard player can read (the stsd box is empty, and mvhd, tkhd and mfhd are missing).
            let duration = mode == "hls-ntsc" ? "1.001" : (mode == "hls-decimal" ? "0.800000" : "4.0")
            let count = mode == "hls-ntsc" ? 7 : 15
            let segments = (0..<count).map { "#EXTINF:\(duration),\nclip-\($0).m4s" }.joined(separator: "\n")
            data = Data("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"clip-init.mp4\"\n\(segments)\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/short-map.m3u8"), ("media.invalid", "/short-segment.m3u8"):
            let map = Bytes.clipInit(sampleTicks: 1000).count + 1
            let segment = Bytes.clipSegment(0).count + 1
            let mapRange = url.path == "/short-map.m3u8" ? ",BYTERANGE=\"\(map)@0\"" : ""
            let mediaRange = mapRange.isEmpty ? "#EXT-X-BYTERANGE:\(segment)@0\n" : ""
            data = Data("#EXTM3U\n#EXT-X-MAP:URI=\"clip-init.mp4\"\(mapRange)\n#EXTINF:4,\n\(mediaRange)clip-0.m4s\n#EXT-X-ENDLIST\n".utf8)
        case ("media.invalid", "/clip-init.mp4"):
            data = Data(Bytes.clipInit(sampleTicks: mode == "hls-decimal" ? 200 : 1000))
        case ("media.invalid", let path) where path.hasPrefix("/clip-"):
            data = Data(Bytes.clipSegment(Int(path.dropFirst(6).dropLast(4)) ?? 0))
        case ("media.invalid", let path) where ["/indexed.mp4", "/cut-200.mp4", "/cut-206.mp4", "/cut-unknown.mp4", "/cut-later.mp4", "/cut-padding.mp4", "/cut-empty.mp4", "/cut-stale.mp4", "/cut-duration.mp4"].contains(path):
            // sidx-untagged-change: every read after the first comes from a second edition.
            // sidx-untagged-grow: every read after the first comes from a longer second edition.
            let later = Self.lock.withLock { Self.seen.contains { $0.url.path == path } }
            let changed = mode == "sidx-untagged-change" && later
            let grown = mode == "sidx-untagged-grow" && later
            var bytes = mode == "sidx-fragments" || path == "/cut-later.mp4" || path == "/cut-padding.mp4" ? Bytes.fragmentIndexedClip
                : (changed ? Bytes.changedIndexedClip : grown ? Bytes.grownIndexedClip : Bytes.indexedClip)
            if mode == "sidx-padding" { bytes += Bytes.box("free", Array(repeating: 0, count: 24)) }
            if ["/cut-empty.mp4", "/cut-stale.mp4", "/cut-duration.mp4"].contains(path) {
                let table = MP4Muxer.parseSidx(in: Data(bytes))!.segments
                let offset = Int(table[1].byteRange.start)
                if path == "/cut-stale.mp4" {
                    bytes.replaceSubrange(offset..<(offset + Bytes.clipSegment(1).count), with: Bytes.clipSegment(2))
                } else {
                    let count = bytes[offset...].firstRange(of: Array("trun".utf8))!.upperBound + 4
                    bytes.replaceSubrange(count..<count + 4, with: Bytes.be32(path == "/cut-duration.mp4" ? 2 : 0))
                }
            } else if path == "/cut-later.mp4" || path == "/cut-padding.mp4" {
                let data = Data(bytes)
                let indexes = MP4Muxer.listBoxes(in: data, from: 0, to: data.count).filter { $0.type == "sidx" }
                let offset = indexes[2].endOffset
                if path == "/cut-later.mp4" {
                    bytes.removeSubrange(offset...)
                } else {
                    let length = Bytes.clipSegment(2).count
                    bytes.replaceSubrange(offset..<(offset + length), with: Bytes.box("free", Array(repeating: 0, count: length - 8)))
                }
            } else if path.hasPrefix("/cut-") { bytes.removeLast(13 * Bytes.clipSegment(0).count) }
            if path != "/cut-200.mp4", let range, let dash = range.firstIndex(of: "-"),
               let start = Int(range.dropFirst(6).prefix(while: { $0 != "-" })),
               let end = Int(range[range.index(after: dash)...]), start < bytes.count {
                let last = min(end, bytes.count - 1)
                status = 206
                let total = path == "/cut-unknown.mp4" && range == "bytes=0-65535" ? "*" : String(bytes.count)
                headers["Content-Range"] = "bytes \(start)-\(last)/\(total)"
                data = Data(bytes[start...last])
            } else { data = Data(bytes) }
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
        if let redirect {
            var next = request
            next.url = redirect
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            client!.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        if let failure {
            client!.urlProtocol(self, didFailWithError: failure)
            return
        }
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if lostAfterResponse {
            client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
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

    static func hlsStreaming() -> [String: Any] {
        ["hlsManifestUrl": "https://media.invalid/clip.m3u8"]
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

    static func emptyPlayer(title: String) -> [String: Any] {
        playerPayload(status: "OK", streaming: ["adaptiveFormats": [Any]()], title: title)
    }

    static func hlsOnlyPlayer(title: String) -> [String: Any] {
        playerPayload(status: "OK", streaming: hlsStreaming(), title: title)
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

    /// A verification wall whose only signal is visible page text. `player` is optional, so one
    /// variant also carries embedded metadata that reports ordinary playback.
    static func wallPage(player: [String: Any]?, mode: String) -> Data {
        var html = "<html><head><title>Verification required</title></head><body>"
        switch mode {
        case "watch-human-notice": html += "<h1>Confirm you're not a bot</h1>"
        case "watch-inline-age": html += "<p>Please verify <span>your</span> age to play this video.</p>"
        case "watch-age-notice": html += "<p>Please verify your age to play this video.</p>"
        case "watch-blocked-text", "watch-blocked-notice": html += "<div>Playback is blocked until verification is complete.</div>"
        case "watch-header-age": html += "<header>Music lessons</header><main><div>Please verify your age to play this video.</div></main>"
        case "watch-verify-human": html += "<main role=\"alert\"><p>Please verify that you are human to continue.</p></main>"
        case "watch-open-details": html += "<h1>Music lesson</h1><details open><summary>Help</summary><p>Please verify your age to play this video.</p></details>"
        case "watch-details-summary": html += "<details><summary>Verify your age to play this video.</summary><p>Help</p></details>"
        case "watch-confirm-identity": html += "<main><p>Please confirm your identity to continue watching.</p></main>"
        case "watch-identity-phone": html += "<main role=\"alert\"><p>Please confirm your identity using your phone to continue watching.</p></main>"
        case "watch-age-device": html += "<main role=\"alert\"><p>Verify your age on this device to continue watching.</p></main>"
        case "watch-age-parenthesis": html += "<main role=\"alert\"><p>Verify your age (18 or older) to continue watching.</p></main>"
        case "watch-identity-dash": html += "<main role=\"alert\"><p>Confirm your identity — this is required to watch the video.</p></main>"
        case "watch-identity-online": html += "<main role=\"alert\"><p>Please confirm your identity online to continue watching.</p></main>"
        case "watch-identity-right-now": html += "<main role=\"alert\"><p>Confirm your identity right now to continue watching.</p></main>"
        case "watch-age-upon": html += "<main role=\"alert\"><p>Please verify your age upon signing in to watch this video.</p></main>"
        case "watch-age-footnote": html += "<main role=\"alert\"><p>Verify your age<sup>1</sup> to continue watching.</p></main>"
        case "watch-purpose-clause": html += "<main role=\"alert\"><p>To continue watching, please verify your age.</p></main>"
        case "watch-second-sentence": html += "<main role=\"alert\">Playback unavailable. Please verify your age to continue watching.</main>"
        case "watch-blocked-statement": html += "<main role=\"alert\">Playback is blocked.</main>"
        case "watch-blocked-video": html += "<main role=\"alert\">Playback is blocked for this video.</main>"
        default: html += "<main>Verify your identity before playback can continue. Playback is blocked.</main>"
        }
        if let player {
            let json = String(data: try! JSONSerialization.data(withJSONObject: player), encoding: .utf8)!
            html += "<script>var ytInitialPlayerResponse = \(json);</script>"
        }
        return Data((html + "</body></html>").utf8)
    }

    /// An ordinary page: challenge words appear only where a reader cannot see them, that is in
    /// the title, the meta description, the video description, page code and a comment. Some
    /// modes add body content: notices and a widget under hidden elements, a notice in the body
    /// of a closed `<details>`, or a lesson that explains verification without asking for it.
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
        case "watch-closed-details":
            html += "<h1>Music lesson</h1><details><summary>Help</summary><p>Please verify your age to play this video.</p></details>"
        case "watch-blocked-lesson":
            html += "<article>This lesson explains why playback is blocked during device verification.</article>"
        case "watch-verification-lesson":
            html += "<article><h1>Uploading a video</h1><p>This lesson explains why an upload remains private until verification is complete.</p></article>"
        case "watch-agent-settings":
            html += "<article><h1>Remote playback</h1><p>Verify your agent settings, then try again.</p><p>Verify your audio settings.</p></article>"
        case "watch-ordinary-objects":
            html += "<article><h1>Storage setup</h1><p>Confirm your identity provider settings before you save the configuration.</p><p>Confirm your identity-provider settings before you save the configuration.</p><p>Verify the cable is not a bottleneck for the disk.</p><p>Verify your age group settings in the family profile.</p></article>"
        default: break
        }
        if mode == "watch-hidden-notice" {
            html += "<!-- Optional g-recaptcha component not loaded. -->"
            html += "<div hidden><p>Please verify your age to play this video.</p></div>"
            html += "<dialog><p>Confirm you're not a bot</p></dialog>"
            html += "<div style=\"display: none\"><div class=\"g-recaptcha\"></div></div>"
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

    static let ftyp = be32(16) + Array("ftypisom".utf8) + be32(0)

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload }

    /// The track uses 1000 ticks per second and one byte per sample.
    static func clipInit(sampleTicks: UInt32, timescale: UInt32 = 1000, video: Bool = false) -> [UInt8] {
        let trak = clipTrak(timescale: timescale, video: video, id: 1)
        let trex = box("trex", be32(0) + be32(1) + be32(1) + be32(sampleTicks) + be32(1) + be32(0))
        return ftyp + box("moov", trak + box("mvex", trex))
    }

    static func clipTrak(timescale: UInt32, video: Bool, id: UInt32) -> [UInt8] {
        let mdhd = box("mdhd", be32(0) + be32(0) + be32(0) + be32(timescale) + be32(0) + be32(0))
        let hdlr = box("hdlr", be32(0) + be32(0) + Array((video ? "vide" : "soun").utf8) + [UInt8](repeating: 0, count: 13))
        let stbl = box("stbl", box("stsd", be32(0) + be32(0)))
        let header = id == 1 ? [] : box("tkhd", Array(repeating: 0, count: 12) + be32(id) + Array(repeating: 0, count: 68))
        return box("trak", header + box("mdia", mdhd + hdlr + box("minf", stbl)))
    }

    /// Media segment `n`: one `moof` with four samples, and an `mdat` whose four bytes are the
    /// stream seconds 4n to 4n+3. The data offset includes the fragment and the media header.
    static func clipSegment(_ n: Int, sampleBase: Int = 0) -> [UInt8] {
        let tfhd = box("tfhd", be32(0x020000) + be32(1))
        let tfdt = box("tfdt", be32(0) + be32(UInt32(n * 4000)))
        let trun = box("trun", be32(0x000001) + be32(4) + be32(76))
        return box("moof", box("traf", tfhd + tfdt + trun)) + box("mdat", (0..<4).map { UInt8(sampleBase + 4 * n + $0) })
    }

    // The first picture is a keyframe. Each payload byte identifies the source second and edition.
    static func renditionFragment(_ bytes: [UInt8], video: Bool, trackID: UInt32 = 1, ticks: UInt32? = nil, start: UInt32? = nil) -> [UInt8] {
        let defaults = ticks.map { be32($0) + be32(1) } ?? []
        let tfhd = box("tfhd", be32(ticks == nil ? 0x020000 : 0x020018) + be32(trackID) + defaults)
        let tfdt = start.map { box("tfdt", be32(0) + be32($0)) } ?? []
        let entries = bytes.indices.flatMap { be32(video && $0 != 0 ? 0x10000 : 0) }
        let trun = box("trun", be32(0x401) + be32(UInt32(bytes.count)) + be32(UInt32(60 + entries.count + defaults.count + tfdt.count)) + entries)
        return box("moof", box("traf", tfhd + tfdt + trun)) + box("mdat", bytes)
    }

    static let indexedClip: [UInt8] = makeIndexedClip(timescale: 1000, sampleBase: 0)
    /// A second edition of `indexedClip` with the same size and box offsets, but a different
    /// track timescale and different sample bytes.
    static let changedIndexedClip: [UInt8] = makeIndexedClip(timescale: 2000, sampleBase: 100)
    /// A second edition of `indexedClip` with the same first 64 KiB and index, different sample
    /// bytes, and one more fragment after the last indexed one, as when the file grows.
    static let grownIndexedClip: [UInt8] = makeIndexedClip(timescale: 1000, sampleBase: 100) + clipSegment(15, sampleBase: 100)

    static func makeIndexedClip(timescale: UInt32, sampleBase: Int) -> [UInt8] {
        let segments = (0..<15).map { clipSegment($0, sampleBase: sampleBase) }
        // Place the media after the initial 64 KiB probe, as in a larger real file.
        let padding = box("free", [UInt8](repeating: 0, count: 65_536))
        var index = be32(0) + be32(1) + be32(1000) + be32(0) + be32(UInt32(padding.count)) + be32(UInt32(segments.count))
        for segment in segments { index += be32(UInt32(segment.count)) + be32(4000) + be32(0) }
        return clipInit(sampleTicks: 1000, timescale: timescale) + box("sidx", index) + padding + segments.flatMap { $0 }
    }

    static let fragmentIndexedClip: [UInt8] = {
        var bytes = clipInit(sampleTicks: 1000)
        for n in 0..<15 {
            let fragment = clipSegment(n)
            let prefix = be32(0) + be32(1) + be32(1000) + be32(UInt32(n * 4000))
            let reference = be32(UInt32(fragment.count)) + be32(4000) + be32(0)
            bytes += box("sidx", prefix + be32(0) + be32(1) + reference) + fragment
        }
        return bytes
    }()
}

// MARK: - Cases

@main
struct RegressionChecks {
    static let videoURL = "https://www.youtube.com/watch?v=Fixture0001"

    static func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "PASS" : "FAIL") \(FixtureProtocol.mode): \(message)")
        if !ok { exit(1) }
    }

    /// The highest physical memory footprint of this process so far.
    static func peakFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.ledger_phys_footprint_peak : 0
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

    /// Every file in the download directory. A denial must save none, visible or hidden.
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

    /// Extracts, then downloads through `DownloadEngine`.
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
                check(httpStatus(failure) == 403 && wanted && seen.dropLast().allSatisfy { $0.url.host == "media.invalid" } && savedOutputs().isEmpty,
                      "no file or later request after denied \(stage): \(seen.map { $0.url.path }), output=\(savedOutputs())")
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
        // Finding 2: a visible notice outranks embedded metadata; inert text is not a notice.
        case "watch-wall-text", "watch-wall-metadata", "watch-human-notice", "watch-age-notice", "watch-inline-age",
             "watch-blocked-text", "watch-blocked-notice", "watch-header-age", "watch-verify-human", "watch-open-details",
             "watch-details-summary", "watch-confirm-identity", "watch-identity-phone", "watch-age-device",
             "watch-age-parenthesis", "watch-identity-dash", "watch-identity-online", "watch-identity-right-now",
             "watch-age-upon", "watch-age-footnote", "watch-purpose-clause", "watch-second-sentence", "watch-blocked-statement", "watch-blocked-video":
            let before = FixtureProtocol.requests().count
            let error = await extractError()
            let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
            check(closedByBotGate(error) && paths == ["/watch"] && savedOutputs().isEmpty,
                  "a visible verification notice stops after the first response, even when the page embeds ordinary player metadata; error=\(String(describing: error)), paths=\(paths), saved=\(savedOutputs())")
        case "watch-inert-text", "watch-lesson-no-state", "watch-hidden-notice", "watch-closed-details", "watch-verification-lesson",
             "watch-agent-settings", "watch-ordinary-objects", "watch-blocked-lesson":
            let (file, error) = await download(audioExt: "webm")
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check(error == nil && bytes == FixtureProtocol.mediaBytes,
                  "challenge words in a title, description, meta tag, script or comment do not stop an ordinary page; error=\(String(describing: error)), paths=\(paths)")
        case "player-gate":
            let error = await extractError()
            let paths = FixtureProtocol.requests().map(\.url.path).filter { $0 != "/sanity" }
            check(closedByBotGate(error) && paths == ["/watch", "/youtubei/v1/player"],
                  "the first /player bot gate with streaming data stops further profiles, media and HLS; error=\(String(describing: error)), paths=\(paths)")

        // Every listed HTTP status fails closed on each stage, with no later request.
        case "watch-status":
            for code in [401, 403, 410, 429, 451] {
                FixtureProtocol.deny(stage: "watch", status: code)
                let before = FixtureProtocol.requests().count
                let error = await extractError()
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                check(httpStatus(error) == code && paths == ["/watch"],
                      "HTTP \(code) on the watch page stops before visitor or player requests; error=\(String(describing: error)), paths=\(paths)")
            }
            check(savedOutputs().isEmpty, "watch denials save no output; saved=\(savedOutputs())")
        case "player-status":
            for code in [401, 403, 410, 429, 451] {
                FixtureProtocol.deny(stage: "player", status: code)
                let before = FixtureProtocol.requests().count
                let error = await extractError()
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                check(httpStatus(error) == code && paths == ["/watch", "/youtubei/v1/player"],
                      "HTTP \(code) on the first /player stops before another profile, media or HLS; error=\(String(describing: error)), paths=\(paths)")
            }
            check(savedOutputs().isEmpty, "player denials save no output; saved=\(savedOutputs())")
        case "probe-status":
            for code in [401, 403, 410, 429, 451] {
                FixtureProtocol.deny(stage: "probe", status: code)
                let before = FixtureProtocol.requests().count
                let error = await extractError()
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                check(httpStatus(error) == code && paths == ["/watch", "/youtubei/v1/player", "/media"],
                      "HTTP \(code) on the range probe stops before HLS or download; error=\(String(describing: error)), paths=\(paths)")
            }
            check(savedOutputs().isEmpty, "probe denials save no output; saved=\(savedOutputs())")
        case "download-status":
            for code in [401, 403, 410, 429, 451] {
                FixtureProtocol.deny(stage: "download", status: code)
                await YouTubeExtractor.invalidateCache(for: videoURL)
                let before = FixtureProtocol.requests().count
                let beforePlayers = FixtureProtocol.playerCount()
                let (file, error) = await download(audioExt: "webm")
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
            for code in [401, 403, 410, 429, 451] {
                FixtureProtocol.deny(stage: "stream", status: code)
                await YouTubeExtractor.invalidateCache(for: videoURL)
                let before = FixtureProtocol.requests().count
                let beforePlayers = FixtureProtocol.playerCount()
                let (file, error) = await download(audioExt: "webm")
                let paths = FixtureProtocol.requests().dropFirst(before).map(\.url.path)
                let players = FixtureProtocol.playerCount() - beforePlayers
                check(file == nil && httpStatus(error) == code
                        && paths == ["/watch", "/youtubei/v1/player", "/media", "/media", "/media"] && players == 1,
                      "HTTP \(code) on the download stream stops without a new player request; error=\(String(describing: error)), paths=\(paths), players=\(players)")
            }
            check(savedOutputs().isEmpty, "download stream denials leave no files; saved=\(savedOutputs())")

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
        // one request and its status. A connection lost before any response stays a transport
        // failure and is retried.
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
                check(status == 0 && failure is URLError && origin.requests > 1,
                      "a connection lost before any response is retried as a transport failure; requests=\(origin.requests), error=\(String(describing: failure))")
            } else {
                check(status == 403 && origin.requests == 1,
                      "a 403 ends the request at its headers, whatever happens to its body; status=\(status), requests=\(origin.requests), error=\(String(describing: failure))")
            }
        // URLSession can hold a response until some of its body arrives. A 403 that sends its
        // headers and then no body reaches uBit as a timeout, so its status is unknown; neither
        // fetchData nor a parallel range worker sends that request again, and no probe, stream or
        // worker exit keeps resume files. A repeated request would get the whole refusal at once.
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
            for target in [file, probeFile, streamFile] {
                try Data("resume prefix".utf8).write(to: target.appendingPathExtension("part"))
                try Data("{}".utf8).write(to: target.appendingPathExtension("part.json"))
            }
            func leftovers(_ target: URL) -> [String] {
                [target, target.appendingPathExtension("part"), target.appendingPathExtension("part.json")]
                    .filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
            }
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
            check(unknownStatus(second) && !seen.isEmpty && seen.values.allSatisfy { $0 == 1 } && leftovers(file).isEmpty,
                  "a range worker does not repeat a range whose headers arrived without a body, and keeps no resume files; ranges=\(seen), files=\(leftovers(file)), error=\(String(describing: second))")
            check(unknownStatus(third) && probe.requests == 1 && leftovers(probeFile).isEmpty,
                  "a probe whose status is unknown keeps no resume files; requests=\(probe.requests), files=\(leftovers(probeFile)), error=\(String(describing: third))")
            check(unknownStatus(fourth) && stream.requests == 2 && leftovers(streamFile).isEmpty,
                  "a single stream whose status is unknown keeps no resume files; requests=\(stream.requests), files=\(leftovers(streamFile)), error=\(String(describing: fourth))")
        // No request starts while another request of the operation waits for its status, so no
        // segment request starts after a refusal whose status uBit has not read yet. `s1` is a
        // slow success; without the rule, its worker asks for `s2` while `s0` is refused.
        case "refusal-hls-parallel":
            final class Paths: @unchecked Sendable {
                private let lock = NSLock()
                private var list: [String] = []
                func add(_ path: String) { lock.withLock { list.append(path) } }
                var all: [String] { lock.withLock { list } }
            }
            let paths = Paths()
            let origin = WireOrigin { connection, _, request in
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                paths.add(path)
                switch path {
                case "/clip.m3u8":
                    let body = "#EXTM3U\n#EXTINF:2,\ns0.ts\n#EXTINF:2,\ns1.ts\n#EXTINF:2,\ns2.ts\n#EXT-X-ENDLIST\n"
                    WireOrigin.transmit(connection, "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
                case "/s0.ts":
                    WireOrigin.transmit(connection, "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 16\r\nConnection: close\r\n\r\n")
                    sleep(45)
                default:
                    usleep(500_000)
                    WireOrigin.transmit(connection, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nGGGG")
                }
                close(connection)
            }
            let file = AppPaths.appSupportDir.appendingPathComponent("refused.ts")
            var failure: Error?
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "http://127.0.0.1:\(origin.port)/clip.m3u8", destination: file, connections: 2)
            } catch { failure = error }
            let seen = paths.all
            check(failure != nil && seen.last == "/s0.ts" && !seen.contains("/s2.ts") && !FileManager.default.fileExists(atPath: file.path),
                  "no segment request starts after a refusal whose status is not yet known; requests=\(seen), error=\(String(describing: failure))")
        // A request that fails after its response began, with metrics that prove nothing (here a
        // URLProtocol load), is not repeated: missing proof is not permission.
        case "metrics-unproven":
            var failure: Error?
            do {
                _ = try await HTTPClient().fetchData(url: "https://media.invalid/lost-after-headers", retries: 3)
            } catch { failure = error }
            let attempts = FixtureProtocol.requests().filter { $0.url.path == "/lost-after-headers" }.count
            var unknown = false
            if case HTTPError.noStatus? = failure as? HTTPError { unknown = true }
            check(unknown && attempts == 1,
                  "uninformative metrics do not allow another request; attempts=\(attempts), error=\(String(describing: failure))")
        // A request that waits at the gate for another request's status can be cancelled alone:
        // it returns at once, it never reaches the origin, and the gate still admits later requests.
        case "gate-cancel-waiter":
            let hold = DispatchSemaphore(value: 0)
            let origin = WireOrigin { connection, _, request in
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                if path == "/first" { hold.wait() }
                WireOrigin.transmit(connection, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n" + (path == "/first" ? "AAAA" : "BBBB"))
                close(connection)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { hold.signal() }
            let client = HTTPClient()
            let base = "http://127.0.0.1:\(origin.port)"
            let first = Task { try await client.fetchData(url: base + "/first").0 }
            while origin.requests == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            let waiter = Task { try await client.fetchData(url: base + "/later").0 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            let started = Date()
            waiter.cancel()
            let cancelled: Bool
            do { _ = try await waiter.value; cancelled = false } catch { cancelled = error is CancellationError }
            let elapsed = Date().timeIntervalSince(started)
            let onWire = origin.requests
            let firstBody = try? await first.value
            let later = try? await client.fetchData(url: base + "/later").0
            check(cancelled && elapsed < 0.5 && onWire == 1 && firstBody == Data("AAAA".utf8) && later == Data("BBBB".utf8) && origin.requests == 2,
                  "a cancelled request that waits for another request's status returns at once and leaves the gate usable; cancelled=\(cancelled), elapsed=\(elapsed), requestsAtCancel=\(onWire), first=\(firstBody.map { String(decoding: $0, as: UTF8.self) } ?? "none"), later=\(later.map { String(decoding: $0, as: UTF8.self) } ?? "none")")
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
        case "hls-section-base":
            // The saved HLS timeline starts at 0, so the engine must know where the first kept
            // segment starts in the stream, or the trim cuts the wrong seconds.
            let dest = AppPaths.appSupportDir.appendingPathComponent("hls-section.ts")
            let result = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/hls.m3u8",
                                                            destination: dest, section: SectionRange(start: 20, end: 26))
            let fetched = FixtureProtocol.requests().map(\.url.path).filter { $0.hasPrefix("/seg-") }.sorted()
            check(result.startTime == 16 && fetched == ["/seg-4.ts", "/seg-5.ts", "/seg-6.ts"],
                  "the 20–26 s clip fetches two overlapping segments and one for preroll; startTime=\(result.startTime), segments=\(fetched)")
        case "hls-clock-mux", "hls-clock-short":
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.connections = 1
            options.cookieSource = "none"
            options.section = SectionRange(start: 2.25, end: 4)
            options.outputDir = AppPaths.appSupportDir.appendingPathComponent("out").path
            let stem = mode == "hls-clock-mux" ? "mux" : "master"
            let file = try await DownloadEngine().downloadSingle(url: "https://media.invalid/clock/\(stem).m3u8", settings: settings, options: options)
            let tracks = try MP4Muxer.readTracks(from: file), media = try Data(contentsOf: file)
            let pictures = tracks.first { $0.kind == .video }?.samples.map { media[Int($0.offset)] }
            let sound = tracks.first { $0.kind == .audio }
            let first = sound?.samples.first.map { media[Int($0.offset)] }
            check(pictures == Array(20..<40).map(UInt8.init) && first == 93 && sound?.editMediaTimeTicks == 768,
                  "cut at keyframe 20 keeps packet 93 and skips 768 audio ticks; first=\(String(describing: first)), edit=\(String(describing: sound?.editMediaTimeTicks))")
        case "paired-plain-a", "paired-plain-b", "paired-tagged-a", "paired-tagged-b", "paired-plain-changed", "paired-tagged-changed", "paired-clock":
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.connections = 1
            options.cookieSource = "none"
            let out = AppPaths.appSupportDir.appendingPathComponent("out")
            options.outputDir = out.path
            let cut = mode == "paired-clock"
            if cut { options.section = SectionRange(start: 1, end: 3) }
            do {
                let file = try await DownloadEngine().downloadSingle(url: "https://media.invalid/paired.m3u8", settings: settings, options: options)
                let tracks = try MP4Muxer.readTracks(from: file)
                let media = try Data(contentsOf: file)
                func bytes(_ kind: MP4TrackKind) -> [UInt8] {
                    tracks.first { $0.kind == kind }?.samples.map { media[Int($0.offset)] } ?? []
                }
                let first: UInt8 = mode.hasSuffix("-b") ? 100 : 0
                let picture = (0..<(cut ? 3 : 4)).map { first + UInt8($0) }
                check(bytes(.video) == picture && bytes(.audio) == picture.map { $0 + 40 },
                      "picture and audio sample identifiers on the movie clock: video=\(bytes(.video)), audio=\(bytes(.audio))")
            } catch HTTPError.rangeUnsupported where mode.contains("changed") {
                let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
                check(files.isEmpty, "a changed cross-rendition edition leaves no output: \(files)")
            }
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
        case "hls-section-outside":
            // Seventh review: a section after the end of a 60 s stream is an error. No media
            // segment is fetched, and no file is saved.
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.cookieSource = "none"
            options.connections = 1
            let outDir = AppPaths.appSupportDir.appendingPathComponent("out")
            options.outputDir = outDir.path
            var rejected: [Int] = []
            for start in [60, 65] {
                options.section = SectionRange(start: Double(start), end: Double(start + 5))
                do {
                    _ = try await DownloadEngine().downloadSingle(url: "https://media.invalid/clip.m3u8", settings: settings, options: options)
                } catch where error.localizedDescription.contains("outside the stream") {
                    rejected.append(start)
                }
            }
            let fetched = FixtureProtocol.requests().map(\.url.path).filter { $0.hasSuffix(".m4s") }
            let saved = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).filter { !$0.hasPrefix(".") }
            check(rejected == [60, 65] && fetched.isEmpty && saved.isEmpty,
                  "sections at and past EOF fail without fetching or saving media; rejected=\(rejected), segments=\(fetched), saved=\(saved)")
        case "range-ignored":
            // Seventh review: a server that ignores Range answers 200 with the whole file. The
            // fixture's /seg- route does that, and its body is its own path.
            let client = HTTPClient()
            let part = try await client.fetchRangeBytes(url: "https://media.invalid/seg-whole.mp3", range: ByteRange(start: 5, end: 9))
            var pastEnd = false
            do {
                _ = try await client.fetchRangeBytes(url: "https://media.invalid/seg-whole.mp3", range: ByteRange(start: 100, end: 200))
            } catch HTTPError.rangeUnsupported {
                pastEnd = true
            }
            let suffix = try await client.fetchRangeBytes(url: "https://media.invalid/seg-whole.mp3", range: ByteRange(start: 5, end: .max))
            let before = FixtureProtocol.requests().count
            var refused = 0
            for bounds in [ByteRange(start: -1, end: 5), ByteRange(start: 5, end: 2)] {
                do {
                    _ = try await client.fetchRangeBytes(url: "https://media.invalid/seg-whole.mp3", range: bounds)
                } catch HTTPError.rangeUnsupported { refused += 1 }
            }
            let text = String(decoding: part, as: UTF8.self)
            check(text == "whole" && pastEnd && String(decoding: suffix, as: UTF8.self) == "whole.mp3"
                  && refused == 2 && FixtureProtocol.requests().count == before,
                  "valid ranges return the requested bytes through EOF; invalid bounds make no request")
            let bounds = ByteRange(start: 1, end: 3)
            let atEOF = try await client.fetchRangeBytes(url: "https://media.invalid/partial/eof", range: bounds)
            check(atEOF == Data("bc".utf8), "a partial answer can end at the actual file end")
            for route in ["short", "shifted", "truncated"] {
                var rejected = false
                do {
                    _ = try await client.fetchRangeBytes(url: "https://media.invalid/partial/\(route)", range: bounds)
                } catch HTTPError.rangeUnsupported { rejected = true }
                check(rejected, "refuse an incomplete or misaligned partial answer: \(route)")
            }
        case "hls-raw-section", "http-raw-section":
            // A raw MP3 stream (the shape that the SoundCloud extractor returns) with a 0:20-0:26
            // section is not trimmed. Over plain HTTP it is saved whole; over HLS, the segments that
            // overlap the section (4 to 6 of 15, 4 s each) are saved as they are.
            let overHLS = FixtureProtocol.mode == "hls-raw-section"
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.cookieSource = "none"
            options.audioOnly = true
            options.connections = 1
            options.targetFormat = "mp3"
            options.outputDir = AppPaths.appSupportDir.appendingPathComponent("out").path
            options.section = SectionRange(start: 20, end: 26)
            let format = overHLS
                ? MediaFormat(id: "hls-mp3", url: "https://media.invalid/hls.m3u8", ext: "mp3", proto: .hls, vcodec: "none", acodec: "mp3", bitrate: 128_000)
                : MediaFormat(id: "http-mp3", url: "https://media.invalid/seg-whole.mp3", ext: "mp3", proto: .http, vcodec: "none", acodec: "mp3", bitrate: 128_000)
            let info = MediaInfo(id: "x", title: "x", site: "Fixture", webpageURL: "https://media.invalid/page", formats: [format])
            let file = try await DownloadEngine().downloadSingle(url: "https://media.invalid/page", preExtracted: info, settings: settings, options: options)
            let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            let expected = overHLS ? "/seg-4.ts/seg-5.ts/seg-6.ts" : "/seg-whole.mp3"
            check(saved == expected, "raw MP3 is not trimmed: HTTP saves the file and HLS saves the selected segments, including preroll; saved=\(saved), expected=\(expected)")
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
                $0.url.path == "/media" && [401, 403, 410, 429, 451].contains($0.status)
            }
            let ok = mode == "hls-fallback-nowatch"
                ? formats.isEmpty && !failure.isEmpty && missing.isEmpty && denied.isEmpty
                : !formats.isEmpty && formats.allSatisfy { $0.hasSuffix(":hls") } && failure.isEmpty
                    && denied.isEmpty && (mode != "hls-fallback-lateprofile" || missing.count == 1)
            check(ok,
                  "the HLS playlist is used after an ordinary empty or not-found miss, never a denial; formats=\(formats), failure=\(failure), missing=\(missing.count), denied=\(denied.map(\.status))")
        case "hls-ntsc":
            let url = "https://media.invalid/clip.m3u8"
            let dest = AppPaths.appSupportDir.appendingPathComponent("unexpected.mp4")
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: url, destination: dest,
                                                       section: SectionRange(start: 7.007, end: 8))
                check(false, "a section starting at decimal EOF produced a stream")
            } catch where error.localizedDescription.contains("outside the stream") {}
            let parts = FixtureProtocol.requests().filter { $0.url.path.hasPrefix("/clip-") }
            check(parts.isEmpty && !FileManager.default.fileExists(atPath: dest.path), "decimal EOF needs neither init nor media")
        case "trim-display-end":
            // Decode order: a sync picture shown at 0, a reference picture shown at 0.3, and a
            // picture shown at 0.1 whose decode duration (0.3) reaches past 0.3.
            let track = MP4Track(trackID: 1, kind: .video, timescale: 10, stsdPayload: Data(), samples: [
                MP4Sample(offset: 0, size: 1, duration: 1, isSync: true),
                MP4Sample(offset: 1, size: 1, duration: 1, ctsOffset: 2, isSync: false),
                MP4Sample(offset: 2, size: 1, duration: 3, ctsOffset: -1, isSync: false),
            ])
            let exact = MP4Muxer.trimTracks([track], section: SectionRange(start: 0, end: 0.3)).first
            check(exact?.samples.count == 3 && exact?.editSegmentTicks == 3,
                  "an end at 0.3 keeps the reference picture for decoding but shows pictures until 0.3 only: edit=\(String(describing: exact?.editSegmentTicks))")
            let after = MP4Muxer.trimTracks([track], section: SectionRange(start: 0, end: 0.300001)).first
            check(after?.samples.count == 3 && after?.editSegmentTicks == nil,
                  "an end just after 0.3 shows the picture at 0.3: edit=\(String(describing: after?.editSegmentTicks))")
        case "trim-boundaries", "trim-keyframe":
            func samples(scale: UInt32, ticks: UInt32, count: Int, group: Int, base: Double, start: Double, end: Double) -> [UInt64] {
                let track = MP4Track(trackID: 1, kind: .video, timescale: scale, stsdPayload: Data(),
                                     samples: (0..<count).map { MP4Sample(offset: UInt64($0), size: 1, duration: ticks, isSync: $0 % group == 0) })
                return MP4Muxer.trimTracks([track], section: SectionRange(start: start, end: end), baseStartTimeSec: base).first?.samples.map(\.offset) ?? []
            }
            if mode == "trim-keyframe" {
                let got = samples(scale: 1, ticks: 1, count: 12, group: 4, base: 0, start: 7.9995, end: 7.9999)
                check(got == [4, 5, 6, 7], "a section before a sync frame uses the preceding keyframe: \(got)")
                let vfr = MP4Track(trackID: 1, kind: .video, timescale: 10, stsdPayload: Data(), samples: [
                    MP4Sample(offset: 0, size: 1, duration: 1, isSync: true),
                    MP4Sample(offset: 1, size: 1, duration: 3, ctsOffset: 2, isSync: false),
                    MP4Sample(offset: 2, size: 1, duration: 1, isSync: true),
                ])
                let cut = MP4Muxer.trimTracks([vfr], section: SectionRange(start: 0.4, end: 0.5))
                check(cut.first?.samples.map(\.offset) == [2], "the preceding picture ends at the next displayed sync picture, not at its decode duration")
                return
            }
            for (end, frames) in [(1.701699, 21), (1.7017, 21), (1.701701, 22)] {
                let got = samples(scale: 30000, ticks: 1001, count: 30, group: 30, base: 1.001, start: 1.2, end: end)
                check(got == Array(0..<UInt64(frames)), "exclusive end \(end): \(got)")
            }
            // At 2 s the video is at a sync picture, but the 48 kHz audio is 768 ticks
            // into packet 93. Reopen the output to check both its packet and its edit.
            let pictures = MP4Track(trackID: 1, kind: .video, timescale: 1, stsdPayload: Data(), samples:
                (0..<4).map { MP4Sample(size: 1, duration: 1, isSync: $0 % 2 == 0, inlineData: Data([UInt8($0)])) })
            let packets = MP4Track(trackID: 2, kind: .audio, timescale: 48000, stsdPayload: Data(), samples:
                (0..<150).map { MP4Sample(size: 1, duration: 1024, inlineData: Data([UInt8($0)])) })
            let section = SectionRange(start: 2.25, end: 2.56)
            for separate in [false, true] {
                let clock = MP4Muxer.SectionClock()
                let tracks = separate
                    ? MP4Muxer.trimTracks([pictures], section: section, clock: clock) + MP4Muxer.trimTracks([packets], section: section, clock: clock)
                    : MP4Muxer.trimTracks([pictures, packets], section: section)
                let url = AppPaths.appSupportDir.appendingPathComponent("packet-clock-\(separate).mp4")
                try MP4Muxer.writeMP4(tracks: tracks, sourceFiles: [], destination: url)
                let saved = try MP4Muxer.readTracks(from: url)
                let data = try Data(contentsOf: url)
                let audio = saved.first { $0.kind == .audio }
                let packet = audio?.samples.first.map { data[Int($0.offset)] }
                let picture = saved.first { $0.kind == .video }?.samples.first.map { data[Int($0.offset)] }
                check(picture == 2 && packet == 93 && audio?.editMediaTimeTicks == 768 && audio?.editSegmentTicks == 26880,
                      "separate=\(separate): picture 2 starts at tick 768 of audio packet 93; packet=\(String(describing: packet)), edit=\(String(describing: audio?.editMediaTimeTicks)), duration=\(String(describing: audio?.editSegmentTicks))")
            }
            let video = MP4Track(trackID: 1, kind: .video, timescale: 30, stsdPayload: Data(), samples:
                (0..<10).map { MP4Sample(offset: UInt64($0 + 10), size: 1, duration: 1, isSync: $0 == 0) })
            let fromThird = MP4Muxer.trimTracks([video], section: SectionRange(start: 0.4, end: 0.5),
                                                 baseStart: SectionTimeBase(ticks: 1, timescale: 3))
            check(fromThird.first?.samples.map(\.offset) == [10, 11, 12, 13, 14], "the exclusive end omits frame 15 after a one-third-second fragment start")
            let offsets: [Int32] = [0, 2, -1, -1]
            let decode = offsets.enumerated().map { i, offset -> MP4Sample in
                let byte = Data([UInt8(i)])
                return MP4Sample(offset: 0, size: 1, duration: 1, ctsOffset: offset, isSync: i == 0, inlineData: byte)
            }
            var reordered = video
            reordered.samples = decode
            let display = MP4Muxer.trimTracks([reordered], section: SectionRange(start: 0, end: 0.1)).first
            check(display?.samples.count == 4 && display?.editSegmentTicks == 3, "the clip retains the fourth decode sample but presents only the first three pictures")
            let file = AppPaths.appSupportDir.appendingPathComponent("reordered.mp4")
            if let display {
                try MP4Muxer.writeMP4(tracks: [display], sourceFiles: [], destination: file)
                let reopened = try MP4Muxer.readTracks(from: file)
                let open = MP4Muxer.trimTracks(reopened, section: SectionRange(start: 0, end: nil))
                let eof = MP4Muxer.trimTracks(reopened, section: SectionRange(start: 0.1, end: nil))
                check(open.first?.editSegmentTicks == 3 && open.first?.samples.count == 4 && eof.isEmpty,
                      "reopening the clip cannot present the hidden reference picture or create a clip at displayed EOF")
            }
        case "hls-decimal", "sidx-boundaries", "sidx-fragments", "sidx-padding":
            let hls = mode == "hls-decimal"
            let path = hls ? "/clip.m3u8" : "/indexed.mp4"
            let url = "https://media.invalid" + path
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.cookieSource = "none"
            options.connections = 1
            let out = AppPaths.appSupportDir.appendingPathComponent("out")
            options.outputDir = out.path
            let eof = hls ? 12.0 : 60.0
            options.section = SectionRange(start: eof, end: eof + 1)
            do {
                _ = try await DownloadEngine().downloadSingle(url: url, settings: settings, options: options)
                check(false, "a section starting at EOF produced a file")
            } catch where error.localizedDescription.contains("outside the stream") {}
            let media = FixtureProtocol.requests().filter { $0.url.path == path || $0.url.path.hasPrefix("/clip-") }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
            var onlyMetadata = hls ? !media.isEmpty && media.allSatisfy { $0.url.path == path }
                                   : media.count == 1 && media[0].range == "bytes=0-65535"
            if mode == "sidx-padding" {
                let next = Bytes.indexedClip.count
                onlyMetadata = media.map(\.range) == ["bytes=0-65535", "bytes=\(next)-\(next + 7)"]
            }
            check(files.isEmpty && (mode == "sidx-fragments" || onlyMetadata),
                  "at EOF no file is saved; a complete index needs no media request; paths=\(media.map(\.url.path)), files=\(files)")

            let clips: [(Double, Double, [Int], [String])] = hls ? [
                (8, 9.6, Array(40..<48), ["/clip-9.m4s", "/clip-10.m4s", "/clip-11.m4s"]),
                (11.999999, 12, [59], ["/clip-14.m4s"])
            ] : mode == "sidx-fragments" ? [(4, 12, Array(4..<12), []), (2, 6, Array(2..<6), [])]
                                         : [(56, 60, Array(56..<60), [])]
            for (start, end, expected, parts) in clips {
                let before = FixtureProtocol.requests().count
                options.section = SectionRange(start: start, end: end)
                let file = try await DownloadEngine().downloadSingle(url: url, settings: settings, options: options)
                let data = try Data(contentsOf: file)
                let samples = data.range(of: Data("mdat".utf8)).map { data[$0.upperBound...].map(Int.init) } ?? []
                let fetched = FixtureProtocol.requests().dropFirst(before).map(\.url.path).filter { $0.hasSuffix(".m4s") }
                check(samples == expected && fetched == parts, "section \(start)-\(end): samples=\(samples), parts=\(fetched)")
            }
        case "sidx-untagged-change", "sidx-untagged-grow":
            // The server names no edition and changes the file after the first read. The saved
            // clip must come from one edition (timescale and samples agree), or no file is saved.
            // When the file grows, an open-ended clip must not stop at the end of the first edition.
            let grow = mode == "sidx-untagged-grow"
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            options.cookieSource = "none"
            options.connections = 1
            let out = AppPaths.appSupportDir.appendingPathComponent("out")
            options.outputDir = out.path
            options.section = grow ? SectionRange(start: 56, end: nil) : SectionRange(start: 8, end: 12)
            var file: URL?
            var failure: Error?
            do {
                file = try await DownloadEngine().downloadSingle(url: "https://media.invalid/indexed.mp4", settings: settings, options: options)
            } catch { failure = error }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
            if let file {
                let data = try Data(contentsOf: file)
                let samples = data.range(of: Data("mdat".utf8)).map { data[$0.upperBound...].map(Int.init) } ?? []
                let timescale = try MP4Muxer.readTracks(from: file).first?.timescale
                let oneEdition = grow ? (samples == Array(56..<60) || samples == Array(156..<164))
                    : (timescale == 1000 && samples == Array(8..<12)) || (timescale == 2000 && samples.allSatisfy { $0 >= 100 })
                check(oneEdition, "a saved clip comes from one edition: timescale=\(String(describing: timescale)), samples=\(samples)")
            } else {
                check(files.isEmpty, "a changed edition fails without a file: error=\(String(describing: failure)), files=\(files)")
            }
        case "parallel-redirect":
            // Two connections and a redirector that alternates between mirrors whose different
            // copies carry the same ETag text: every range must come from the probed mirror.
            let file = AppPaths.appSupportDir.appendingPathComponent("hop.bin")
            var failure: Error?
            do {
                try await HTTPClient().downloadFile(url: "https://media.invalid/hop.bin", destination: file, connections: 2)
            } catch { failure = error }
            let saved = try? Data(contentsOf: file)
            let sources = Set(FixtureProtocol.requests().filter { $0.url.path.hasPrefix("/mirror-") }.map(\.url.path))
            check(failure == nil && saved == FixtureProtocol.parallelBytes && sources == ["/mirror-a.bin"],
                  "a parallel download reads one mirror: failure=\(String(describing: failure)), sources=\(sources.sorted()), intact=\(saved == FixtureProtocol.parallelBytes)")
        case "hls-redirect-vod", "hls-redirect-live":
            // The same redirector for one playlist URI: two ranges (VOD), or a whole read and
            // then a range (live), must come from the mirror that answered first.
            let file = AppPaths.appSupportDir.appendingPathComponent("hop.ts")
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            let live = mode == "hls-redirect-live"
            var failure: Error?
            do {
                if live {
                    _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/hop-live.m3u8", destination: file)
                } else {
                    _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/hop.m3u8", destination: file, connections: 2)
                }
            } catch { failure = error }
            let saved = try? Data(contentsOf: file)
            check(failure == nil && saved == Data((live ? "AAAAAA" : "AAAA").utf8),
                  "every read of a redirected URI uses the first mirror: failure=\(String(describing: failure)), saved=\(String(decoding: saved ?? Data(), as: UTF8.self))")
        case "parallel-cancel", "parallel-short", "parallel-intact", "parallel-unvalidated":
            let file = AppPaths.appSupportDir.appendingPathComponent("result.bin")
            var failure: Error?
            do {
                try await HTTPClient().downloadFile(url: "https://media.invalid/parallel.bin", destination: file, connections: 2)
            } catch { failure = error }
            let ranges = FixtureProtocol.requests().filter { $0.url.path == "/parallel.bin" && $0.range != "bytes=0-0" }.compactMap(\.range)
            let saved = try? Data(contentsOf: file)
            switch mode {
            case "parallel-intact", "parallel-unvalidated": check(failure == nil && saved == FixtureProtocol.parallelBytes, "all source bytes are present")
            case "parallel-cancel": check((failure as? URLError)?.code == .cancelled && saved == nil && !ranges.isEmpty && Set(ranges).count == ranges.count, "a cancelled range is not retried: \(ranges)")
            default: check(failure != nil && saved == nil && !ranges.isEmpty, "a short range cannot publish a preallocated file")
            }
        case "dash-refusal":
            let dir = AppPaths.appSupportDir.appendingPathComponent("out")
            let file = dir.appendingPathComponent("video.mp4")
            func transfer(_ folder: String) async throws {
                try await DASHEngine.downloadRepresentation(client: HTTPClient(), mpdURL: "https://segments.invalid/\(folder)/clip.mpd", formatID: "dash-v", destination: file, connections: 1)
            }
            do { try await transfer("denied"); check(false, "DASH accepted a denied segment") }
            catch HTTPError.status(403, _) {}
            let afterFailure = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let requests = FixtureProtocol.requests().filter { $0.url.host == "segments.invalid" }.map(\.url.path)
            check(afterFailure.isEmpty && requests == ["/denied/clip.mpd", "/denied/piece-1.m4s", "/denied/piece-2.m4s"], "DASH stops at the denied segment without leaving output: \(requests), \(afterFailure)")
            try await transfer("allowed")
            let bytes = try Data(contentsOf: file)
            check(String(decoding: bytes, as: UTF8.self) == "/allowed/piece-1.m4s/allowed/piece-2.m4s/allowed/piece-3.m4s", "a later operation assembles only its own three segments")
        case "hls-live-stable", "hls-live-changed", "hls-live-whole", "hls-live-whole-changed":
            let file = AppPaths.appSupportDir.appendingPathComponent("live.ts")
            // The CLI creates the output folder before a live recording starts.
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            var rejected = false
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/live-editions.m3u8", destination: file)
            } catch HTTPError.rangeUnsupported { rejected = true }
            let saved = try? Data(contentsOf: file)
            switch mode {
            case "hls-live-changed", "hls-live-whole-changed":
                check(rejected && saved == nil, "a returning or ranged URI with new content stops the recording: saved=\(String(describing: saved))")
            case "hls-live-whole":
                // A whole read and a later range of the same unchanged URI form one edition.
                check(saved == Data("AAAAAA".utf8), "a range after a whole read uses the same edition: \(String(decoding: saved ?? Data(), as: UTF8.self))")
            default:
                check(saved == Data("AAxxAA".utf8), "a returning untagged URI contributes the original bytes: \(String(decoding: saved ?? Data(), as: UTF8.self))")
            }
        case "hls-event-whole", "hls-event-ranged":
            let file = AppPaths.appSupportDir.appendingPathComponent("event.ts")
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            let before = Self.peakFootprint()
            _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/event.m3u8", destination: file)
            let growth = Self.peakFootprint() - before
            let saved = try Data(contentsOf: file, options: .alwaysMapped)
            if mode == "hls-event-whole" {
                // 64 whole 1 MiB segments: the recorder must not keep the recording in memory.
                let intact = saved.count == 64 << 20 && saved[saved.count - 1] == 63
                check(intact && growth < 32 << 20, "an EVENT recording keeps no copy of whole segments: \(saved.count) bytes saved, peak grew \(growth >> 20) MiB")
            } else {
                // 70 ranged 1 MiB objects exceed the 64 MiB copy budget, so the first object
                // lost its copy; its later range must come from a new complete read that matches.
                let full = FixtureProtocol.requests().filter { $0.url.path == "/ev-0.bin" && $0.range == nil }.count
                let expected = (0..<70).reduce(into: Data()) { $0.append(Data(repeating: UInt8($1), count: 1024)) } + Data(repeating: 0, count: 1024)
                check(saved == expected && full == 2, "an evicted copy is replaced by a matching complete read: \(saved.count) bytes, \(full) complete reads of the first object")
            }
        case "hls-event-oversized":
            // One untagged object larger than the 64 MiB copy budget: after its first range the
            // copy is released, and the later range comes from a new complete read that matches.
            let file = AppPaths.appSupportDir.appendingPathComponent("event.ts")
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/event.m3u8", destination: file)
            let saved = try Data(contentsOf: file)
            let full = FixtureProtocol.requests().filter { $0.url.path == "/big.bin" && $0.range == nil }.count
            check(saved == Data(repeating: 0x41, count: 1024) + Data(repeating: 0x5A, count: 1024) && full == 2,
                  "a copy over the budget is not kept between playlist updates: \(saved.count) bytes, \(full) complete reads")
        case "hls-changed-edition", "hls-untagged-edition":
            let file = AppPaths.appSupportDir.appendingPathComponent("clip.ts")
            var rejected = false
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/editions.m3u8", destination: file, connections: 2)
            } catch HTTPError.rangeUnsupported { rejected = true }
            let saved = try? Data(contentsOf: file)
            check(mode == "hls-changed-edition" ? rejected && saved == nil : saved == Data("AAAA".utf8),
                  "two playlist ranges must not publish bytes from different editions")
        // Two whole reads of one URI in one selection give one edition: a changed object fails
        // without a clip, and an unchanged object is saved twice.
        case "hls-repeat-stable", "hls-repeat-changed", "hls-alias-stable", "hls-alias-changed":
            let alias = mode.hasPrefix("hls-alias")
            let file = AppPaths.appSupportDir.appendingPathComponent("repeat.ts")
            var rejected = false
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/\(alias ? "alias" : "repeat").m3u8", destination: file, connections: 1)
            } catch HTTPError.rangeUnsupported { rejected = true }
            let saved = try? Data(contentsOf: file)
            check(mode.hasSuffix("-changed") ? rejected && saved == nil : saved == Data(String(repeating: "AAAA", count: alias ? 4 : 2).utf8),
                  "whole reads of one HTTP resource, also under other spellings, must not publish bytes from different editions; saved=\(saved.map { String(decoding: $0, as: UTF8.self) } ?? "none")")
        // Spellings whose requests are identical on the wire read one resource: a VOD selection
        // and a live recording both stop when its second read is a new edition.
        case "hls-userinfo-changed", "hls-live-userinfo":
            let live = mode == "hls-live-userinfo"
            let file = AppPaths.appSupportDir.appendingPathComponent("alias.ts")
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            var rejected = false
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/\(live ? "live-alias" : "alias-userinfo").m3u8", destination: file, connections: 1)
            } catch HTTPError.rangeUnsupported { rejected = true }
            let saved = try? Data(contentsOf: file)
            check(rejected && saved == nil, "empty user information names the same resource, so a changed second read stops without a clip; saved=\(saved.map { String(decoding: $0, as: UTF8.self) } ?? "none")")
        // Request targets that differ only in the case of an escape are requested as written.
        case "hls-raw-routes":
            let file = AppPaths.appSupportDir.appendingPathComponent("routes.ts")
            _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/routes.m3u8", destination: file, connections: 1)
            let saved = try? Data(contentsOf: file)
            let queries = FixtureProtocol.requests().filter { $0.url.path == "/route.ts" }.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "" }
            check(saved == Data("AAAABBBB".utf8) && queries == ["object=ab%2fCD", "object=ab%2FCD"],
                  "each playlist URI is requested as written; saved=\(saved.map { String(decoding: $0, as: UTF8.self) } ?? "none"), queries=\(queries)")
        // Two spellings that the edition key joins can still be separate routes. Each spelling is
        // requested, and spellings that give different bytes stop the download.
        case "hls-dot-routes", "hls-dot-same", "hls-live-dot-routes", "hls-live-dot-tagged":
            let file = AppPaths.appSupportDir.appendingPathComponent("dots.ts")
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            var rejected = false
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/\(mode.hasPrefix("hls-live-") ? "live-dots" : "dots").m3u8", destination: file, connections: 1)
            } catch HTTPError.rangeUnsupported { rejected = true }
            let saved = try? Data(contentsOf: file)
            let targets = Set(FixtureProtocol.requests().map(\.url.path).filter { $0.hasSuffix("dots.ts") })
            let outcome = ["hls-dot-same", "hls-live-dot-tagged"].contains(mode) ? !rejected && saved == Data("AAAA".utf8) : rejected && saved == nil
            check(outcome && targets == ["/a/../dots.ts", "/dots.ts"],
                  "a pinned copy serves only the spelling that it read; saved=\(saved.map { String(decoding: $0, as: UTF8.self) } ?? "none"), rejected=\(rejected), targets=\(targets.sorted())")
        // A scoped and an unscoped loopback address send the same request, so they are one
        // resource. Two Host forms of one address can be separate routes, so each is requested.
        case "hls-v6-scope", "hls-live-v6-scope", "hls-v6-forms":
            let file = AppPaths.appSupportDir.appendingPathComponent("v6.ts")
            try FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            var rejected = false
            do {
                _ = try await HLSEngine.downloadStream(client: HTTPClient(), playlistURL: "https://media.invalid/\(mode == "hls-live-v6-scope" ? "live-v6" : "v6").m3u8", destination: file, connections: 1)
            } catch HTTPError.rangeUnsupported { rejected = true }
            let saved = try? Data(contentsOf: file)
            let hosts = Set(FixtureProtocol.requests().filter { $0.url.path == "/v6.ts" }.compactMap(\.url.host))
            check(rejected && saved == nil && hosts.count == 2,
                  "two spellings of one IPv6 address give one edition or no file; saved=\(saved.map { String(decoding: $0, as: UTF8.self) } ?? "none"), rejected=\(rejected), hosts=\(hosts.sorted())")
        case "hls-short-range":
            let folder = AppPaths.appSupportDir.appendingPathComponent("out")
            var options = DownloadRequestOptions()
            options.outputDir = folder.path
            options.cookieSource = "none"
            for path in ["short-map", "short-segment"] {
                do {
                    _ = try await DownloadEngine().downloadSingle(url: "https://media.invalid/\(path).m3u8", settings: Settings(), options: options)
                    check(false, "an incomplete HLS range must not publish a clip")
                } catch HTTPError.rangeUnsupported {}
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            check(names.isEmpty, "a short segment or map leaves no media or temporary files: \(names)")
        case "sidx-cut":
            var settings = Settings()
            settings.embedMetadata = false
            settings.saveThumbnail = false
            var options = DownloadRequestOptions()
            let start = 4.0
            options.connections = 1
            options.cookieSource = "none"
            let out = AppPaths.appSupportDir.appendingPathComponent("out")
            options.outputDir = out.path
            let scenarios: [(String, Double?)] = [("200", 10), ("206", 10), ("206", 61), ("unknown", 61), ("unknown", nil), ("later", 12), ("padding", 12), ("empty", 8), ("stale", 8), ("duration", 8)]
            for (status, end) in scenarios {
                options.section = SectionRange(start: start, end: end)
                do {
                    _ = try await DownloadEngine().downloadSingle(url: "https://media.invalid/cut-\(status).mp4", settings: settings, options: options)
                    check(false, "a file cut between indexed fragments produced a clip")
                } catch HTTPError.rangeUnsupported {}
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
            check(files.isEmpty, "a short indexed file is not saved, including after a full download with an unknown initial size")
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
            let leaked = stderrText.contains(marker)
            check(formats == 2 && info == 2 && get == 2 && socks4 == 2 && socks4a == 2 && getSocks4 == 2 && settingsSocks4a == 2
                    && added == 0 && !leaked && stderrText.contains("invalid")
                    && !storedBad && !storedSocks4a && storedGood && routed && capitalPort,
                  "invalid proxies exit 2 before any request without repeating the value, settings refuse them, valid ones are installed and a capital SOCKS5 scheme gets port 1080; formats=\(formats), info=\(info), get=\(get), socks4=\(socks4), socks4a=\(socks4a), getSocks4=\(getSocks4), settings=\(settingsSocks4a), requests=\(added), password in stderr=\(leaked), storedBad=\(storedBad), storedSocks4a=\(storedSocks4a), resolved=\(resolved)")
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
