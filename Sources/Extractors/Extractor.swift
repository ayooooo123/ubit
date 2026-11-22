import Foundation

public protocol SiteExtractor: Sendable {
    var name: String { get }
    func matches(url: URL) -> Bool
    func extract(url: URL, client: HTTPClient) async throws -> MediaInfo
}

public enum ExtractorError: LocalizedError {
    case unsupported(String)
    case notFound(String)
    case drmProtected
    case loginRequired(String)
    case playbackDenied(String)
    /// The provider requires verification. Local credentials do not complete that check.
    case botGate(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let m): return m
        case .notFound(let m): return m
        case .drmProtected: return "This media is protected by DRM and can't be downloaded."
        case .loginRequired(let site): return "\(site) asked to sign in. Open uBit's Browser (⌘B) and sign in to \(site), or pass --cookies."
        case .playbackDenied(let reason): return reason
        case .botGate(let site): return "\(site) requires verification. Extraction stopped."
        }
    }
}

public enum ExtractorUtils {
    /// Optional metadata may be absent. A refusal or cancellation must reach the caller.
    static func optionalRequest<T>(_ operation: () async throws -> T?) async throws -> T? {
        do {
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            guard !mustStop(error) else { throw error }
            return nil
        }
    }

    static func mustStop(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, ExtractorError.botGate, ExtractorError.loginRequired,
             ExtractorError.playbackDenied, ExtractorError.drmProtected: return true
        case let transport as URLError: return !HTTPClient.canRetryTransport(transport)
        case HTTPError.status(let code, _): return (400..<500).contains(code) && code != 404
        default: return false
        }
    }

    public static func hostMatches(_ url: URL, domains: [String]) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    public static func firstMatch(_ pattern: String, in text: String, group: Int = 1, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > group,
              m.range(at: group).location != NSNotFound,
              let r = Range(m.range(at: group), in: text) else {
            return nil
        }
        return String(text[r])
    }

    public static func allMatches(_ pattern: String, in text: String, group: Int = 1, options: NSRegularExpression.Options = []) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard m.numberOfRanges > group, m.range(at: group).location != NSNotFound, let r = Range(m.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Extracts a balanced JSON `{...}` or `[...]` value immediately following `marker` in HTML/JS text.
    public static func extractJSONAfter(_ marker: String, in text: String) -> Any? {
        guard let range = text.range(of: marker) else { return nil }
        var idx = range.upperBound
        while idx < text.endIndex && (text[idx].isWhitespace || text[idx] == "=") {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, (text[idx] == "{" || text[idx] == "[") else { return nil }
        let openCh = text[idx]
        let closeCh: Character = (openCh == "{") ? "}" : "]"

        var depth = 0
        var inStr = false
        var quoteCh: Character = "\""
        var escaped = false
        let start = idx

        while idx < text.endIndex {
            let c = text[idx]
            if inStr {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == quoteCh { inStr = false }
            } else {
                if c == "\"" || c == "'" {
                    inStr = true
                    quoteCh = c
                } else if c == openCh {
                    depth += 1
                } else if c == closeCh {
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: idx)
                        let sub = String(text[start..<end]).replacingOccurrences(of: ":undefined", with: ":null")
                        if let data = sub.data(using: .utf8) {
                            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                        }
                        return nil
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    public static func metaContent(_ prop: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: prop)
        let patterns = [
            "<meta[^>]+(?:property|name|itemprop)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name|itemprop)=[\"']\(escaped)[\"']",
        ]
        for p in patterns {
            if let val = firstMatch(p, in: html, options: [.caseInsensitive]) {
                return SponsorAndSubtitles.decodeHTMLEntities(val)
            }
        }
        return nil
    }

    public static func pageTitle(in html: String) -> String? {
        if let og = metaContent("og:title", in: html) ?? metaContent("twitter:title", in: html), !og.isEmpty {
            return og
        }
        if let t = firstMatch("<title[^>]*>([\\s\\S]*?)</title>", in: html, options: [.caseInsensitive]) {
            return SponsorAndSubtitles.decodeHTMLEntities(t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static let inlineElements: Set<String> = [
        "a", "abbr", "b", "bdi", "bdo", "br", "cite", "code", "data", "dfn", "em", "font", "i", "kbd", "label",
        "mark", "q", "s", "samp", "small", "span", "strong", "sub", "sup", "time", "u", "var", "wbr",
    ]
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]
    private static let rawTextElements: Set<String> = ["script", "style", "title", "textarea", "xmp", "iframe"]

    /// The text that a reader can see on an HTML page: one lowercased entry per block, with
    /// whitespace collapsed. Inline markup such as `<strong>`, `<span>` or a link does not split
    /// a block. Comments, script, style, title and template content are left out, and so is
    /// everything under a hidden ancestor: `hidden`, `aria-hidden="true"`, `display:none`,
    /// `visibility:hidden`, a closed `<dialog>` or `<noscript>`. `onElement` receives the name
    /// and the attributes of each visible element.
    static func visibleTextBlocks(in html: String, onElement: (String, [String: String]) -> Void = { _, _ in }) -> [String] {
        let bytes = Array(html.utf8), n = bytes.count
        var blocks: [String] = [], run: [UInt8] = []
        var open: [(name: String, hidden: Bool)] = []
        let commentOpen = Array("<!--".utf8), commentClose = Array("-->".utf8)
        func lower(_ b: UInt8) -> UInt8 { (0x41...0x5A).contains(b) ? b + 0x20 : b }
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D }
        func matches(_ needle: [UInt8], at k: Int) -> Bool {
            guard k + needle.count <= n else { return false }
            for m in 0..<needle.count where lower(bytes[k + m]) != needle[m] { return false }
            return true
        }
        func find(_ needle: [UInt8], from start: Int) -> Int? {
            var k = start
            while k + needle.count <= n { if matches(needle, at: k) { return k }; k += 1 }
            return nil
        }
        func flush() {
            guard !run.isEmpty else { return }
            let text = SponsorAndSubtitles.decodeHTMLEntities(String(decoding: run, as: UTF8.self)).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { blocks.append(text) }
            run.removeAll(keepingCapacity: true)
        }
        var i = 0
        while i < n {
            let hidden = open.last?.hidden ?? false
            guard bytes[i] == 0x3C else {
                let start = i
                while i < n, bytes[i] != 0x3C { i += 1 }
                if !hidden { run.append(contentsOf: bytes[start..<i]) }
                continue
            }
            if matches(commentOpen, at: i) {
                i = find(commentClose, from: i + 4).map { $0 + 3 } ?? n
                continue
            }
            if i + 1 < n, bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F {
                i = find([0x3E], from: i).map { $0 + 1 } ?? n
                continue
            }
            let closing = i + 1 < n && bytes[i + 1] == 0x2F
            let nameStart = i + (closing ? 2 : 1)
            var k = nameStart
            while k < n, (0x61...0x7A).contains(lower(bytes[k])) || (0x30...0x39).contains(bytes[k]) || bytes[k] == 0x2D || bytes[k] == 0x3A { k += 1 }
            guard k > nameStart, (0x61...0x7A).contains(lower(bytes[nameStart])) else {
                // A "<" that does not start a tag is text.
                if !hidden { run.append(bytes[i]) }
                i += 1
                continue
            }
            let name = String(decoding: bytes[nameStart..<k].map(lower), as: UTF8.self)
            var attributes: [String: String] = [:], selfClosing = false
            while k < n, bytes[k] != 0x3E {
                if isSpace(bytes[k]) { k += 1; continue }
                if bytes[k] == 0x2F { selfClosing = true; k += 1; continue }
                selfClosing = false
                let attrStart = k
                while k < n, !isSpace(bytes[k]), bytes[k] != 0x3D, bytes[k] != 0x3E, bytes[k] != 0x2F { k += 1 }
                let attr = String(decoding: bytes[attrStart..<k].map(lower), as: UTF8.self)
                while k < n, isSpace(bytes[k]) { k += 1 }
                var value = ""
                if k < n, bytes[k] == 0x3D {
                    k += 1
                    while k < n, isSpace(bytes[k]) { k += 1 }
                    if k < n, bytes[k] == 0x22 || bytes[k] == 0x27 {
                        let quote = bytes[k], valueStart = k + 1
                        k = valueStart
                        while k < n, bytes[k] != quote { k += 1 }
                        value = String(decoding: bytes[valueStart..<min(k, n)], as: UTF8.self)
                        k += 1
                    } else {
                        let valueStart = k
                        while k < n, !isSpace(bytes[k]), bytes[k] != 0x3E { k += 1 }
                        value = String(decoding: bytes[valueStart..<k], as: UTF8.self)
                    }
                }
                if !attr.isEmpty { attributes[attr] = value }
            }
            i = min(k + 1, n)
            let inline = inlineElements.contains(name)
            if !inline { flush() } else if name == "br" && !hidden { run.append(0x20) }
            if closing {
                if let index = open.lastIndex(where: { $0.name == name }) { open.removeSubrange(index...) }
                continue
            }
            let style = (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
            let isHidden = hidden || attributes["hidden"] != nil || attributes["aria-hidden"]?.lowercased() == "true"
                || style.contains("display:none") || style.contains("visibility:hidden")
                || (name == "dialog" && attributes["open"] == nil) || name == "template" || name == "noscript"
            if !isHidden { onElement(name, attributes) }
            if rawTextElements.contains(name) {
                let end = find(Array("</\(name)".utf8), from: i)
                i = end.flatMap { find([0x3E], from: $0) }.map { $0 + 1 } ?? n
                continue
            }
            if !voidElements.contains(name) && !selfClosing { open.append((name, isHidden)) }
        }
        flush()
        return blocks
    }

    public static func unescapeJSString(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u003D", with: "=")
            .replacingOccurrences(of: "\\u0025", with: "%")
            .replacingOccurrences(of: "&amp;", with: "&")
        if let data = "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"".data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            s = decoded
        }
        return s
    }

    public static func formatUnixDate(_ ts: TimeInterval) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date(timeIntervalSince1970: ts))
    }
}

public enum ExtractorRegistry {
    public static let extractors: [SiteExtractor] = [
        YouTubeExtractor(),
        VimeoExtractor(),
        SoundCloudExtractor(),
        BilibiliExtractor(),
        TwitchExtractor(),
        KickExtractor(),
        RedditExtractor(),
        TwitterExtractor(),
        BlueskyExtractor(),
        TikTokExtractor(),
        InstagramExtractor(),
        FacebookExtractor(),
        ThreadsExtractor(),
        BandcampExtractor(),
        MixcloudExtractor(),
        DailymotionExtractor(),
        RumbleExtractor(),
        OdyseeExtractor(),
        InternetArchiveExtractor(),
        ImgurExtractor(),
        TumblrExtractor(),
        PinterestExtractor(),
        StreamableExtractor(),
        LoomExtractor(),
        TEDExtractor(),
        VKExtractor(),
        DouyinExtractor(),
        KuaishouExtractor(),
        WeiboExtractor(),
        XiaohongshuExtractor(),
        GitHubMediaExtractor(),
        CoubExtractor(),
        NineGagExtractor(),
        MastodonExtractor(),
        PeerTubeExtractor(),
    ]

    public static var supportedSiteNames: [String] {
        Array(Set(extractors.map(\.name))).sorted()
    }

    public static func extract(url rawInput: String, client: HTTPClient) async throws -> MediaInfo {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // Support plain search queries via YouTube search (`ytsearch:` or non-URL string)
        if trimmed.hasPrefix("ytsearch:") {
            let q = String(trimmed.dropFirst("ytsearch:".count))
            return try await YouTubeExtractor().search(query: q, client: client)
        }
        let normalizedURLString: String
        if !trimmed.contains("://") {
            if trimmed.contains(".") && !trimmed.contains(" ") {
                normalizedURLString = "https://" + trimmed
            } else {
                return try await YouTubeExtractor().search(query: trimmed, client: client)
            }
        } else {
            normalizedURLString = trimmed
        }

        guard let parsedURL = URL(string: normalizedURLString) else {
            throw ExtractorError.unsupported("Invalid URL: \(rawInput)")
        }

        // Direct media / manifest URL shortcut (.mp4, .m4a, .webm, .mp3, .m3u8, .mpd)
        let pathExt = parsedURL.pathExtension.lowercased()
        if ["m3u8"].contains(pathExt) {
            let fmts = try await HLSEngine.extractFormats(client: client, playlistURL: parsedURL.absoluteString)
            return MediaInfo(
                id: parsedURL.deletingPathExtension().lastPathComponent,
                title: parsedURL.deletingPathExtension().lastPathComponent.isEmpty ? "HLS Stream" : parsedURL.deletingPathExtension().lastPathComponent,
                site: parsedURL.host ?? "HLS",
                webpageURL: parsedURL.absoluteString,
                isLive: fmts.contains(where: \.isLive),
                formats: fmts
            )
        }
        if ["mpd"].contains(pathExt) {
            let (fmts, _, isDRM) = try await DASHEngine.extractFormats(client: client, mpdURL: parsedURL.absoluteString)
            return MediaInfo(
                id: parsedURL.deletingPathExtension().lastPathComponent,
                title: parsedURL.deletingPathExtension().lastPathComponent.isEmpty ? "DASH Stream" : parsedURL.deletingPathExtension().lastPathComponent,
                site: parsedURL.host ?? "DASH",
                webpageURL: parsedURL.absoluteString,
                isLive: fmts.contains(where: \.isLive),
                isDRM: isDRM,
                formats: fmts
            )
        }
        if ["mp4", "m4a", "mov", "webm", "mp3", "wav", "flac", "opus", "mkv"].contains(pathExt) {
            let isAudio = ["m4a", "mp3", "wav", "flac", "opus"].contains(pathExt)
            let name = parsedURL.deletingPathExtension().lastPathComponent
            return MediaInfo(
                id: name.isEmpty ? "direct" : name,
                title: (name.removingPercentEncoding ?? name).isEmpty ? "Direct Media" : (name.removingPercentEncoding ?? name),
                site: parsedURL.host ?? "Web",
                webpageURL: parsedURL.absoluteString,
                formats: [MediaFormat(
                    id: "direct-\(pathExt)",
                    url: parsedURL.absoluteString,
                    ext: pathExt,
                    proto: .http,
                    vcodec: isAudio ? "none" : (pathExt == "webm" ? "vp9" : "avc1"),
                    acodec: pathExt == "webm" || pathExt == "opus" ? "opus" : "mp4a"
                )]
            )
        }

        // Dedicated site extractors
        for ext in extractors where ext.matches(url: parsedURL) {
            do {
                let info = try await ext.extract(url: parsedURL, client: client)
                if !info.formats.isEmpty || !info.entries.isEmpty || info.isDRM {
                    return info
                }
            } catch let e as ExtractorError {
                throw e
            } catch {
                if ExtractorUtils.mustStop(error) { throw error }
                // Fall back to generic HTML/manifest extractor if site-specific API changed
                if let fallback = try await ExtractorUtils.optionalRequest({ try await GenericExtractor.extract(url: parsedURL, client: client) }),
                   !fallback.formats.isEmpty {
                    return fallback
                }
                throw error
            }
        }

        return try await GenericExtractor.extract(url: parsedURL, client: client)
    }
}

public enum GenericExtractor {
    public static func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (data, resp) = try await client.fetchData(url: url.absoluteString)
        let finalURL = resp.url ?? url
        let ctype = (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        // Direct binary media Content-Type without file extension
        if ctype.hasPrefix("video/") || ctype.hasPrefix("audio/") {
            let isAudio = ctype.hasPrefix("audio/")
            let ext = isAudio ? "m4a" : (ctype.contains("webm") ? "webm" : "mp4")
            return MediaInfo(
                id: finalURL.lastPathComponent.isEmpty ? "media" : finalURL.lastPathComponent,
                title: finalURL.lastPathComponent.isEmpty ? (finalURL.host ?? "Media") : finalURL.lastPathComponent,
                site: finalURL.host ?? "Web",
                webpageURL: finalURL.absoluteString,
                formats: [MediaFormat(id: "direct", url: finalURL.absoluteString, ext: ext, proto: .http, vcodec: isAudio ? "none" : "avc1", acodec: "mp4a", filesize: Int64(data.count))]
            )
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let title = ExtractorUtils.pageTitle(in: html) ?? finalURL.lastPathComponent
        let thumb = ExtractorUtils.metaContent("og:image", in: html) ?? ExtractorUtils.metaContent("twitter:image", in: html)
        let author = ExtractorUtils.metaContent("author", in: html) ?? ExtractorUtils.metaContent("og:site_name", in: html)
        let headers = ["Referer": finalURL.absoluteString]

        // Check embedded YouTube / Vimeo iframes first
        if let ytEmbed = ExtractorUtils.firstMatch("(?:youtube\\.com/embed/|youtube-nocookie\\.com/embed/)([A-Za-z0-9_-]{11})", in: html) {
            return try await YouTubeExtractor().extract(url: URL(string: "https://www.youtube.com/watch?v=\(ytEmbed)")!, client: client)
        }

        var formats: [MediaFormat] = []
        var seenURLs = Set<String>()

        func addCandidate(_ raw: String) async throws {
            let clean = ExtractorUtils.unescapeJSString(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !clean.hasPrefix("blob:") else { return }
            guard let resolved = URL(string: clean, relativeTo: finalURL)?.absoluteURL.absoluteString else { return }
            guard seenURLs.insert(resolved).inserted else { return }
            let low = resolved.lowercased()
            if low.contains(".m3u8") {
                if let hls = try await ExtractorUtils.optionalRequest({ try await HLSEngine.extractFormats(client: client, playlistURL: resolved, headers: headers, idPrefix: "hls-\(formats.count)") }) {
                    formats.append(contentsOf: hls)
                }
            } else if low.contains(".mpd") {
                if let (dash, _, _) = try await ExtractorUtils.optionalRequest({ try await DASHEngine.extractFormats(client: client, mpdURL: resolved, headers: headers, idPrefix: "dash-\(formats.count)") }) {
                    formats.append(contentsOf: dash)
                }
            } else {
                let isAudio = low.contains(".mp3") || low.contains(".m4a") || low.contains(".opus") || low.contains(".wav")
                let ext = low.contains(".webm") ? "webm" : (low.contains(".mp3") ? "mp3" : (isAudio ? "m4a" : "mp4"))
                formats.append(MediaFormat(
                    id: "web-\(formats.count)",
                    url: resolved,
                    ext: ext,
                    proto: .http,
                    vcodec: isAudio ? "none" : "avc1",
                    acodec: "mp4a",
                    headers: headers
                ))
            }
        }

        // 1. OpenGraph & Twitter media meta tags
        for metaName in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream", "og:audio:secure_url", "og:audio"] {
            if let v = ExtractorUtils.metaContent(metaName, in: html),
               (v.contains(".mp4") || v.contains(".m3u8") || v.contains(".webm") || v.contains(".mp3") || v.contains(".m4a") || metaName.contains("stream")) {
                try await addCandidate(v)
            }
        }

        // 2. JSON-LD VideoObject / AudioObject contentUrl & embedUrl
        for ldJSON in ExtractorUtils.allMatches("<script[^>]+type=[\"']application/ld\\+json[\"'][^>]*>([\\s\\S]*?)</script>", in: html, options: [.caseInsensitive]) {
            if let d = ldJSON.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) {
                for u in collectJSONLDMediaURLs(obj) {
                    try await addCandidate(u)
                }
            }
        }

        // 3. HTML5 <video>, <audio>, <source src="...">
        for src in ExtractorUtils.allMatches("<(?:video|audio|source)[^>]+src=[\"']([^\"']+)[\"']", in: html, options: [.caseInsensitive]) {
            try await addCandidate(src)
        }

        // 4. Inline HLS / MP4 URLs in page scripts
        for m3u8 in ExtractorUtils.allMatches("(https?:\\\\?/\\\\?/[^\"'\\s<>]+\\.m3u8(?:\\?[^\"'\\s<>]*)?)", in: html) {
            try await addCandidate(m3u8)
        }
        if formats.isEmpty {
            for mp4 in ExtractorUtils.allMatches("(https?:\\\\?/\\\\?/[^\"'\\s<>]+\\.(?:mp4|m4a|webm)(?:\\?[^\"'\\s<>]*)?)", in: html) {
                try await addCandidate(mp4)
            }
        }

        guard !formats.isEmpty else {
            throw ExtractorError.notFound("No downloadable media found at \(finalURL.host ?? finalURL.absoluteString). Open it in uBit's Browser (⌘B) and play the video to capture its stream.")
        }

        return MediaInfo(
            id: String(abs(finalURL.absoluteString.hashValue)),
            title: title,
            site: finalURL.host?.replacingOccurrences(of: "www.", with: "") ?? "Web",
            webpageURL: finalURL.absoluteString,
            author: author,
            thumbnail: thumb,
            isLive: formats.contains(where: \.isLive),
            formats: formats
        )
    }

    private static func collectJSONLDMediaURLs(_ node: Any) -> [String] {
        var out: [String] = []
        if let dict = node as? [String: Any] {
            for k in ["contentUrl", "streamUrl"] {
                if let u = dict[k] as? String { out.append(u) }
            }
            for (_, v) in dict { out.append(contentsOf: collectJSONLDMediaURLs(v)) }
        } else if let arr = node as? [Any] {
            for item in arr { out.append(contentsOf: collectJSONLDMediaURLs(item)) }
        }
        return out
    }
}
