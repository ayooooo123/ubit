import Foundation
import JavaScriptCore
import CryptoKit

public struct YouTubeExtractor: SiteExtractor {
    public var name: String { "YouTube" }

    public init() {}

    public func matches(url: URL) -> Bool {
        ExtractorUtils.hostMatches(url, domains: ["youtube.com", "youtu.be", "youtube-nocookie.com"])
    }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let path = url.path
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let qItems = comps?.queryItems ?? []
        let listID = qItems.first(where: { $0.name == "list" })?.value
        let videoID = Self.extractVideoID(from: url)

        if let listID, videoID == nil || path.hasPrefix("/playlist") {
            return try await extractPlaylist(listID: listID, webpageURL: url.absoluteString, client: client)
        }
        if path.hasPrefix("/results"), let q = qItems.first(where: { $0.name == "search_query" })?.value {
            return try await search(query: q, client: client)
        }
        if path.hasPrefix("/hashtag/") {
            let tag = path.replacingOccurrences(of: "/hashtag/", with: "").split(separator: "/").first.map(String.init) ?? ""
            return try await search(query: "#\(tag)", client: client)
        }
        if videoID == nil && (path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/") || path.hasPrefix("/user/")) {
            return try await extractChannel(url: url, client: client)
        }
        guard let vid = videoID else {
            throw ExtractorError.notFound("Could not find a YouTube video, playlist, or channel at this link.")
        }
        return try await extractVideo(videoID: vid, client: client)
    }

    public static func extractVideoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let seg = path.split(separator: "/").first.map(String.init)
            if let s = seg, s.count == 11 { return s }
        }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, v.count == 11 {
            return v
        }
        for prefix in ["/shorts/", "/embed/", "/live/", "/v/"] {
            if path.hasPrefix(prefix) {
                let rest = String(path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init) ?? ""
                if rest.count == 11 { return rest }
            }
        }
        return nil
    }

    // MARK: - Video Extraction (Multi-Client InnerTube + SAPISIDHASH Auth + JSC Cipher Fallback)

    private struct YTClientProfile {
        let label: String
        let name: String
        let version: String
        let clientNameHeader: String
        let userAgent: String
        let extraFields: [String: Any]
        let supportsCookies: Bool
        let requiresJS: Bool
    }

    private static let visionOSProfile = YTClientProfile(
        label: "visionos",
        name: "VISIONOS",
        version: "1.02",
        clientNameHeader: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        extraFields: [
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
        ],
        supportsCookies: false,
        requiresJS: false
    )

    private static let iosProfile = YTClientProfile(
        label: "ios",
        name: "IOS",
        version: "21.26.4",
        clientNameHeader: "5",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extraFields: [
            "deviceMake": "Apple",
            "deviceModel": "iPhone16,2",
            "osName": "iPhone",
            "osVersion": "18.3.2.22D82",
        ],
        supportsCookies: false,
        requiresJS: false
    )

    private static let tvSamsungProfile = YTClientProfile(
        label: "tv_samsung",
        name: "TVHTML5",
        version: "5.20260707",
        clientNameHeader: "7",
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        extraFields: [
            "deviceMake": "Samsung",
            "deviceModel": "UKS9800",
            "osName": "Tizen",
            "osVersion": "2.4.0",
        ],
        supportsCookies: true,
        requiresJS: true
    )

    private static let webProfile = YTClientProfile(
        label: "web",
        name: "WEB",
        version: "2.20261029.11.00",
        clientNameHeader: "1",
        userAgent: HTTPClient.defaultBrowserUA,
        extraFields: [:],
        supportsCookies: true,
        requiresJS: true
    )

    /// Process-wide YouTube state: one persisted visitor ID, a 5.5 h MediaInfo cache, and the
    /// /player request pacing. It lowers the request rate from one process; it does not
    /// guarantee anything about how YouTube rates the egress IP.
    /// Internal, not private, so that `tests/swift/RegressionChecks.swift` can drive one instance.
    actor YTGuard {
        static let shared = YTGuard()
        /// Minimum time between permits for /player attempts, including retries.
        static let playerGap: TimeInterval = 3

        /// The cache key holds the request context as well as the video, because the
        /// response depends on the cookies sent to YouTube and the media URLs are bound to
        /// the egress IP (the proxy route).
        struct CacheKey: Hashable {
            var videoID: String
            var context: String
        }

        private var visitorData: String?
        private var cache: [CacheKey: (info: MediaInfo, exp: Date)] = [:]
        private var nextPlayerSlot: TimeInterval = 0
        private var lastPlayerPermit: TimeInterval = -.infinity
        private var fileURL: URL { AppPaths.appSupportDir.appendingPathComponent("yt_visitor.txt") }

        func visitor() -> String? {
            if let v = visitorData, !v.isEmpty { return v }
            if let s = try? String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                visitorData = s
                return s
            }
            return nil
        }

        func saveVisitor(_ v: String) {
            guard !v.isEmpty, visitorData == nil else { return }
            visitorData = v
            try? FileManager.default.createDirectory(at: AppPaths.appSupportDir, withIntermediateDirectories: true)
            try? v.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        func cached(_ key: CacheKey) -> MediaInfo? {
            guard let hit = cache[key], hit.exp > Date() else { return nil }
            return hit.info
        }

        func store(_ key: CacheKey, _ info: MediaInfo, now: Date = Date()) {
            cache = cache.filter { $0.value.exp > now }   // a long GUI session must not keep expired entries
            cache[key] = (info, now.addingTimeInterval(5.5 * 3600))
        }

        var entryCount: Int { cache.count }

        /// Drops the video's entries for every request context.
        func invalidate(_ videoID: String) {
            cache = cache.filter { $0.key.videoID != videoID }
        }

        /// Reserves a slot and grants one permit. If several callers wake late, each checks
        /// the time of the last grant before it can proceed. The caller starts HTTP work
        /// after this method returns, so the interval between HTTP starts may be shorter.
        /// Cancellation releases a reservation if no later caller has reserved a slot.
        func pace() async throws {
            let now = ProcessInfo.processInfo.systemUptime
            let slot = max(now, nextPlayerSlot)
            nextPlayerSlot = slot + Self.playerGap
            var wait = max(slot, lastPlayerPermit + Self.playerGap) - now
            do {
                while wait > 0 {
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    wait = lastPlayerPermit + Self.playerGap - ProcessInfo.processInfo.systemUptime
                }
            } catch {
                if nextPlayerSlot == slot + Self.playerGap { nextPlayerSlot = slot }
                throw error
            }
            // The actor cannot grant another permit between the check and this assignment.
            lastPlayerPermit = ProcessInfo.processInfo.systemUptime
            nextPlayerSlot = max(nextPlayerSlot, lastPlayerPermit + Self.playerGap)
        }
    }

    static let playerURL = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"

    /// The request context for the metadata cache: everything that the watch page and /player
    /// requests carry and that can change YouTube's answer. That is the cookies in scope for
    /// each of the two paths, the User-Agent, the extra headers and the proxy route. The context
    /// is hashed so that cookie values are not kept as dictionary keys.
    private static func cacheContext(for client: HTTPClient) -> String {
        let watch = client.cookies.cookieHeader(for: URL(string: "https://www.youtube.com/watch")!) ?? ""
        let player = client.cookies.cookieHeader(for: URL(string: playerURL)!) ?? ""
        let headers = client.defaultHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        let context = ([watch, player, client.userAgent, client.proxy ?? ""] + headers).joined(separator: "\n")
        return SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The SAPISID value for SAPISIDHASH sign-in: the `SAPISID` (or else `__Secure-3PAPISID`)
    /// cookie that a /player request actually sends (in scope, not expired, and not shadowed by a
    /// cookie of the same name with a longer path), when its value is nonempty.
    static func signInCookie(in cookies: CookieVault) -> String? {
        let sent = cookies.effectiveCookies(for: URL(string: playerURL)!).filter { !$0.value.isEmpty }
        return (sent.first { $0.name == "SAPISID" } ?? sent.first { $0.name == "__Secure-3PAPISID" })?.value
    }

    /// Drops the cached metadata of the video at `url`. Pass the extracted `webpageURL`, not the
    /// page that the user entered: an embedding page does not hold the video ID in its own URL.
    public static func invalidateCache(for url: String) async {
        if let u = URL(string: url), let vid = extractVideoID(from: u) {
            await YTGuard.shared.invalidate(vid)
        }
    }

    private static func checkPlaybackDecision(_ response: [String: Any]) throws {
        if let failure = response["error"] as? [String: Any] {
            throw ExtractorError.playbackDenied(failure["message"] as? String ?? "YouTube declined playback.")
        }
        guard let decision = response["playabilityStatus"] as? [String: Any],
              let status = decision["status"] as? String else {
            throw ExtractorError.playbackDenied("YouTube did not confirm playback.")
        }
        let reason = decision["reason"] as? String ?? ""
        if isChallenge(reason) { throw ExtractorError.botGate("YouTube") }
        if status == "LOGIN_REQUIRED" { throw ExtractorError.loginRequired("YouTube") }
        if status != "OK" {
            throw ExtractorError.playbackDenied(reason.isEmpty ? "YouTube declined playback (\(status))." : reason)
        }
        if decision["errorScreen"] != nil { throw ExtractorError.playbackDenied("YouTube declined playback.") }
    }

    private static func isChallenge(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("not a bot") ||
            text.localizedCaseInsensitiveContains("unusual traffic") ||
            text.localizedCaseInsensitiveContains("verify your") ||
            text.localizedCaseInsensitiveContains("confirm your age")
    }

    /// Objects of a verification instruction: the age or identity of the reader, or a statement
    /// that the reader is human.
    private static let noticeObjects: [String] = {
        let human = ["human", "a human", "not a bot", "not a robot"]
        let subjects = ["you are ", "you're ", "you’re "]
        return ["your age", "your identity"] + subjects.flatMap { subject in human.map { subject + $0 } }
    }()

    /// Words that can follow the object of an instruction and start a new part of the sentence:
    /// prepositions, conjunctions and adverbs ("verify your age on this device", "confirm your
    /// identity using your phone", "confirm your identity online", "confirm your identity right
    /// now", "verify your age upon signing in"). Words that end in "ly" are adverbs too. A noun
    /// after the object instead makes it part of a longer name ("your identity provider
    /// settings").
    private static let functionWords: Set<String> = [
        "about", "above", "across", "after", "again", "against", "ahead", "along", "also", "and",
        "around", "as", "at", "because", "before", "below", "beyond", "but", "by", "during", "first",
        "for", "from", "here", "if", "in", "inside", "instead", "into", "later", "now", "offline",
        "on", "once", "online", "or", "per", "please", "prior", "right", "since", "so", "soon",
        "then", "there", "through", "to", "today", "toward", "towards", "under", "unless", "until",
        "upon", "using", "via", "when", "whenever", "where", "while", "with", "within", "without",
    ]

    /// Characters that join two words into one compound word.
    private static let joiners: Set<Character> = ["-", "\u{2010}", "\u{2011}", "'", "’"]

    /// True for "verify" or "confirm", an optional "that", and an object that ends there:
    /// after it comes the end of the text, a character that is not a letter (punctuation, a
    /// digit such as a footnote mark, or a symbol, also after a space), or a word from
    /// `functionWords` or a word that ends in "ly". A hyphen or apostrophe followed by a letter
    /// continues the word. So "verify your agent settings", "confirm your identity provider
    /// settings", "confirm your identity-provider settings" and "verify the cable is not a
    /// bottleneck" are not instructions.
    private static func isInstruction(_ text: String) -> Bool {
        var rest = Substring(text)
        // A purpose clause can precede the imperative: “To continue watching, please verify …”.
        if rest.hasPrefix("to "), let comma = rest.firstIndex(of: ",") {
            rest = rest[rest.index(after: comma)...].drop(while: \.isWhitespace)
        }
        if rest.hasPrefix("please ") { rest = rest.dropFirst(7) }
        guard let verb = ["verify ", "confirm "].first(where: { rest.hasPrefix($0) }) else { return false }
        rest = rest.dropFirst(verb.count)
        if rest.hasPrefix("that ") { rest = rest.dropFirst(5) }
        return noticeObjects.contains { object in
            guard rest.hasPrefix(object) else { return false }
            let after = rest.dropFirst(object.count)
            guard let next = after.first else { return true }
            if next.isWhitespace {
                let following = after.drop(while: \.isWhitespace)
                guard let start = following.first, start.isLetter else { return true }
                let word = String(following.prefix(while: \.isLetter))
                return functionWords.contains(word) || (word.count > 3 && word.hasSuffix("ly"))
            }
            if joiners.contains(next), after.dropFirst().first?.isLetter == true { return false }
            return !next.isLetter
        }
    }

    /// Text that a reader sees as a verification instruction, read from one visible block.
    /// Prose that only explains verification is not a notice.
    private static func isNotice(_ text: String) -> Bool {
        isInstruction(text)
            || (text.contains("playback is blocked") && text.contains("verif"))
            || (text.contains("sign in to confirm") && (text.contains("not a bot") || text.contains("your age")))
            || text.contains("detected unusual traffic")
            || text == "unusual traffic" || text == "not a bot"
    }

    private static func playerResponse(in html: String, at url: URL) throws -> [String: Any]? {
        if url.path.hasPrefix("/sorry/") || url.host == "accounts.google.com" || url.host?.hasPrefix("consent.") == true {
            throw ExtractorError.botGate("YouTube")
        }
        // Embedded player metadata can outlive a page-level verification widget or notice, so
        // both are read first. Only visible content counts: a script, comment, attribute,
        // title or hidden element is not a notice.
        var widget = false
        let blocks = ExtractorUtils.visibleTextBlocks(in: html) { name, attributes in
            let classes = (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace)
            if classes.contains("g-recaptcha") || (name == "iframe" && (attributes["src"] ?? "").contains("/recaptcha/")) {
                widget = true
            }
        }
        if widget || blocks.contains(where: isNotice) {
            throw ExtractorError.botGate("YouTube")
        }
        if let response = ExtractorUtils.extractJSONAfter("ytInitialPlayerResponse =", in: html) as? [String: Any] {
            try checkPlaybackDecision(response)
            return response
        }
        // Missing player metadata is not itself a playback decision.
        return nil
    }

    private struct WatchContext {
        var visitorData: String?
        var jsURL: String?
        var sts: Int?
        var playerResponse: [String: Any]?
    }

    private func fetchWatchContext(videoID: String, client: HTTPClient) async throws -> WatchContext {
        var ctx = WatchContext()
        ctx.visitorData = await YTGuard.shared.visitor()
        if let (html, pageURL) = try await ExtractorUtils.optionalRequest({ try await client.fetchText(
            url: "https://www.youtube.com/watch?v=\(videoID)",
            headers: ["Accept-Language": "en-US,en;q=0.9"]
        ) }) {
            ctx.playerResponse = try Self.playerResponse(in: html, at: pageURL)
            if ctx.visitorData == nil, let v = ExtractorUtils.firstMatch("\"VISITOR_DATA\"\\s*:\\s*\"([^\"]+)\"", in: html) {
                ctx.visitorData = v
                await YTGuard.shared.saveVisitor(v)
            }
            if let jsRel = ExtractorUtils.firstMatch("\"jsUrl\"\\s*:\\s*\"([^\"]+base\\.js)\"", in: html) {
                ctx.jsURL = jsRel.hasPrefix("http") ? jsRel : "https://www.youtube.com\(jsRel)"
            }
            ctx.sts = ExtractorUtils.firstMatch("\"signatureTimestamp\"\\s*:\\s*(\\d+)", in: html).flatMap(Int.init)
        }
        if ctx.visitorData == nil,
           let (sw, _) = try await ExtractorUtils.optionalRequest({ try await client.fetchText(url: "https://www.youtube.com/sw.js_data", includeCookies: false) }),
           let v = ExtractorUtils.firstMatch("\"(Cgt[A-Za-z0-9_-]{10,})\"", in: sw) {
            ctx.visitorData = v
            await YTGuard.shared.saveVisitor(v)
        }
        return ctx
    }

    /// Confirms that the advertised media resource serves a range before selecting it.
    private func verifyTailRangePlayable(url: String, contentLength: Int64?, userAgent: String, client: HTTPClient) async throws -> Bool {
        let clen = contentLength ?? 0
        let probeStart = clen > 131_072 ? (clen - 4096) : 0
        let probeEnd = clen > 131_072 ? (clen - 1) : 2047
        let chunk = try await ExtractorUtils.optionalRequest { try await client.fetchRangeBytes(
                url: url,
                range: ByteRange(start: probeStart, end: probeEnd),
                headers: ["User-Agent": userAgent]
        ) }
        return chunk?.isEmpty == false
    }

    private func extractVideo(videoID: String, client: HTTPClient) async throws -> MediaInfo {
        try Task.checkCancellation()
        // Default headers apply even to requests that omit vault cookies.
        if client.defaultHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Cookie") == .orderedSame }) {
            throw ExtractorError.unsupported("Explicit Cookie headers are not supported for YouTube video extraction.")
        }
        let cacheKey = YTGuard.CacheKey(videoID: videoID, context: Self.cacheContext(for: client))
        if let cached = await YTGuard.shared.cached(cacheKey) { return cached }
        let watchCtx = try await fetchWatchContext(videoID: videoID, client: client)

        // Honor YouTube pre-roll ad slot wait if requested (avoids transient 403 before stream activation)
        if let adSlots = watchCtx.playerResponse?["adSlots"] as? [Any], !adSlots.isEmpty,
           let adJSON = try? JSONSerialization.data(withJSONObject: adSlots),
           let adStr = String(data: adJSON, encoding: .utf8),
           let skipMsStr = ExtractorUtils.firstMatch("\"skipOffsetMilliseconds\"\\s*:\\s*\"?(\\d+)\"?", in: adStr),
           let skipMs = Int(skipMsStr), skipMs > 0 {
            let waitMs = min(4000, skipMs)
            try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
        }

        let candidateProfiles: [YTClientProfile] = [
            Self.visionOSProfile,
            Self.tvSamsungProfile,
            Self.iosProfile,
            Self.webProfile,
        ]

        var chosenResp: [String: Any]?
        var chosenFormats: [MediaFormat] = []
        var chosenHLSManifest: String?
        var chosenHLSUA: String = Self.visionOSProfile.userAgent
        var cachedSolver: JSPlayerCipherSolver?
        var loadedSolver = false

        for profile in candidateProfiles {
            let resp = try await callPlayer(videoID: videoID, profile: profile,
                                            visitorData: watchCtx.visitorData,
                                            sts: profile.requiresJS ? watchCtx.sts : nil, client: client)

            try Self.checkPlaybackDecision(resp)
            guard let sd = resp["streamingData"] as? [String: Any] else { continue }

            if chosenHLSManifest == nil, let hlsM = sd["hlsManifestUrl"] as? String {
                chosenHLSManifest = hlsM
                chosenHLSUA = profile.userAgent
            }

            let rawFmts = ((sd["formats"] as? [[String: Any]]) ?? []) + ((sd["adaptiveFormats"] as? [[String: Any]]) ?? [])
            let hasCipher = rawFmts.contains { $0["url"] == nil && ($0["signatureCipher"] != nil || $0["cipher"] != nil) }
            let needsJS = hasCipher || (profile.requiresJS && !rawFmts.isEmpty)

            if needsJS && !loadedSolver {
                loadedSolver = true
                cachedSolver = try await ExtractorUtils.optionalRequest { try await loadPlayerCipherSolver(videoID: videoID, knownJSURL: watchCtx.jsURL, client: client) }
            }

            var parsed: [MediaFormat] = []
            for f in rawFmts {
                guard let itag = f["itag"] as? Int else { continue }
                var streamURL = f["url"] as? String
                if streamURL == nil, let cipherStr = (f["signatureCipher"] as? String) ?? (f["cipher"] as? String),
                   let solver = cachedSolver {
                    streamURL = solver.resolveCipher(cipherStr)
                }
                guard var finalStreamURL = streamURL, !finalStreamURL.isEmpty else { continue }
                if let solver = cachedSolver {
                    finalStreamURL = solver.transformNParam(in: finalStreamURL)
                }

                let mime = (f["mimeType"] as? String) ?? "video/mp4"
                let (ext, vcodec, acodec) = Self.parseYouTubeMime(mime)
                let width = f["width"] as? Int
                let height = f["height"] as? Int
                let fps = (f["fps"] as? Double) ?? (f["fps"] as? Int).map(Double.init)
                let bitrate = (f["averageBitrate"] as? Int64) ?? (f["bitrate"] as? Int64) ?? (f["bitrate"] as? Int).map(Int64.init)
                let clen = (f["contentLength"] as? String).flatMap(Int64.init)
                let qLabel = (f["qualityLabel"] as? String)

                var initR: ByteRange?
                if let ir = f["initRange"] as? [String: Any],
                   let s = (ir["start"] as? String).flatMap(Int64.init),
                   let e = (ir["end"] as? String).flatMap(Int64.init) {
                    initR = ByteRange(start: s, end: e)
                }
                var idxR: ByteRange?
                if let xr = f["indexRange"] as? [String: Any],
                   let s = (xr["start"] as? String).flatMap(Int64.init),
                   let e = (xr["end"] as? String).flatMap(Int64.init) {
                    idxR = ByteRange(start: s, end: e)
                }

                parsed.append(MediaFormat(
                    id: String(itag),
                    url: finalStreamURL,
                    ext: ext,
                    proto: .http,
                    vcodec: vcodec,
                    acodec: acodec,
                    width: width,
                    height: height,
                    fps: fps,
                    bitrate: bitrate,
                    filesize: clen,
                    audioSampleRate: (f["audioSampleRate"] as? String).flatMap(Int.init),
                    qualityLabel: qLabel,
                    headers: ["User-Agent": profile.userAgent],
                    initRange: initR,
                    indexRange: idxR
                ))
            }

            if let probeTarget = parsed.first(where: { ($0.filesize ?? 0) > 2_000_000 }) ?? parsed.first {
                let playable = try await verifyTailRangePlayable(
                    url: probeTarget.url,
                    contentLength: probeTarget.filesize,
                    userAgent: profile.userAgent,
                    client: client
                )
                if playable {
                    chosenResp = resp
                    chosenFormats = parsed
                    break
                }
            } else if sd["hlsManifestUrl"] != nil {
                chosenResp = resp
                break
            }
        }

        let metaResp = chosenResp ?? watchCtx.playerResponse
        guard let resp = metaResp else {
            throw ExtractorError.notFound("YouTube player request failed for \(videoID).")
        }

        let details = (resp["videoDetails"] as? [String: Any])
            ?? (watchCtx.playerResponse?["videoDetails"] as? [String: Any])
            ?? [:]
        let micro = ((watchCtx.playerResponse?["microformat"] ?? resp["microformat"]) as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any]

        let title = (details["title"] as? String) ?? videoID
        let author = (details["author"] as? String)
        let description = (details["shortDescription"] as? String) ?? ((micro?["description"] as? [String: Any])?["simpleText"] as? String)
        let duration = (details["lengthSeconds"] as? String).flatMap(Double.init)
        let isLive = (details["isLiveContent"] as? Bool == true) && ((details["isLive"] as? Bool == true) || duration == 0)
        let uploadDate = (micro?["publishDate"] as? String).map { String($0.prefix(10)) }
        let thumb = "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg"

        var formats = chosenFormats
        // An ordinary player response can advertise HLS instead of direct formats.
        if let hlsManifest = chosenHLSManifest ?? ((watchCtx.playerResponse?["streamingData"] as? [String: Any])?["hlsManifestUrl"] as? String) {
            if isLive || formats.isEmpty {
                if let hlsFmts = try await ExtractorUtils.optionalRequest({ try await HLSEngine.extractFormats(client: client, playlistURL: hlsManifest, headers: ["User-Agent": chosenHLSUA], idPrefix: "hls") }) {
                    for var hf in hlsFmts {
                        hf.isLive = isLive
                        formats.append(hf)
                    }
                }
            }
        }

        if formats.isEmpty {
            throw ExtractorError.notFound("YouTube: No playable non-DRM streams returned")
        }

        // Subtitles from watch page player response (or chosen response)
        var subtitles: [SubtitleTrack] = []
        let capSource = (watchCtx.playerResponse?["captions"] != nil) ? watchCtx.playerResponse : resp
        if let tracklist = ((capSource?["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any])?["captionTracks"] as? [[String: Any]] {
            for ct in tracklist {
                guard let base = ct["baseUrl"] as? String,
                      let lang = ct["languageCode"] as? String else { continue }
                let isAuto = (ct["kind"] as? String) == "asr"
                let nameObj = ct["name"] as? [String: Any]
                let dispName = (nameObj?["simpleText"] as? String)
                    ?? (((nameObj?["runs"] as? [[String: Any]])?.first)?["text"] as? String)
                    ?? lang
                let vttURL = base.contains("fmt=") ? base : (base + "&fmt=vtt")
                subtitles.append(SubtitleTrack(lang: lang, name: dispName, url: vttURL, ext: "vtt", isAutoGenerated: isAuto))
            }
        }

        let chapters = SponsorAndSubtitles.chaptersFromDescription(description, totalDuration: duration)

        let info = MediaInfo(
            id: videoID,
            title: title,
            site: "YouTube",
            webpageURL: "https://www.youtube.com/watch?v=\(videoID)",
            author: author,
            uploadDate: uploadDate,
            description: description,
            duration: duration,
            thumbnail: thumb,
            isLive: isLive,
            formats: formats,
            subtitles: subtitles,
            chapters: chapters
        )
        try Task.checkCancellation()
        await YTGuard.shared.store(cacheKey, info)
        return info
    }

    private func callPlayer(
        videoID: String,
        profile: YTClientProfile,
        visitorData: String?,
        sts: Int?,
        client: HTTPClient
    ) async throws -> [String: Any] {
        var clientDict: [String: Any] = [
            "clientName": profile.name,
            "clientVersion": profile.version,
            "hl": "en",
            "gl": "US",
            "userAgent": profile.userAgent,
        ]
        if let visitorData, !visitorData.isEmpty {
            clientDict["visitorData"] = visitorData
        }
        for (k, v) in profile.extraFields { clientDict[k] = v }

        let context: [String: Any] = ["client": clientDict]
        var bodyObj: [String: Any] = [
            "videoId": videoID,
            "context": context,
        ]
        if let sts {
            bodyObj["playbackContext"] = [
                "contentPlaybackContext": [
                    "signatureTimestamp": sts,
                    "html5Preference": "HTML5_PREF_WANTS",
                ]
            ]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj)
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "User-Agent": profile.userAgent,
            "X-YouTube-Client-Name": profile.clientNameHeader,
            "X-YouTube-Client-Version": profile.version,
            "Origin": "https://www.youtube.com",
        ]
        if let visitorData, !visitorData.isEmpty {
            headers["X-Goog-Visitor-Id"] = visitorData
        }

        if profile.supportsCookies, let sapisid = Self.signInCookie(in: client.cookies) {
            let ts = Int(Date().timeIntervalSince1970)
            let input = "\(ts) \(sapisid) https://www.youtube.com"
            let sha1 = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            headers["Authorization"] = "SAPISIDHASH \(ts)_\(sha1)"
            headers["X-Origin"] = "https://www.youtube.com"
        }

        // Each retry after a transient server error waits for its own pacing slot.
        // the HTTP client's own (unpaced) retry loop is turned off for this request.
        var attempt = 0
        while true {
            try await YTGuard.shared.pace()
            do {
                let (data, _) = try await client.fetchData(
                    url: Self.playerURL,
                    method: "POST",
                    headers: headers,
                    body: bodyData,
                    includeCookies: profile.supportsCookies,
                    retries: 1
                )
                guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw ExtractorError.notFound("YouTube did not return a player response.")
                }
                return response
            } catch HTTPError.status(let code, _) where attempt < 2 && [500, 502, 503, 504].contains(code) {
                attempt += 1
            } catch let error as URLError where attempt < 2 && HTTPClient.canRetryTransport(error) {
                attempt += 1
            }
        }
    }

    private static func parseYouTubeMime(_ mime: String) -> (ext: String, vcodec: String?, acodec: String?) {
        // e.g. video/mp4; codecs="avc1.64002A, mp4a.40.2" or audio/mp4; codecs="mp4a.40.2"
        let mainPart = mime.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? "video/mp4"
        let isAudioOnly = mainPart.hasPrefix("audio/")
        let isWebM = mainPart.contains("webm")
        let ext = isWebM ? "webm" : (isAudioOnly ? "m4a" : "mp4")

        let codecsStr = ExtractorUtils.firstMatch("codecs=\"([^\"]+)\"", in: mime) ?? ""
        let codecs = codecsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        if isAudioOnly {
            return (ext, "none", codecs.first ?? (isWebM ? "opus" : "mp4a.40.2"))
        }
        if codecs.count >= 2 {
            return (ext, codecs[0], codecs[1])
        }
        return (ext, codecs.first ?? "avc1", "none")
    }

    // MARK: - Playlists, Channels & Search (InnerTube `browse` & `search` with Continuation Tokens)

    private func extractPlaylist(listID: String, webpageURL: String, client: HTTPClient) async throws -> MediaInfo {
        let browseID = listID.hasPrefix("VL") ? listID : "VL\(listID)"
        let resp = try await callInnerTube(endpoint: "browse", payload: ["browseId": browseID], client: client)

        let title = Self.findString(in: resp, keys: ["title"]) ?? "Playlist \(listID)"
        var entries: [PlaylistEntry] = []
        var continuation: String?
        Self.collectPlaylistItems(in: resp, entries: &entries, continuation: &continuation)

        // Follow continuation pages (no 100-video cap!)
        var pageCount = 0
        while let cont = continuation, pageCount < 25 {
            continuation = nil
            pageCount += 1
            if let nextResp = try await ExtractorUtils.optionalRequest({ try await callInnerTube(endpoint: "browse", payload: ["continuation": cont], client: client) }) {
                Self.collectPlaylistItems(in: nextResp, entries: &entries, continuation: &continuation)
            }
        }

        guard !entries.isEmpty else {
            throw ExtractorError.notFound("This YouTube playlist is empty or private.")
        }

        return MediaInfo(
            id: listID,
            title: title,
            site: "YouTube",
            webpageURL: webpageURL,
            thumbnail: entries.first?.thumbnail,
            entries: entries
        )
    }

    private func extractChannel(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, _) = try await client.fetchText(url: url.absoluteString)
        guard let initialData = ExtractorUtils.extractJSONAfter("var ytInitialData =", in: html)
                ?? ExtractorUtils.extractJSONAfter("ytInitialData =", in: html) else {
            throw ExtractorError.notFound("Could not read YouTube channel page.")
        }
        let channelTitle = ExtractorUtils.metaContent("og:title", in: html) ?? url.lastPathComponent
        let channelID = ExtractorUtils.firstMatch("\"externalId\":\"(UC[A-Za-z0-9_-]{22})\"", in: html) ?? url.lastPathComponent

        // Convert channel ID UC... -> uploads playlist UU... for complete video feed!
        if channelID.hasPrefix("UC") && channelID.count == 24 {
            let uploadsList = "UU" + channelID.dropFirst(2)
            if var pl = try await ExtractorUtils.optionalRequest({ try await extractPlaylist(listID: uploadsList, webpageURL: url.absoluteString, client: client) }), !pl.entries.isEmpty {
                pl.title = channelTitle
                pl.id = channelID
                return pl
            }
        }

        var entries: [PlaylistEntry] = []
        var cont: String?
        Self.collectPlaylistItems(in: initialData, entries: &entries, continuation: &cont)
        return MediaInfo(
            id: channelID,
            title: channelTitle,
            site: "YouTube",
            webpageURL: url.absoluteString,
            thumbnail: entries.first?.thumbnail,
            entries: entries
        )
    }

    public func search(query: String, client: HTTPClient) async throws -> MediaInfo {
        let resp = try await callInnerTube(endpoint: "search", payload: ["query": query], client: client)
        var entries: [PlaylistEntry] = []
        var cont: String?
        Self.collectPlaylistItems(in: resp, entries: &entries, continuation: &cont)
        guard !entries.isEmpty else {
            throw ExtractorError.notFound("No YouTube results found for '\(query)'.")
        }
        return MediaInfo(
            id: "search-\(abs(query.hashValue))",
            title: "Search: \(query)",
            site: "YouTube",
            webpageURL: "https://www.youtube.com/results?search_query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)",
            thumbnail: entries.first?.thumbnail,
            entries: entries
        )
    }

    private func callInnerTube(endpoint: String, payload: [String: Any], client: HTTPClient) async throws -> Any {
        var body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": Self.webProfile.version,
                    "hl": "en",
                    "gl": "US",
                ]
            ]
        ]
        for (k, v) in payload { body[k] = v }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await client.fetchJSON(
            url: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false",
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Origin": "https://www.youtube.com",
            ],
            body: data
        )
    }

    private static func findString(in obj: Any, keys: Set<String>) -> String? {
        if let dict = obj as? [String: Any] {
            if let meta = dict["playlistMetadataRenderer"] as? [String: Any], let t = meta["title"] as? String {
                return t
            }
            for k in keys {
                if let s = dict[k] as? String, !s.isEmpty { return s }
            }
            for (_, v) in dict {
                if let r = findString(in: v, keys: keys) { return r }
            }
        } else if let arr = obj as? [Any] {
            for item in arr {
                if let r = findString(in: item, keys: keys) { return r }
            }
        }
        return nil
    }

    private static func collectPlaylistItems(in node: Any, entries: inout [PlaylistEntry], continuation: inout String?) {
        if let dict = node as? [String: Any] {
            if let vr = (dict["playlistVideoRenderer"] as? [String: Any]) ?? (dict["videoRenderer"] as? [String: Any]) ?? (dict["reelItemRenderer"] as? [String: Any]) {
                if let vid = vr["videoId"] as? String, !entries.contains(where: { $0.id == vid }) {
                    let titleObj = vr["title"] as? [String: Any]
                    let title = (titleObj?["simpleText"] as? String)
                        ?? (((titleObj?["runs"] as? [[String: Any]])?.first)?["text"] as? String)
                        ?? vid
                    let durStr = (vr["lengthSeconds"] as? String)
                        ?? ((vr["lengthText"] as? [String: Any])?["simpleText"] as? String)
                    let dur = durStr.flatMap(SectionRange.parseTimestamp)
                    entries.append(PlaylistEntry(
                        id: vid,
                        title: title,
                        url: "https://www.youtube.com/watch?v=\(vid)",
                        duration: dur,
                        thumbnail: "https://i.ytimg.com/vi/\(vid)/mqdefault.jpg"
                    ))
                }
                return
            }
            if let ce = dict["continuationEndpoint"] as? [String: Any],
               let cc = ce["continuationCommand"] as? [String: Any],
               let token = cc["token"] as? String, continuation == nil {
                continuation = token
            }
            for (_, v) in dict {
                collectPlaylistItems(in: v, entries: &entries, continuation: &continuation)
            }
        } else if let arr = node as? [Any] {
            for x in arr {
                collectPlaylistItems(in: x, entries: &entries, continuation: &continuation)
            }
        }
    }

    // MARK: - Lightweight Native JavaScriptCore Cipher Solver (0 KB Embedded JS AST Bloat!)

    private func loadPlayerCipherSolver(videoID: String, knownJSURL: String?, client: HTTPClient) async throws -> JSPlayerCipherSolver? {
        var resolvedJSURL = knownJSURL
        if resolvedJSURL == nil {
            let (embedHTML, pageURL) = try await client.fetchText(url: "https://www.youtube.com/embed/\(videoID)")
            _ = try Self.playerResponse(in: embedHTML, at: pageURL)
            if let jsRel = ExtractorUtils.firstMatch("\"jsUrl\":\"([^\"]+base\\.js)\"", in: embedHTML) {
                resolvedJSURL = jsRel.hasPrefix("http") ? jsRel : "https://www.youtube.com\(jsRel)"
            }
        }
        guard let jsURL = resolvedJSURL else { return nil }
        let (jsCode, _) = try await client.fetchText(url: jsURL, includeCookies: false)
        return JSPlayerCipherSolver(playerJS: jsCode)
    }
}

private final class JSPlayerCipherSolver: @unchecked Sendable {
    private let lock = NSLock()
    private let ctx: JSContext?
    private var hasSigFn = false
    private var hasNFn = false

    init(playerJS: String) {
        let context = JSContext()
        self.ctx = context
        // 1. Signature decipher function
        if let sigFnName = ExtractorUtils.firstMatch("\\b[cs]\\s*&&\\s*[adf]\\.set\\([^,]+,\\s*encodeURIComponent\\(([a-zA-Z0-9$]+)\\(", in: playerJS)
            ?? ExtractorUtils.firstMatch("([a-zA-Z0-9$]+)\\s*=\\s*function\\(\\s*a\\s*\\)\\s*\\{\\s*a\\s*=\\s*a\\.split\\(\\s*\"\"\\s*\\)", in: playerJS) {
            let escapedFn = NSRegularExpression.escapedPattern(for: sigFnName)
            if let fnBody = ExtractorUtils.firstMatch("(?:var\\s+)?\(escapedFn)\\s*=\\s*(function\\(\\s*a\\s*\\)\\s*\\{[^}]+\\})", in: playerJS) {
                var script = ""
                if let helperObj = ExtractorUtils.firstMatch(";([a-zA-Z0-9$]{2,})\\.[a-zA-Z0-9$]+\\(a,\\d+\\)", in: fnBody) {
                    let escObj = NSRegularExpression.escapedPattern(for: helperObj)
                    if let objDecl = ExtractorUtils.firstMatch("(var\\s+\(escObj)\\s*=\\s*\\{[\\s\\S]*?\\};)", in: playerJS) {
                        script += objDecl + "\n"
                    }
                }
                script += "var __decipher = \(fnBody);"
                context?.evaluateScript(script)
                hasSigFn = true
            }
        }
        // 2. Throttle `n`-challenge function extraction
        if let nArrName = ExtractorUtils.firstMatch("\\.get\\(\"n\"\\)\\)&&\\(b=([a-zA-Z0-9$]+)(?:\\[(\\d+)\\])?\\([a-zA-Z0-9]\\)", in: playerJS) {
            var fnName = nArrName
            let escArr = NSRegularExpression.escapedPattern(for: nArrName)
            if let realFn = ExtractorUtils.firstMatch("var\\s+\(escArr)\\s*=\\s*\\[([a-zA-Z0-9$]+)\\]", in: playerJS) {
                fnName = realFn
            }
            let escFn = NSRegularExpression.escapedPattern(for: fnName)
            if let nBody = ExtractorUtils.firstMatch("\(escFn)\\s*=\\s*(function\\([a-zA-Z0-9]\\)\\{[\\s\\S]*?return\\s+[a-zA-Z0-9]\\.join\\(\"\"\\)\\})", in: playerJS) {
                context?.evaluateScript("var __nsolve = \(nBody);")
                if context?.exception == nil { hasNFn = true }
                context?.exception = nil
            }
        }
    }

    func resolveCipher(_ cipherQuery: String) -> String? {
        var comps = URLComponents()
        comps.percentEncodedQuery = cipherQuery
        let items = comps.queryItems ?? []
        guard var baseURL = items.first(where: { $0.name == "url" })?.value else { return nil }
        let sp = items.first(where: { $0.name == "sp" })?.value ?? "sig"
        if let s = items.first(where: { $0.name == "s" })?.value, hasSigFn {
            lock.lock()
            let decodedSig = ctx?.objectForKeyedSubscript("__decipher")?.call(withArguments: [s])?.toString()
            lock.unlock()
            if let sig = decodedSig, !sig.isEmpty, sig != "undefined" {
                let sep = baseURL.contains("?") ? "&" : "?"
                baseURL += "\(sep)\(sp)=\(sig.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sig)"
            }
        }
        return baseURL
    }

    func transformNParam(in url: String) -> String {
        guard hasNFn, var comps = URLComponents(string: url),
              var items = comps.queryItems,
              let idx = items.firstIndex(where: { $0.name == "n" }),
              let oldN = items[idx].value else {
            return url
        }
        lock.lock()
        let newN = ctx?.objectForKeyedSubscript("__nsolve")?.call(withArguments: [oldN])?.toString()
        lock.unlock()
        if let newN, !newN.isEmpty, newN != "undefined", newN != oldN {
            items[idx].value = newN
            comps.queryItems = items
            return comps.url?.absoluteString ?? url
        }
        return url
    }
}
