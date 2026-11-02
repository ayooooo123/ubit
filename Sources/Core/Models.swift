import Foundation

public let UBIT_VERSION = "0.3.3"
public let UBIT_BUNDLE_ID = "app.ubit.mac"

public enum StreamProtocol: String, Codable, Sendable {
    case http
    case hls
    case dash
}

public struct ByteRange: Codable, Sendable, Equatable {
    public var start: Int64
    public var end: Int64 // inclusive
    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
    public var length: Int64 { max(0, end - start + 1) }
}

public struct MediaFormat: Codable, Sendable {
    public var id: String
    public var url: String
    public var ext: String
    public var proto: StreamProtocol
    public var vcodec: String?      // e.g. "avc1.640028", "vp9", "av01", nil/"none" for audio-only
    public var acodec: String?      // e.g. "mp4a.40.2", "opus", "mp3", nil/"none" for video-only
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var bitrate: Int64?      // bits/sec
    public var filesize: Int64?     // bytes
    public var audioSampleRate: Int?
    public var qualityLabel: String?
    public var headers: [String: String]?
    public var initRange: ByteRange?
    public var indexRange: ByteRange?
    public var audioTrackURL: String? // for HLS separate audio rendition
    public var isLive: Bool

    public init(
        id: String,
        url: String,
        ext: String = "mp4",
        proto: StreamProtocol = .http,
        vcodec: String? = nil,
        acodec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        bitrate: Int64? = nil,
        filesize: Int64? = nil,
        audioSampleRate: Int? = nil,
        qualityLabel: String? = nil,
        headers: [String: String]? = nil,
        initRange: ByteRange? = nil,
        indexRange: ByteRange? = nil,
        audioTrackURL: String? = nil,
        isLive: Bool = false
    ) {
        self.id = id
        self.url = url
        self.ext = ext
        self.proto = proto
        self.vcodec = vcodec
        self.acodec = acodec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.filesize = filesize
        self.audioSampleRate = audioSampleRate
        self.qualityLabel = qualityLabel
        self.headers = headers
        self.initRange = initRange
        self.indexRange = indexRange
        self.audioTrackURL = audioTrackURL
        self.isLive = isLive
    }

    public var hasVideo: Bool {
        guard let v = vcodec?.lowercased(), !v.isEmpty, v != "none" else { return (height ?? 0) > 0 }
        return true
    }

    public var hasAudio: Bool {
        if audioTrackURL != nil { return true }
        guard let a = acodec?.lowercased(), !a.isEmpty, a != "none" else {
            return !hasVideo
        }
        return true
    }

    public var isH264: Bool {
        guard let v = vcodec?.lowercased() else { return ext == "mp4" && hasVideo }
        return v.contains("avc") || v.contains("h264")
    }

    /// True for ISO-BMFF MP4 (H.264, HEVC, AV1) and HLS streams that mux natively without FFmpeg on macOS.
    public var isNativeMP4: Bool {
        ext == "mp4" || proto == .hls
    }

    public var isAAC: Bool {
        guard let a = acodec?.lowercased() else { return (ext == "m4a" || ext == "mp4") && hasAudio }
        return a.contains("mp4a") || a.contains("aac")
    }

    public var displayQuality: String {
        if let q = qualityLabel, !q.isEmpty { return q }
        if let h = height, h > 0 {
            if let f = fps, f > 31 { return "\(h)p\(Int(f.rounded()))" }
            return "\(h)p"
        }
        if hasAudio && !hasVideo {
            if let br = bitrate, br > 0 { return "Audio \(br / 1000)k" }
            return "Audio"
        }
        return id
    }

    public var shortCodec: String {
        var parts: [String] = []
        if let v = vcodec, v != "none" {
            let lv = v.lowercased()
            if lv.contains("avc") || lv.contains("h264") { parts.append("h264") }
            else if lv.contains("hev") || lv.contains("hvc") || lv.contains("h265") { parts.append("hevc") }
            else if lv.contains("av01") || lv.contains("av1") { parts.append("av1") }
            else if lv.contains("vp9") || lv.contains("vp09") { parts.append("vp9") }
            else { parts.append(v.components(separatedBy: ".").first ?? v) }
        }
        if let a = acodec, a != "none" {
            let la = a.lowercased()
            if la.contains("mp4a") || la.contains("aac") { parts.append("aac") }
            else if la.contains("opus") { parts.append("opus") }
            else if la.contains("vorbis") { parts.append("vorbis") }
            else if la.contains("mp3") || la.contains("mp4a.69") || la.contains("mp4a.6b") { parts.append("mp3") }
            else { parts.append(a.components(separatedBy: ".").first ?? a) }
        }
        return parts.isEmpty ? ext : parts.joined(separator: "+")
    }
}

public struct SubtitleTrack: Codable, Sendable {
    public var lang: String
    public var name: String
    public var url: String
    public var ext: String // "vtt", "srt", "srv3"
    public var isAutoGenerated: Bool
    public init(lang: String, name: String, url: String, ext: String = "vtt", isAutoGenerated: Bool = false) {
        self.lang = lang
        self.name = name
        self.url = url
        self.ext = ext
        self.isAutoGenerated = isAutoGenerated
    }
}

public struct Chapter: Codable, Sendable, Equatable {
    public var title: String
    public var startTime: Double
    public var endTime: Double
    public init(title: String, startTime: Double, endTime: Double) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct PlaylistEntry: Codable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var duration: Double?
    public var thumbnail: String?
    public var author: String?
    public var uploadDate: String?
    public init(id: String, title: String, url: String, duration: Double? = nil, thumbnail: String? = nil, author: String? = nil, uploadDate: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.duration = duration
        self.thumbnail = thumbnail
        self.author = author
        self.uploadDate = uploadDate
    }
}

public struct MediaInfo: Codable, Sendable {
    public var id: String
    public var title: String
    public var site: String
    public var webpageURL: String
    public var author: String?
    public var uploadDate: String? // YYYY-MM-DD
    public var description: String?
    public var duration: Double?
    public var thumbnail: String?
    public var isLive: Bool
    public var isDRM: Bool
    public var signInHint: String?
    public var formats: [MediaFormat]
    public var subtitles: [SubtitleTrack]
    public var chapters: [Chapter]
    public var entries: [PlaylistEntry] // non-empty if playlist / channel / multi-part

    public init(
        id: String,
        title: String,
        site: String,
        webpageURL: String,
        author: String? = nil,
        uploadDate: String? = nil,
        description: String? = nil,
        duration: Double? = nil,
        thumbnail: String? = nil,
        isLive: Bool = false,
        isDRM: Bool = false,
        signInHint: String? = nil,
        formats: [MediaFormat] = [],
        subtitles: [SubtitleTrack] = [],
        chapters: [Chapter] = [],
        entries: [PlaylistEntry] = []
    ) {
        self.id = id
        self.title = title
        self.site = site
        self.webpageURL = webpageURL
        self.author = author
        self.uploadDate = uploadDate
        self.description = description
        self.duration = duration
        self.thumbnail = thumbnail
        self.isLive = isLive
        self.isDRM = isDRM
        self.signInHint = signInHint
        self.formats = formats
        self.subtitles = subtitles
        self.chapters = chapters
        self.entries = entries
    }

    public var isPlaylist: Bool { !entries.isEmpty && formats.isEmpty }
}

public struct SectionRange: Codable, Sendable, Equatable {
    public var start: Double? // seconds
    public var end: Double?   // seconds

    public init(start: Double?, end: Double?) {
        self.start = start
        self.end = end
    }

    public static func parse(_ raw: String) -> SectionRange? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 {
            let st = parts[0].isEmpty ? nil : Self.parseTimestamp(parts[0])
            let en = parts[1].isEmpty ? nil : Self.parseTimestamp(parts[1])
            if (!parts[0].isEmpty && st == nil) || (!parts[1].isEmpty && en == nil) { return nil }
            if let a = st, let b = en, b <= a { return nil }
            return SectionRange(start: st, end: en)
        }
        return nil
    }

    public static func parseTimestamp(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in: .whitespaces)
        if let sec = Double(clean), sec >= 0 { return sec }
        let comps = clean.split(separator: ":").compactMap { Double($0) }
        guard comps.count >= 2 && comps.count <= 3 else { return nil }
        if comps.count == 2 { return comps[0] * 60 + comps[1] }
        return comps[0] * 3600 + comps[1] * 60 + comps[2]
    }
}

public struct Settings: Codable, Sendable {
    public var folder: String = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads")
    public var mode: String = "video"               // "video" or "audio"
    public var quality: String = "best"             // "best", "2160", "1440", "1080", "720", "480", "360"
    public var compatible: Bool = true              // Prefer H.264/AAC in MP4
    public var videoFormat: String = "mp4"          // mp4, mov, mkv, webm
    public var audioFormat: String = "m4a"          // m4a, wav, flac, mp3, opus
    public var concurrent: Int = 4                  // 1-16 (unlocked!)
    public var connections: Int = 8                 // 1-32 (unlocked!)
    public var rateLimit: String = ""               // e.g. "2M", "500K"
    public var proxy: String = ""                   // e.g. "socks5://127.0.0.1:1080"
    public var cookies: String = "builtin"          // "builtin", "none", "safari", "chrome", "brave", "firefox", or path
    public var template: String = "{title}"         // {title} {site} {author} {quality} {date} {id}
    public var siteFolders: Bool = false
    public var playlistFolders: Bool = false
    public var embedMetadata: Bool = true
    public var embedSubtitles: Bool = true
    public var subtitles: Bool = false
    public var subtitleLangs: String = "en"
    public var saveThumbnail: Bool = false
    public var useUploadDate: Bool = false
    public var sponsors: String = "keep"            // "keep", "mark", "remove"
    public var addToLibrary: Bool = false           // Add to Apple Music / TV
    public var watchClipboard: Bool = true
    public var keepAwake: Bool = true
    public var menuBarIcon: Bool = false
    public var notify: Bool = true
    public var removeFinished: Bool = false
    public var checkSubscriptions: Int = 1          // hours; 0 = manual
    public var blockAds: Bool = true
    public var adLists: String = "easylist,easyprivacy"
    public var askFormat: Bool = false
    public var askPlaylist: Bool = true
    public var language: String = ""

    public init() {}

    public static func load() -> Settings {
        let url = AppPaths.settingsFile
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return decoded
    }

    public func save() throws {
        try AppPaths.ensureAppSupport()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: AppPaths.settingsFile, options: .atomic)
    }

    public mutating func setByKey(_ key: String, value: String) -> Bool {
        func b(_ s: String) -> Bool? {
            switch s.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        switch key {
        case "folder": folder = (value as NSString).expandingTildeInPath
        case "mode": guard ["video", "audio"].contains(value) else { return false }; mode = value
        case "quality": guard ["best", "2160", "1440", "1080", "720", "480", "360"].contains(value) else { return false }; quality = value
        case "compatible": guard let v = b(value) else { return false }; compatible = v
        case "videoFormat": guard ["mp4", "mov", "mkv", "webm"].contains(value) else { return false }; videoFormat = value
        case "audioFormat": guard ["m4a", "wav", "flac", "mp3", "opus", "aiff"].contains(value) else { return false }; audioFormat = value
        case "concurrent": guard let n = Int(value), (1...16).contains(n) else { return false }; concurrent = n
        case "connections": guard let n = Int(value), (1...32).contains(n) else { return false }; connections = n
        case "rateLimit": rateLimit = value
        case "proxy": proxy = value
        case "cookies": cookies = value
        case "template": template = value
        case "siteFolders": guard let v = b(value) else { return false }; siteFolders = v
        case "playlistFolders": guard let v = b(value) else { return false }; playlistFolders = v
        case "embedMetadata": guard let v = b(value) else { return false }; embedMetadata = v
        case "embedSubtitles": guard let v = b(value) else { return false }; embedSubtitles = v
        case "subtitles": guard let v = b(value) else { return false }; subtitles = v
        case "subtitleLangs": subtitleLangs = value
        case "saveThumbnail": guard let v = b(value) else { return false }; saveThumbnail = v
        case "useUploadDate": guard let v = b(value) else { return false }; useUploadDate = v
        case "sponsors": guard ["keep", "mark", "remove"].contains(value) else { return false }; sponsors = value
        case "addToLibrary": guard let v = b(value) else { return false }; addToLibrary = v
        case "watchClipboard": guard let v = b(value) else { return false }; watchClipboard = v
        case "keepAwake": guard let v = b(value) else { return false }; keepAwake = v
        case "menuBarIcon": guard let v = b(value) else { return false }; menuBarIcon = v
        case "notify": guard let v = b(value) else { return false }; notify = v
        case "removeFinished": guard let v = b(value) else { return false }; removeFinished = v
        case "checkSubscriptions": guard let n = Int(value), n >= 0 else { return false }; checkSubscriptions = n
        case "blockAds": guard let v = b(value) else { return false }; blockAds = v
        case "adLists": adLists = value
        case "askFormat": guard let v = b(value) else { return false }; askFormat = v
        case "askPlaylist": guard let v = b(value) else { return false }; askPlaylist = v
        case "language": language = value
        default: return false
        }
        return true
    }

    public func allEntries() -> [(key: String, value: String, description: String)] {
        [
            ("adLists", adLists, "Adblock filter lists (comma-separated)"),
            ("addToLibrary", String(addToLibrary), "Add finished downloads to Apple Music or TV"),
            ("askFormat", String(askFormat), "Ask which format to download for each link"),
            ("askPlaylist", String(askPlaylist), "Ask which items of a playlist to download"),
            ("audioFormat", audioFormat, "Audio format: m4a, wav, flac, aiff, mp3, opus"),
            ("blockAds", String(blockAds), "Block ads and trackers in the built-in browser"),
            ("checkSubscriptions", String(checkSubscriptions), "Hours between subscription checks (0 = manual)"),
            ("compatible", String(compatible), "Prefer H.264/AAC in MP4 for universal playback"),
            ("concurrent", String(concurrent), "Downloads running at once (1-16)"),
            ("connections", String(connections), "Parallel range connections per download (1-32)"),
            ("cookies", cookies, "Cookie source: builtin, none, chrome, brave, firefox, safari, or file path"),
            ("embedMetadata", String(embedMetadata), "Embed title, artist, date, link, chapters & cover art"),
            ("embedSubtitles", String(embedSubtitles), "Mux subtitles inside MP4 rather than beside them"),
            ("folder", folder, "Folder downloads are saved to"),
            ("keepAwake", String(keepAwake), "Prevent sleep while downloads are running"),
            ("language", language, "App language override (en, zh-Hans)"),
            ("menuBarIcon", String(menuBarIcon), "Keep uBit in the macOS menu bar"),
            ("mode", mode, "Default download mode: video or audio"),
            ("notify", String(notify), "Send macOS notification when downloads finish"),
            ("playlistFolders", String(playlistFolders), "Put playlist items into a named subfolder"),
            ("proxy", proxy, "Proxy URL, e.g. socks5://127.0.0.1:1080 or http://127.0.0.1:8080"),
            ("quality", quality, "Max video height: best, 2160, 1440, 1080, 720, 480, 360"),
            ("rateLimit", rateLimit, "Speed limit per download, e.g. 2M or 500K"),
            ("removeFinished", String(removeFinished), "Clear finished items from list automatically"),
            ("saveThumbnail", String(saveThumbnail), "Save cover thumbnail .jpg beside downloaded file"),
            ("siteFolders", String(siteFolders), "Put each site's downloads in a subfolder"),
            ("sponsors", sponsors, "SponsorBlock mode for YouTube: keep, mark, remove"),
            ("subtitleLangs", subtitleLangs, "Subtitle languages, e.g. en,de or all"),
            ("subtitles", String(subtitles), "Download subtitles automatically"),
            ("template", template, "Filename template: {title} {site} {author} {quality} {date} {id}"),
            ("useUploadDate", String(useUploadDate), "Set file modification date to media publish date"),
            ("videoFormat", videoFormat, "Video container: mp4, mov, mkv, webm"),
            ("watchClipboard", String(watchClipboard), "Offer copied media links when focusing app"),
        ]
    }
}

public enum DownloadState: String, Codable, Sendable {
    case queued
    case extracting
    case downloading
    case processing
    case paused
    case done
    case failed
    case canceled
}

public struct LibraryItem: Codable, Sendable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var site: String
    public var author: String?
    public var quality: String?
    public var ext: String
    public var path: String?
    public var thumbnail: String?
    public var duration: Double?
    public var state: DownloadState
    public var stage: String?
    public var fraction: Double
    public var downloadedBytes: Int64
    public var totalBytes: Int64
    public var speedBytesPerSec: Int64
    public var etaSeconds: Int?
    public var isAudio: Bool
    public var isLive: Bool
    public var error: String?
    public var createdAt: Date
    public var finishedAt: Date?
    public var formatID: String?
    public var section: SectionRange?

    public init(
        id: String = UUID().uuidString.lowercased(),
        url: String,
        title: String = "",
        site: String = "",
        author: String? = nil,
        quality: String? = nil,
        ext: String = "mp4",
        path: String? = nil,
        thumbnail: String? = nil,
        duration: Double? = nil,
        state: DownloadState = .queued,
        stage: String? = nil,
        fraction: Double = 0,
        downloadedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        speedBytesPerSec: Int64 = 0,
        etaSeconds: Int? = nil,
        isAudio: Bool = false,
        isLive: Bool = false,
        error: String? = nil,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        formatID: String? = nil,
        section: SectionRange? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title.isEmpty ? url : title
        self.site = site
        self.author = author
        self.quality = quality
        self.ext = ext
        self.path = path
        self.thumbnail = thumbnail
        self.duration = duration
        self.state = state
        self.stage = stage
        self.fraction = fraction
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.etaSeconds = etaSeconds
        self.isAudio = isAudio
        self.isLive = isLive
        self.error = error
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.formatID = formatID
        self.section = section
    }
}

public struct Subscription: Codable, Sendable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var site: String
    public var thumbnail: String?
    public var audioOnly: Bool
    public var seenIDs: Set<String>
    public var lastCheckedAt: Date?
    public var lastNewCount: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        url: String,
        title: String,
        site: String,
        thumbnail: String? = nil,
        audioOnly: Bool = false,
        seenIDs: Set<String> = [],
        lastCheckedAt: Date? = nil,
        lastNewCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.site = site
        self.thumbnail = thumbnail
        self.audioOnly = audioOnly
        self.seenIDs = seenIDs
        self.lastCheckedAt = lastCheckedAt
        self.lastNewCount = lastNewCount
        self.createdAt = createdAt
    }
}

public enum AppPaths {
    public static var appSupportDir: URL {
        if let custom = ProcessInfo.processInfo.environment["UBIT_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("uBit", isDirectory: true)
    }

    public static var settingsFile: URL { appSupportDir.appendingPathComponent("settings.json") }
    public static var libraryFile: URL { appSupportDir.appendingPathComponent("library.json") }
    public static var subsFile: URL { appSupportDir.appendingPathComponent("subscriptions.json") }
    public static var cookiesFile: URL { appSupportDir.appendingPathComponent("cookies.txt") }
    public static var thumbCacheDir: URL { appSupportDir.appendingPathComponent("thumbs", isDirectory: true) }
    public static var workDir: URL { appSupportDir.appendingPathComponent("work", isDirectory: true) }
    public static var adblockCacheDir: URL { appSupportDir.appendingPathComponent("adblock", isDirectory: true) }
    public static var ipcSocketPath: String { appSupportDir.appendingPathComponent("ubit.sock").path }

    public static func ensureAppSupport() throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }
}

public enum FormatHelpers {
    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var val = Double(bytes)
        var idx = -1
        while val >= 1024 && idx < units.count - 1 {
            val /= 1024
            idx += 1
        }
        return String(format: val >= 100 ? "%.0f %@" : "%.1f %@", val, units[max(0, idx)])
    }

    public static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func parseRateLimit(_ text: String) -> Int64? {
        let s = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return nil }
        var mult: Double = 1
        var numPart = s
        if s.hasSuffix("K") || s.hasSuffix("KB") {
            mult = 1024
            numPart = s.replacingOccurrences(of: "KB", with: "").replacingOccurrences(of: "K", with: "")
        } else if s.hasSuffix("M") || s.hasSuffix("MB") {
            mult = 1024 * 1024
            numPart = s.replacingOccurrences(of: "MB", with: "").replacingOccurrences(of: "M", with: "")
        } else if s.hasSuffix("G") || s.hasSuffix("GB") {
            mult = 1024 * 1024 * 1024
            numPart = s.replacingOccurrences(of: "GB", with: "").replacingOccurrences(of: "G", with: "")
        }
        guard let v = Double(numPart), v > 0 else { return nil }
        return Int64(v * mult)
    }

    public static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
        var str = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        while str.hasPrefix(".") { str.removeFirst() }
        if str.isEmpty { str = "download" }
        if str.utf8.count > 220 {
            str = String(str.prefix(100))
        }
        return str
    }

    public static func renderTemplate(
        _ template: String,
        info: MediaInfo,
        quality: String,
        ext: String
    ) -> String {
        let map: [String: String] = [
            "{title}": sanitizeFilename(info.title),
            "{site}": sanitizeFilename(info.site),
            "{author}": sanitizeFilename(info.author ?? "Unknown"),
            "{quality}": sanitizeFilename(quality),
            "{date}": sanitizeFilename(info.uploadDate ?? ""),
            "{id}": sanitizeFilename(info.id),
        ]
        var rendered = template.isEmpty ? "{title}" : template
        for (k, v) in map {
            rendered = rendered.replacingOccurrences(of: k, with: v)
        }
        // Preserve intentional '/' subfolder separators in template while sanitizing each component
        let parts = rendered.split(separator: "/").map { FormatHelpers.sanitizeFilename(String($0)) }.filter { !$0.isEmpty }
        let joined = parts.isEmpty ? sanitizeFilename(info.title) : parts.joined(separator: "/")
        return "\(joined).\(ext)"
    }
}
