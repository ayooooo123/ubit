import Foundation

// MARK: - Bluesky (ATProto XRPC)

public struct BlueskyExtractor: SiteExtractor {
    public var name: String { "Bluesky" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["bsky.app"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let handle = ExtractorUtils.firstMatch("/profile/([^/]+)/post/", in: url.path),
              let rkey = ExtractorUtils.firstMatch("/post/([A-Za-z0-9]+)", in: url.path) else {
            throw ExtractorError.notFound("Not a Bluesky post URL.")
        }
        let atURI = "at://\(handle)/app.bsky.feed.post/\(rkey)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let api = "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?depth=0&parentHeight=0&uri=\(atURI)"
        guard let root = try await client.fetchJSON(url: api, includeCookies: false) as? [String: Any],
              let post = ((root["thread"] as? [String: Any])?["post"] as? [String: Any]) else {
            throw ExtractorError.notFound("Bluesky post unavailable.")
        }
        let record = (post["record"] as? [String: Any]) ?? [:]
        let text = ((record["text"] as? String) ?? "Bluesky \(rkey)").trimmingCharacters(in: .whitespacesAndNewlines)
        let author = ((post["author"] as? [String: Any])?["handle"] as? String) ?? handle
        let embed = (post["embed"] as? [String: Any]) ?? [:]
        let media = (embed["media"] as? [String: Any]) ?? embed

        guard let playlist = media["playlist"] as? String else {
            throw ExtractorError.notFound("This Bluesky post has no video.")
        }
        let fmts = try await HLSEngine.extractFormats(client: client, playlistURL: playlist)
        return MediaInfo(
            id: rkey,
            title: text.isEmpty ? "Bluesky \(rkey)" : String(text.prefix(100)),
            site: "Bluesky",
            webpageURL: url.absoluteString,
            author: author,
            thumbnail: media["thumbnail"] as? String,
            formats: fmts
        )
    }
}

// MARK: - TikTok

public struct TikTokExtractor: SiteExtractor {
    public var name: String { "TikTok" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["tiktok.com", "vm.tiktok.com", "vt.tiktok.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, finalURL) = try await client.fetchText(url: url.absoluteString)
        let vidID = ExtractorUtils.firstMatch("/video/(\\d+)", in: finalURL.path) ?? String(abs(finalURL.path.hashValue))

        if let rehyd = ExtractorUtils.extractJSONAfter("__UNIVERSAL_DATA_FOR_REHYDRATION__ =", in: html) as? [String: Any]
            ?? (ExtractorUtils.firstMatch("<script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\"[^>]*>([\\s\\S]*?)</script>", in: html).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           let defScope = rehyd["__DEFAULT_SCOPE__"] as? [String: Any],
           let detail = (defScope["webapp.video-detail"] as? [String: Any])?["itemInfo"] as? [String: Any],
           let item = detail["itemStruct"] as? [String: Any],
           let video = item["video"] as? [String: Any] {
            var formats: [MediaFormat] = []
            let headers = ["Referer": "https://www.tiktok.com/"]
            for key in ["playAddr", "downloadAddr"] {
                if let u = video[key] as? String, !u.isEmpty {
                    formats.append(MediaFormat(id: key, url: u, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", width: video["width"] as? Int, height: video["height"] as? Int, headers: headers))
                }
            }
            if !formats.isEmpty {
                let desc = (item["desc"] as? String) ?? "TikTok \(vidID)"
                let author = ((item["author"] as? [String: Any])?["uniqueId"] as? String)
                return MediaInfo(id: vidID, title: desc.isEmpty ? "TikTok \(vidID)" : desc, site: "TikTok", webpageURL: finalURL.absoluteString, author: author, duration: (video["duration"] as? Int).map(Double.init), thumbnail: video["cover"] as? String, formats: formats)
            }
        }
        return try await GenericExtractor.extract(url: finalURL, client: client)
    }
}

// MARK: - Instagram & Threads & Facebook

public struct InstagramExtractor: SiteExtractor {
    public var name: String { "Instagram" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["instagram.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let shortcode = ExtractorUtils.firstMatch("/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)", in: url.path) else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        let embedURL = "https://www.instagram.com/p/\(shortcode)/embed/captioned/"
        let (html, _) = try await client.fetchText(url: embedURL)
        var formats: [MediaFormat] = []
        for raw in ExtractorUtils.allMatches("\"video_url\"\\s*:\\s*\"([^\"]+)\"", in: html) {
            let clean = ExtractorUtils.unescapeJSString(raw)
            formats.append(MediaFormat(id: "ig-\(formats.count)", url: clean, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a"))
        }
        if formats.isEmpty {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        let title = ExtractorUtils.pageTitle(in: html) ?? "Instagram \(shortcode)"
        let thumb = ExtractorUtils.metaContent("og:image", in: html)
        return MediaInfo(id: shortcode, title: title, site: "Instagram", webpageURL: url.absoluteString, thumbnail: thumb, formats: formats)
    }
}

public struct FacebookExtractor: SiteExtractor {
    public var name: String { "Facebook" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["facebook.com", "fb.watch"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, finalURL) = try await client.fetchText(url: url.absoluteString, headers: [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Sec-Fetch-Mode": "navigate",
        ])
        var formats: [MediaFormat] = []
        for (key, label, h) in [
            ("browser_native_hd_url", "HD", 720),
            ("playable_url_quality_hd", "HD", 720),
            ("browser_native_sd_url", "SD", 480),
            ("playable_url", "SD", 480),
        ] {
            if let m = ExtractorUtils.firstMatch("\"\(key)\"\\s*:\\s*\"([^\"]+)\"", in: html) {
                let u = ExtractorUtils.unescapeJSString(m)
                if u.hasPrefix("http") && !formats.contains(where: { $0.url == u }) {
                    formats.append(MediaFormat(id: label.lowercased(), url: u, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", height: h, qualityLabel: label))
                }
            }
        }
        if formats.isEmpty { return try await GenericExtractor.extract(url: finalURL, client: client) }
        let title = ExtractorUtils.pageTitle(in: html) ?? "Facebook Video"
        return MediaInfo(id: String(abs(finalURL.path.hashValue)), title: title, site: "Facebook", webpageURL: finalURL.absoluteString, thumbnail: ExtractorUtils.metaContent("og:image", in: html), formats: formats)
    }
}

public struct ThreadsExtractor: SiteExtractor {
    public var name: String { "Threads" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["threads.net", "threads.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "Threads"
        return info
    }
}

// MARK: - Bandcamp & Mixcloud

public struct BandcampExtractor: SiteExtractor {
    public var name: String { "Bandcamp" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["bandcamp.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, finalURL) = try await client.fetchText(url: url.absoluteString)
        guard let attr = ExtractorUtils.firstMatch("data-tralbum=[\"']([^\"']+)[\"']", in: html) else {
            return try await GenericExtractor.extract(url: finalURL, client: client)
        }
        let decoded = SponsorAndSubtitles.decodeHTMLEntities(attr)
        guard let data = decoded.data(using: .utf8),
              let tralbum = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorError.notFound("Could not read Bandcamp album data.")
        }
        let artist = tralbum["artist"] as? String
        let current = (tralbum["current"] as? [String: Any]) ?? [:]
        let itemType = (tralbum["item_type"] as? String) ?? "track"
        let tracks = (tralbum["trackinfo"] as? [[String: Any]]) ?? []
        let artID = tralbum["art_id"] as? Int
        let thumb = artID.map { "https://f4.bcbits.com/img/a\($0)_10.jpg" }

        if itemType == "album" && tracks.count > 1 {
            let baseOrigin = "\(finalURL.scheme ?? "https")://\(finalURL.host ?? "")"
            let entries = tracks.compactMap { t -> PlaylistEntry? in
                guard let link = t["title_link"] as? String else { return nil }
                return PlaylistEntry(
                    id: String((t["id"] as? Int) ?? 0),
                    title: (t["title"] as? String) ?? "Track",
                    url: link.hasPrefix("http") ? link : (baseOrigin + link),
                    duration: t["duration"] as? Double,
                    thumbnail: thumb,
                    author: artist
                )
            }
            return MediaInfo(id: String((current["id"] as? Int) ?? 0), title: (current["title"] as? String) ?? "Bandcamp Album", site: "Bandcamp", webpageURL: finalURL.absoluteString, author: artist, thumbnail: thumb, entries: entries)
        }

        guard let tr = tracks.first, let fileDict = tr["file"] as? [String: Any],
              let mp3URL = (fileDict["mp3-128"] as? String) ?? (fileDict.values.first as? String) else {
            throw ExtractorError.notFound("This Bandcamp track has no free stream.")
        }
        let fullURL = mp3URL.hasPrefix("//") ? "https:" + mp3URL : mp3URL
        return MediaInfo(
            id: String((tr["id"] as? Int) ?? 0),
            title: (tr["title"] as? String) ?? (current["title"] as? String) ?? "Bandcamp Track",
            site: "Bandcamp",
            webpageURL: finalURL.absoluteString,
            author: artist,
            duration: tr["duration"] as? Double,
            thumbnail: thumb,
            formats: [MediaFormat(id: "mp3-128", url: fullURL, ext: "mp3", proto: .http, vcodec: "none", acodec: "mp3", bitrate: 128_000, qualityLabel: "Audio MP3")]
        )
    }
}

public struct MixcloudExtractor: SiteExtractor {
    public var name: String { "Mixcloud" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["mixcloud.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "Mixcloud"
        return info
    }
}

// MARK: - Dailymotion, Rumble, Odysee, PeerTube, Internet Archive, Streamable, Loom, TED

public struct DailymotionExtractor: SiteExtractor {
    public var name: String { "Dailymotion" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["dailymotion.com", "dai.ly"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let vidID = (url.host == "dai.ly")
            ? (url.path.split(separator: "/").first.map(String.init) ?? "")
            : (ExtractorUtils.firstMatch("/video/([a-zA-Z0-9]+)", in: url.path) ?? "")
        guard !vidID.isEmpty else { throw ExtractorError.notFound("No Dailymotion video ID found.") }

        let metaURL = "https://www.dailymotion.com/player/metadata/video/\(vidID)"
        guard let meta = try await client.fetchJSON(url: metaURL) as? [String: Any] else {
            throw ExtractorError.notFound("Dailymotion metadata unavailable.")
        }
        var formats: [MediaFormat] = []
        if let quals = meta["qualities"] as? [String: Any],
           let autoArr = quals["auto"] as? [[String: Any]],
           let m3u8 = autoArr.first?["url"] as? String {
            formats = try await HLSEngine.extractFormats(client: client, playlistURL: m3u8)
        }
        guard !formats.isEmpty else { throw ExtractorError.notFound("No playable Dailymotion stream.") }
        let owner = (meta["owner"] as? [String: Any])?["screenname"] as? String
        let thumbs = meta["thumbnails"] as? [String: Any]
        let thumb = (thumbs?["1080"] as? String) ?? (thumbs?["720"] as? String) ?? (thumbs?["480"] as? String)
        return MediaInfo(id: vidID, title: (meta["title"] as? String) ?? vidID, site: "Dailymotion", webpageURL: url.absoluteString, author: owner, duration: meta["duration"] as? Double, thumbnail: thumb, isLive: (meta["is_live"] as? Bool) == true, formats: formats)
    }
}

public struct RumbleExtractor: SiteExtractor {
    public var name: String { "Rumble" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["rumble.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, finalURL) = try await client.fetchText(url: url.absoluteString)
        let embedID = ExtractorUtils.firstMatch("/embed/(v[a-z0-9]+)", in: html)
            ?? ExtractorUtils.firstMatch("\"video\"\\s*:\\s*\"(v[a-z0-9]+)\"", in: html)
        guard let vid = embedID else { return try await GenericExtractor.extract(url: finalURL, client: client) }

        guard let obj = try await client.fetchJSON(url: "https://rumble.com/embedJS/u3/?request=video&ver=2&v=\(vid)") as? [String: Any] else {
            throw ExtractorError.notFound("Rumble embed API failed.")
        }
        var formats: [MediaFormat] = []
        if let ua = obj["ua"] as? [String: Any] {
            for (kind, entriesAny) in ua {
                if let kindDict = entriesAny as? [String: Any] {
                    for (resKey, infoAny) in kindDict {
                        guard let item = infoAny as? [String: Any], let surl = item["url"] as? String else { continue }
                        let isHLS = kind == "hls" || surl.contains(".m3u8")
                        if isHLS, let hls = try? await HLSEngine.extractFormats(client: client, playlistURL: surl) {
                            formats.append(contentsOf: hls)
                        } else {
                            formats.append(MediaFormat(id: "\(kind)-\(resKey)", url: surl, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", height: Int(resKey)))
                        }
                    }
                }
            }
        }
        return MediaInfo(id: vid, title: (obj["title"] as? String) ?? vid, site: "Rumble", webpageURL: finalURL.absoluteString, author: (obj["author"] as? [String: Any])?["name"] as? String, duration: obj["duration"] as? Double, thumbnail: obj["i"] as? String, formats: formats)
    }
}

public struct OdyseeExtractor: SiteExtractor {
    public var name: String { "Odysee" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["odysee.com", "lbry.tv"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let lbryURI = "lbry://" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: ":", with: "#")
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "resolve", "params": ["urls": [lbryURI]]]
        let resp = try await client.fetchJSON(
            url: "https://api.na-backend.odysee.com/api/v1/proxy?m=resolve",
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: rpc)
        ) as? [String: Any]
        guard let resMap = resp?["result"] as? [String: Any],
              let claim = resMap.values.first as? [String: Any],
              let claimID = claim["claim_id"] as? String,
              let name = claim["name"] as? String else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        let val = (claim["value"] as? [String: Any]) ?? [:]
        let title = (val["title"] as? String) ?? name
        let thumb = ((val["thumbnail"] as? [String: Any])?["url"] as? String)
        let dur = ((val["video"] as? [String: Any])?["duration"] as? Double)
        let streamURL = "https://player.odycdn.com/api/v3/streams/free/\(name)/\(claimID)/stream.mp4"
        let hlsURL = "https://player.odycdn.com/v6/streams/\(claimID)/master.m3u8"
        var formats = (try? await HLSEngine.extractFormats(client: client, playlistURL: hlsURL)) ?? []
        formats.append(MediaFormat(id: "direct-mp4", url: streamURL, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a"))
        return MediaInfo(id: claimID, title: title, site: "Odysee", webpageURL: url.absoluteString, duration: dur, thumbnail: thumb, formats: formats)
    }
}

public struct PeerTubeExtractor: SiteExtractor {
    public var name: String { "PeerTube" }
    public init() {}
    public func matches(url: URL) -> Bool {
        url.path.hasPrefix("/videos/watch/") || url.path.hasPrefix("/w/")
    }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let uuid = url.path.split(separator: "/").last.map(String.init),
              let host = url.host else {
            throw ExtractorError.notFound("Invalid PeerTube URL.")
        }
        let api = "\(url.scheme ?? "https")://\(host)/api/v1/videos/\(uuid)"
        guard let obj = try? await client.fetchJSON(url: api) as? [String: Any] else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        var formats: [MediaFormat] = []
        for f in (obj["files"] as? [[String: Any]]) ?? [] {
            guard let furl = f["fileUrl"] as? String else { continue }
            let h = (f["resolution"] as? [String: Any])?["id"] as? Int
            formats.append(MediaFormat(id: "pt-\(h ?? formats.count)", url: furl, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", height: h, filesize: f["size"] as? Int64))
        }
        for sp in (obj["streamingPlaylists"] as? [[String: Any]]) ?? [] {
            if let m3u8 = sp["playlistUrl"] as? String,
               let hls = try? await HLSEngine.extractFormats(client: client, playlistURL: m3u8) {
                formats.append(contentsOf: hls)
            }
        }
        guard !formats.isEmpty else { return try await GenericExtractor.extract(url: url, client: client) }
        return MediaInfo(id: uuid, title: (obj["name"] as? String) ?? uuid, site: "PeerTube", webpageURL: url.absoluteString, author: (obj["account"] as? [String: Any])?["displayName"] as? String, duration: obj["duration"] as? Double, formats: formats)
    }
}

public struct InternetArchiveExtractor: SiteExtractor {
    public var name: String { "Internet Archive" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["archive.org"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let itemID = ExtractorUtils.firstMatch("/(?:details|download|embed)/([^/?#]+)", in: url.path) else {
            throw ExtractorError.notFound("Not an Internet Archive item URL.")
        }
        guard let metaRoot = try await client.fetchJSON(url: "https://archive.org/metadata/\(itemID)") as? [String: Any],
              let files = metaRoot["files"] as? [[String: Any]] else {
            throw ExtractorError.notFound("Internet Archive metadata unavailable for \(itemID).")
        }
        let md = (metaRoot["metadata"] as? [String: Any]) ?? [:]
        let title = (md["title"] as? String) ?? itemID
        let creator = (md["creator"] as? String)
        var formats: [MediaFormat] = []
        for f in files {
            guard let fname = f["name"] as? String else { continue }
            let ext = (fname as NSString).pathExtension.lowercased()
            guard ["mp4", "m4a", "webm", "mp3", "flac", "wav", "mkv", "ogv"].contains(ext) else { continue }
            let encoded = fname.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            let durl = "https://archive.org/download/\(itemID)/\(encoded)"
            let isAudio = ["m4a", "mp3", "flac", "wav"].contains(ext)
            formats.append(MediaFormat(
                id: fname,
                url: durl,
                ext: ext,
                proto: .http,
                vcodec: isAudio ? "none" : "avc1",
                acodec: "mp4a",
                width: (f["width"] as? String).flatMap(Int.init),
                height: (f["height"] as? String).flatMap(Int.init),
                filesize: (f["size"] as? String).flatMap(Int64.init),
                qualityLabel: fname
            ))
        }
        guard !formats.isEmpty else { throw ExtractorError.notFound("No media files in Internet Archive item \(itemID).") }
        return MediaInfo(id: itemID, title: title, site: "Internet Archive", webpageURL: url.absoluteString, author: creator, thumbnail: "https://archive.org/services/img/\(itemID)", formats: formats)
    }
}

public struct StreamableExtractor: SiteExtractor {
    public var name: String { "Streamable" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["streamable.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let code = url.path.split(separator: "/").last.map(String.init), !code.isEmpty else {
            throw ExtractorError.notFound("Invalid Streamable link.")
        }
        guard let obj = try await client.fetchJSON(url: "https://api.streamable.com/videos/\(code)") as? [String: Any],
              let files = obj["files"] as? [String: Any] else {
            throw ExtractorError.notFound("Streamable video unavailable.")
        }
        var formats: [MediaFormat] = []
        for (key, val) in files {
            guard let f = val as? [String: Any], var furl = f["url"] as? String else { continue }
            if furl.hasPrefix("//") { furl = "https:" + furl }
            formats.append(MediaFormat(id: key, url: furl, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", width: f["width"] as? Int, height: f["height"] as? Int, bitrate: f["bitrate"] as? Int64, filesize: f["size"] as? Int64))
        }
        var thumb = obj["thumbnail_url"] as? String
        if thumb?.hasPrefix("//") == true { thumb = "https:" + thumb! }
        return MediaInfo(id: code, title: (obj["title"] as? String) ?? "Streamable \(code)", site: "Streamable", webpageURL: url.absoluteString, duration: obj["duration"] as? Double, thumbnail: thumb, formats: formats)
    }
}

public struct LoomExtractor: SiteExtractor {
    public var name: String { "Loom" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["loom.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let vidID = ExtractorUtils.firstMatch("/(?:share|embed)/([0-9a-f]{32})", in: url.path) else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        let gql: [String: Any] = [
            "operationName": "FetchVideoTranscript",
            "variables": ["videoId": vidID],
            "query": "query FetchVideoTranscript($videoId: ID!) { fetchVideoTranscript(videoId: $videoId) { ... on VideoTranscriptDetails { captions_source_url } } }"
        ]
        _ = gql
        let streamGQL: [String: Any] = [
            "operationName": "GetVideoTranscodedUrl",
            "variables": ["videoId": vidID, "forceOriginal": false],
            "query": "query GetVideoTranscodedUrl($videoId: ID!, $forceOriginal: Boolean) { fetchTranscodedUrl(videoId: $videoId, forceOriginal: $forceOriginal) { url } }"
        ]
        let resp = try? await client.fetchJSON(
            url: "https://www.loom.com/graphql",
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: streamGQL)
        ) as? [String: Any]
        if let surl = ((resp?["data"] as? [String: Any])?["fetchTranscodedUrl"] as? [String: Any])?["url"] as? String {
            let (html, _) = (try? await client.fetchText(url: url.absoluteString)) ?? ("", url)
            let title = ExtractorUtils.pageTitle(in: html) ?? "Loom \(vidID.prefix(8))"
            let fmts = surl.contains(".m3u8")
                ? (try await HLSEngine.extractFormats(client: client, playlistURL: surl))
                : [MediaFormat(id: "mp4", url: surl, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a")]
            return MediaInfo(id: vidID, title: title, site: "Loom", webpageURL: url.absoluteString, thumbnail: ExtractorUtils.metaContent("og:image", in: html), formats: fmts)
        }
        return try await GenericExtractor.extract(url: url, client: client)
    }
}

public struct TEDExtractor: SiteExtractor {
    public var name: String { "TED" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["ted.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, finalURL) = try await client.fetchText(url: url.absoluteString)
        var formats: [MediaFormat] = []
        for mp4 in Set(ExtractorUtils.allMatches("(https://py\\.tedcdn\\.com/[^\"'\\s]+\\.mp4)", in: html)) {
            let q = ExtractorUtils.firstMatch("-(\\d+k)\\.mp4", in: mp4) ?? "mp4"
            formats.append(MediaFormat(id: q, url: mp4, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", qualityLabel: q))
        }
        for m3u8 in Set(ExtractorUtils.allMatches("(https://hls\\.ted\\.com/[^\"'\\s]+\\.m3u8[^\"'\\s]*)", in: html)) {
            if let hls = try? await HLSEngine.extractFormats(client: client, playlistURL: ExtractorUtils.unescapeJSString(m3u8)) {
                formats.append(contentsOf: hls)
            }
        }
        if formats.isEmpty { return try await GenericExtractor.extract(url: finalURL, client: client) }
        return MediaInfo(id: finalURL.lastPathComponent, title: ExtractorUtils.pageTitle(in: html) ?? "TED Talk", site: "TED", webpageURL: finalURL.absoluteString, thumbnail: ExtractorUtils.metaContent("og:image", in: html), formats: formats)
    }
}

// MARK: - Imgur, Tumblr, Pinterest, VK, Douyin, Kuaishou, Weibo, Xiaohongshu

public struct ImgurExtractor: SiteExtractor {
    public var name: String { "Imgur" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["imgur.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        if let id = ExtractorUtils.firstMatch("/(?:gallery/|a/|t/[^/]+/)?(?:[A-Za-z0-9-]+-)?([A-Za-z0-9]{5,8})(?:\\.[a-z0-9]+)?$", in: url.path) {
            let directMP4 = "https://i.imgur.com/\(id).mp4"
            if let (_, resp) = try? await client.fetchData(url: directMP4, method: "HEAD"), resp.statusCode == 200 {
                return MediaInfo(id: id, title: "Imgur \(id)", site: "Imgur", webpageURL: url.absoluteString, formats: [MediaFormat(id: "mp4", url: directMP4, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a")])
            }
        }
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "Imgur"
        return info
    }
}

public struct TumblrExtractor: SiteExtractor {
    public var name: String { "Tumblr" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["tumblr.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "Tumblr"
        return info
    }
}

public struct PinterestExtractor: SiteExtractor {
    public var name: String { "Pinterest" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["pinterest.com", "pin.it"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, finalURL) = try await client.fetchText(url: url.absoluteString)
        var formats: [MediaFormat] = []
        for v in Set(ExtractorUtils.allMatches("(https://v1\\.pinimg\\.com/videos/[^\"'\\s]+\\.(?:mp4|m3u8))", in: html)) {
            if v.hasSuffix(".m3u8"), let hls = try? await HLSEngine.extractFormats(client: client, playlistURL: v) {
                formats.append(contentsOf: hls)
            } else {
                formats.append(MediaFormat(id: "mp4-\(formats.count)", url: v, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a"))
            }
        }
        if formats.isEmpty { return try await GenericExtractor.extract(url: finalURL, client: client) }
        return MediaInfo(id: finalURL.lastPathComponent, title: ExtractorUtils.pageTitle(in: html) ?? "Pinterest Video", site: "Pinterest", webpageURL: finalURL.absoluteString, formats: formats)
    }
}

public struct VKExtractor: SiteExtractor {
    public var name: String { "VK" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["vk.com", "vkvideo.ru"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "VK"
        return info
    }
}

public struct DouyinExtractor: SiteExtractor {
    public var name: String { "Douyin" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["douyin.com", "iesdouyin.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "Douyin"
        return info
    }
}

public struct KuaishouExtractor: SiteExtractor {
    public var name: String { "Kuaishou" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["kuaishou.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "Kuaishou"
        return info
    }
}

public struct WeiboExtractor: SiteExtractor {
    public var name: String { "Weibo" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["weibo.com", "weibo.cn"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        var info = try await GenericExtractor.extract(url: url, client: client)
        info.site = "Weibo"
        return info
    }
}

public struct XiaohongshuExtractor: SiteExtractor {
    public var name: String { "Xiaohongshu" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["xiaohongshu.com", "xhslink.com"]) }

    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (html, finalURL) = try await client.fetchText(url: url.absoluteString, headers: [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
        ])
        var formats: [MediaFormat] = []
        for raw in Set(ExtractorUtils.allMatches("(https?:\\\\?/\\\\?/sns-video-[^\"'\\s<>]+\\.mp4(?:\\?[^\"'\\s<>]*)?)", in: html)) {
            let clean = ExtractorUtils.unescapeJSString(raw)
            formats.append(MediaFormat(id: "xhs-\(formats.count)", url: clean, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", headers: ["Referer": "https://www.xiaohongshu.com/"]))
        }
        if formats.isEmpty {
            if let ogVideo = ExtractorUtils.metaContent("og:video", in: html), ogVideo.hasPrefix("http") {
                formats.append(MediaFormat(id: "xhs-og", url: ogVideo, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a", headers: ["Referer": "https://www.xiaohongshu.com/"]))
            }
        }
        guard !formats.isEmpty else {
            throw ExtractorError.loginRequired("Xiaohongshu")
        }
        let title = ExtractorUtils.pageTitle(in: html) ?? "Xiaohongshu Video"
        return MediaInfo(id: finalURL.lastPathComponent, title: title, site: "Xiaohongshu", webpageURL: finalURL.absoluteString, thumbnail: ExtractorUtils.metaContent("og:image", in: html), formats: formats)
    }
}

// MARK: - Bonus Extractors Beyond Downbit: GitHub Assets, Mastodon/Fediverse, Coub, 9GAG

public struct GitHubMediaExtractor: SiteExtractor {
    public var name: String { "GitHub" }
    public init() {}
    public func matches(url: URL) -> Bool {
        ExtractorUtils.hostMatches(url, domains: ["github.com"]) && (url.path.contains("/assets/") || url.path.contains("/user-attachments/"))
    }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        let (_, resp) = try await client.fetchData(url: url.absoluteString, method: "HEAD")
        let finalU = resp.url ?? url
        return MediaInfo(
            id: finalU.lastPathComponent,
            title: finalU.deletingPathExtension().lastPathComponent,
            site: "GitHub",
            webpageURL: url.absoluteString,
            formats: [MediaFormat(id: "mp4", url: finalU.absoluteString, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a")]
        )
    }
}

public struct MastodonExtractor: SiteExtractor {
    public var name: String { "Mastodon" }
    public init() {}
    public func matches(url: URL) -> Bool {
        ExtractorUtils.firstMatch("^/@[^/]+/(\\d+)$", in: url.path) != nil
    }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let statusID = ExtractorUtils.firstMatch("^/@[^/]+/(\\d+)$", in: url.path),
              let host = url.host else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        guard let st = try? await client.fetchJSON(url: "\(url.scheme ?? "https")://\(host)/api/v1/statuses/\(statusID)") as? [String: Any],
              let atts = st["media_attachments"] as? [[String: Any]], !atts.isEmpty else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        var formats: [MediaFormat] = []
        var thumb: String?
        for (i, a) in atts.enumerated() where ["video", "gifv", "audio"].contains((a["type"] as? String) ?? "") {
            guard let u = a["url"] as? String else { continue }
            if thumb == nil { thumb = a["preview_url"] as? String }
            let isAudio = (a["type"] as? String) == "audio"
            formats.append(MediaFormat(id: "masto-\(i)", url: u, ext: isAudio ? "m4a" : "mp4", proto: .http, vcodec: isAudio ? "none" : "avc1", acodec: "mp4a"))
        }
        guard !formats.isEmpty else { return try await GenericExtractor.extract(url: url, client: client) }
        let acct = (st["account"] as? [String: Any])?["acct"] as? String
        return MediaInfo(id: statusID, title: "Mastodon \(statusID)", site: "Mastodon", webpageURL: url.absoluteString, author: acct, thumbnail: thumb, formats: formats)
    }
}

public struct CoubExtractor: SiteExtractor {
    public var name: String { "Coub" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["coub.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let cid = ExtractorUtils.firstMatch("/view/([A-Za-z0-9]+)", in: url.path),
              let obj = try? await client.fetchJSON(url: "https://coub.com/api/v2/coubs/\(cid)") as? [String: Any],
              let fv = ((obj["file_versions"] as? [String: Any])?["html5"] as? [String: Any]) else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        var formats: [MediaFormat] = []
        if let vdict = fv["video"] as? [String: Any] {
            for (k, anyV) in vdict {
                if let d = anyV as? [String: Any], let u = d["url"] as? String {
                    formats.append(MediaFormat(id: "v-\(k)", url: u, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "none"))
                }
            }
        }
        if let adict = fv["audio"] as? [String: Any] {
            for (k, anyA) in adict {
                if let d = anyA as? [String: Any], let u = d["url"] as? String {
                    formats.append(MediaFormat(id: "a-\(k)", url: u, ext: "mp3", proto: .http, vcodec: "none", acodec: "mp3"))
                }
            }
        }
        return MediaInfo(id: cid, title: (obj["title"] as? String) ?? "Coub \(cid)", site: "Coub", webpageURL: url.absoluteString, formats: formats)
    }
}

public struct NineGagExtractor: SiteExtractor {
    public var name: String { "9GAG" }
    public init() {}
    public func matches(url: URL) -> Bool { ExtractorUtils.hostMatches(url, domains: ["9gag.com"]) }
    public func extract(url: URL, client: HTTPClient) async throws -> MediaInfo {
        guard let pid = ExtractorUtils.firstMatch("/gag/([A-Za-z0-9]+)", in: url.path) else {
            return try await GenericExtractor.extract(url: url, client: client)
        }
        let mp4 = "https://img-9gag-fun.9cache.com/photo/\(pid)_460sv.mp4"
        return MediaInfo(id: pid, title: "9GAG \(pid)", site: "9GAG", webpageURL: url.absoluteString, formats: [MediaFormat(id: "mp4", url: mp4, ext: "mp4", proto: .http, vcodec: "avc1", acodec: "mp4a")])
    }
}
