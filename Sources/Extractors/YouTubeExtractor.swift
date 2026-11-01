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
        let name: String
        let version: String
        let clientNameHeader: String
        let userAgent: String
        let extraFields: [String: Any]
        let supportsCookies: Bool
    }

    private static let iosProfile = YTClientProfile(
        name: "IOS",
        version: "20.03.02",
        clientNameHeader: "5",
        userAgent: "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X;)",
        extraFields: [
            "deviceMake": "Apple",
            "deviceModel": "iPhone16,2",
            "osName": "iPhone",
            "osVersion": "18.2.1.22C161",
        ],
        supportsCookies: false
    )

    private static let webProfile = YTClientProfile(
        name: "WEB",
        version: "2.20260201.01.00",
        clientNameHeader: "1",
        userAgent: HTTPClient.defaultBrowserUA,
        extraFields: [:],
        supportsCookies: true
    )

    private static let tvEmbeddedProfile = YTClientProfile(
        name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        version: "2.0",
        clientNameHeader: "85",
        userAgent: HTTPClient.defaultBrowserUA,
        extraFields: [:],
        supportsCookies: true
    )

    private func extractVideo(videoID: String, client: HTTPClient) async throws -> MediaInfo {
        // Fetch IOS (direct unthrottled 4K60/H264/AV1/AAC/Opus URLs) and WEB (captions, chapters, signed-in fallback) concurrently!
        async let iosRespTask = callPlayer(videoID: videoID, profile: Self.iosProfile, client: client, sts: nil)
        async let webRespTask = callPlayer(videoID: videoID, profile: Self.webProfile, client: client, sts: nil)

        let iosResp = try? await iosRespTask
        let webResp = try? await webRespTask

        var primaryResp = iosResp
        var status = (iosResp?["playabilityStatus"] as? [String: Any])?["status"] as? String ?? ""

        if status != "OK" || (iosResp?["streamingData"] == nil) {
            if let wr = webResp, ((wr["playabilityStatus"] as? [String: Any])?["status"] as? String) == "OK", wr["streamingData"] != nil {
                primaryResp = wr
                status = "OK"
            } else if let tvResp = try? await callPlayer(videoID: videoID, profile: Self.tvEmbeddedProfile, client: client, sts: nil),
                      ((tvResp["playabilityStatus"] as? [String: Any])?["status"] as? String) == "OK" {
                primaryResp = tvResp
                status = "OK"
            }
        }

        guard let resp = primaryResp else {
            throw ExtractorError.notFound("YouTube player request failed for \(videoID).")
        }

        if status != "OK" && resp["streamingData"] == nil {
            let reason = ((resp["playabilityStatus"] as? [String: Any])?["reason"] as? String) ?? "Unavailable"
            if reason.lowercased().contains("sign in") {
                throw ExtractorError.loginRequired("YouTube")
            }
            throw ExtractorError.notFound("YouTube: \(reason)")
        }

        let details = (resp["videoDetails"] as? [String: Any]) ?? (webResp?["videoDetails"] as? [String: Any]) ?? [:]
        let micro = ((webResp?["microformat"] ?? resp["microformat"]) as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any]

        let title = (details["title"] as? String) ?? videoID
        let author = (details["author"] as? String)
        let description = (details["shortDescription"] as? String) ?? ((micro?["description"] as? [String: Any])?["simpleText"] as? String)
        let duration = (details["lengthSeconds"] as? String).flatMap(Double.init)
        let isLive = (details["isLiveContent"] as? Bool == true) && ((details["isLive"] as? Bool == true) || duration == 0)
        let uploadDate = (micro?["publishDate"] as? String).map { String($0.prefix(10)) }
        let thumb = "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg"

        var formats: [MediaFormat] = []
        var usedProfileUA = (primaryResp as NSDictionary? === iosResp as NSDictionary?) ? Self.iosProfile.userAgent : Self.webProfile.userAgent
        if primaryResp == nil { usedProfileUA = Self.iosProfile.userAgent }

        if let sd = resp["streamingData"] as? [String: Any] {
            let rawFmts = ((sd["formats"] as? [[String: Any]]) ?? []) + ((sd["adaptiveFormats"] as? [[String: Any]]) ?? [])
            var needsPlayerJS = false
            for f in rawFmts where f["url"] == nil && (f["signatureCipher"] != nil || f["cipher"] != nil) {
                needsPlayerJS = true; break
            }

            var playerJSSolver: JSPlayerCipherSolver?
            if needsPlayerJS {
                playerJSSolver = try? await loadPlayerCipherSolver(videoID: videoID, client: client)
            }

            for f in rawFmts {
                guard let itag = f["itag"] as? Int else { continue }
                var streamURL = f["url"] as? String
                if streamURL == nil, let cipherStr = (f["signatureCipher"] as? String) ?? (f["cipher"] as? String),
                   let solver = playerJSSolver {
                    streamURL = solver.resolveCipher(cipherStr)
                }
                guard var finalStreamURL = streamURL, !finalStreamURL.isEmpty else { continue }
                if let solver = playerJSSolver {
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

                formats.append(MediaFormat(
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
                    headers: ["User-Agent": usedProfileUA],
                    initRange: initR,
                    indexRange: idxR
                ))
            }

            // Live stream or fallback HLS manifest
            if (isLive || formats.isEmpty),
               let hlsManifest = (sd["hlsManifestUrl"] as? String) ?? ((webResp?["streamingData"] as? [String: Any])?["hlsManifestUrl"] as? String) {
                if let hlsFmts = try? await HLSEngine.extractFormats(client: client, playlistURL: hlsManifest, headers: ["User-Agent": usedProfileUA], idPrefix: "hls") {
                    for var hf in hlsFmts {
                        hf.isLive = isLive
                        formats.append(hf)
                    }
                }
            }
        }

        // Subtitles from WEB response (or primary response)
        var subtitles: [SubtitleTrack] = []
        let capSource = (webResp?["captions"] != nil) ? webResp : resp
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

        return MediaInfo(
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
    }

    private func callPlayer(videoID: String, profile: YTClientProfile, client: HTTPClient, sts: Int?) async throws -> [String: Any] {
        var clientDict: [String: Any] = [
            "clientName": profile.name,
            "clientVersion": profile.version,
            "hl": "en",
            "gl": "US",
        ]
        for (k, v) in profile.extraFields { clientDict[k] = v }

        var context: [String: Any] = ["client": clientDict]
        if profile.name.contains("EMBEDDED") {
            context["thirdParty"] = ["embedUrl": "https://www.youtube.com/"]
        }
        var bodyObj: [String: Any] = [
            "videoId": videoID,
            "context": context,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let sts {
            bodyObj["playbackContext"] = ["contentPlaybackContext": ["signatureTimestamp": sts]]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj)
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "User-Agent": profile.userAgent,
            "X-YouTube-Client-Name": profile.clientNameHeader,
            "X-YouTube-Client-Version": profile.version,
            "Origin": "https://www.youtube.com",
        ]

        // Attach SAPISIDHASH Authorization header when user has signed in via uBit Browser or cookies.txt!
        if profile.supportsCookies,
           let sapisid = client.cookies.cookieValue(named: "SAPISID", forDomain: "youtube.com")
                ?? client.cookies.cookieValue(named: "__Secure-3PAPISID", forDomain: "youtube.com") {
            let ts = Int(Date().timeIntervalSince1970)
            let input = "\(ts) \(sapisid) https://www.youtube.com"
            let sha1 = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            headers["Authorization"] = "SAPISIDHASH \(ts)_\(sha1)"
            headers["X-Origin"] = "https://www.youtube.com"
        }

        let json = try await client.fetchJSON(
            url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            method: "POST",
            headers: headers,
            body: bodyData,
            includeCookies: profile.supportsCookies
        )
        return (json as? [String: Any]) ?? [:]
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
            if let nextResp = try? await callInnerTube(endpoint: "browse", payload: ["continuation": cont], client: client) {
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
            if var pl = try? await extractPlaylist(listID: uploadsList, webpageURL: url.absoluteString, client: client), !pl.entries.isEmpty {
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

    private func loadPlayerCipherSolver(videoID: String, client: HTTPClient) async throws -> JSPlayerCipherSolver? {
        let (embedHTML, _) = try await client.fetchText(url: "https://www.youtube.com/embed/\(videoID)")
        guard let jsRel = ExtractorUtils.firstMatch("\"jsUrl\":\"([^\"]+base\\.js)\"", in: embedHTML) else {
            return nil
        }
        let jsURL = jsRel.hasPrefix("http") ? jsRel : "https://www.youtube.com\(jsRel)"
        let (jsCode, _) = try await client.fetchText(url: jsURL, includeCookies: false)
        return JSPlayerCipherSolver(playerJS: jsCode)
    }
}

private final class JSPlayerCipherSolver: @unchecked Sendable {
    private let lock = NSLock()
    private let ctx: JSContext?
    private var hasSigFn = false

    init(playerJS: String) {
        let context = JSContext()
        self.ctx = context
        // Locate signature decipher function & helper object in base.js
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
        url
    }
}
