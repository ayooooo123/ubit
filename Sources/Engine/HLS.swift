import Foundation
import CommonCrypto
import CryptoKit

public struct HLSVals {
    public struct Segment: Sendable {
        public var index: Int
        public var url: String
        fileprivate var playlistDuration: Decimal
        public var duration: Double { (playlistDuration as NSDecimalNumber).doubleValue }
        public var byteRange: ByteRange?
        public var keyURL: String?
        public var iv: Data?
        public var mediaSequence: UInt64
    }

    public struct MediaPlaylist: Sendable {
        public var initURL: String?
        public var initByteRange: ByteRange?
        public var segments: [Segment]
        public var isLive: Bool
        public var targetDuration: Double
    }
}

public enum HLSEngine {
    public static func parseAttributes(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = raw.startIndex
        while i < raw.endIndex {
            while i < raw.endIndex && (raw[i] == "," || raw[i].isWhitespace) {
                i = raw.index(after: i)
            }
            guard i < raw.endIndex, let eq = raw[i...].firstIndex(of: "=") else { break }
            let key = String(raw[i..<eq]).trimmingCharacters(in: .whitespaces)
            var vStart = raw.index(after: eq)
            if vStart < raw.endIndex && raw[vStart] == "\"" {
                vStart = raw.index(after: vStart)
                var val = ""
                while vStart < raw.endIndex && raw[vStart] != "\"" {
                    val.append(raw[vStart])
                    vStart = raw.index(after: vStart)
                }
                if vStart < raw.endIndex && raw[vStart] == "\"" {
                    vStart = raw.index(after: vStart)
                }
                out[key] = val
                i = vStart
            } else {
                let comma = raw[vStart...].firstIndex(of: ",") ?? raw.endIndex
                out[key] = String(raw[vStart..<comma]).trimmingCharacters(in: .whitespaces)
                i = comma
            }
        }
        return out
    }

    /// Resolves a playlist URI to the URL that an HTTP request for it asks for. Edition checks
    /// compare these URLs, so two spellings of one resource ("pack.m4s" and "pack.m4s#") are one
    /// resource there too.
    private static func resolve(_ rel: String, base: URL) -> String {
        if rel.hasPrefix("http://") || rel.hasPrefix("https://") { return retrievalURL(rel) }
        return retrievalURL(URL(string: rel, relativeTo: base)?.absoluteURL.absoluteString ?? rel)
    }

    /// `url` without the parts that do not change the requested resource (RFC 3986, 6.2.2): the
    /// fragment, which a client does not send, the case of the scheme and host, a default port,
    /// dot segments and percent-encoded unreserved characters. Path and query stay otherwise as
    /// they are.
    static func retrievalURL(_ url: String) -> String {
        guard var parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else { return url }
        parts.scheme = scheme
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.fragment = nil
        var path = removeDotSegments(normalizePercents(parts.percentEncodedPath))
        if path.isEmpty, parts.percentEncodedHost != nil { path = "/" }
        parts.percentEncodedPath = path
        if let query = parts.percentEncodedQuery { parts.percentEncodedQuery = normalizePercents(query) }
        return parts.string ?? url
    }

    /// Decodes percent-encoded unreserved characters and writes other escapes in uppercase.
    private static func normalizePercents(_ text: String) -> String {
        guard text.contains("%") else { return text }
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            default: return nil
            }
        }
        let hex = Array("0123456789ABCDEF".utf8)
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count, let high = digit(bytes[i + 1]), let low = digit(bytes[i + 2]) {
                let value = high << 4 | low
                if unreserved.contains(value) { out.append(value) } else { out += [UInt8(ascii: "%"), hex[Int(high)], hex[Int(low)]] }
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// RFC 3986, 5.2.4, for an absolute path.
    private static func removeDotSegments(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        var out: [Substring] = []
        for (index, segment) in segments.enumerated() {
            let last = index == segments.count - 1
            if segment == "." || segment == ".." {
                if segment == "..", out.count > 1 { out.removeLast() }
                if last { out.append("") }
                continue
            }
            out.append(segment)
        }
        return out.joined(separator: "/")
    }

    private static func parseByteRange(_ s: String, prevEnd: inout Int64) -> ByteRange? {
        let parts = s.split(separator: "@")
        guard let len = Int64(parts[0]) else { return nil }
        let start: Int64
        if parts.count == 2, let off = Int64(parts[1]) {
            start = off
        } else {
            start = prevEnd
        }
        prevEnd = start + len
        return ByteRange(start: start, end: start + len - 1)
    }

    /// Parses an HLS master or media playlist into `MediaFormat` options.
    public static func extractFormats(
        client: HTTPClient,
        playlistURL: String,
        headers: [String: String]? = nil,
        idPrefix: String = "hls"
    ) async throws -> [MediaFormat] {
        let (text, finalURL) = try await client.fetchText(url: playlistURL, headers: headers)
        if !text.contains("#EXT-X-STREAM-INF") {
            let isLive = !text.contains("#EXT-X-ENDLIST") && text.contains("#EXTINF:")
            return [MediaFormat(
                id: idPrefix,
                url: finalURL.absoluteString,
                ext: "mp4",
                proto: .hls,
                vcodec: "avc1",
                acodec: "mp4a",
                headers: headers,
                isLive: isLive
            )]
        }

        // Parse #EXT-X-MEDIA audio groups first
        var audioGroups: [String: String] = [:] // GROUP-ID -> URI
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            if attrs["TYPE"] == "AUDIO", let gid = attrs["GROUP-ID"], let uri = attrs["URI"] {
                let resolved = resolve(uri, base: finalURL)
                if audioGroups[gid] == nil || attrs["DEFAULT"] == "YES" {
                    audioGroups[gid] = resolved
                }
            }
        }

        var formats: [MediaFormat] = []
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                var uriLine = ""
                var nextIdx = idx + 1
                while nextIdx < lines.count {
                    if !lines[nextIdx].isEmpty && !lines[nextIdx].hasPrefix("#") {
                        uriLine = lines[nextIdx]
                        break
                    }
                    nextIdx += 1
                }
                if !uriLine.isEmpty {
                    let fullURI = resolve(uriLine, base: finalURL)
                    let bw = Int64(attrs["AVERAGE-BANDWIDTH"] ?? attrs["BANDWIDTH"] ?? "0")
                    var width: Int?
                    var height: Int?
                    if let res = attrs["RESOLUTION"] {
                        let wh = res.lowercased().split(separator: "x")
                        if wh.count == 2 {
                            width = Int(wh[0])
                            height = Int(wh[1])
                        }
                    }
                    let fps = attrs["FRAME-RATE"].flatMap(Double.init)
                    var vcodec: String? = "avc1"
                    var acodec: String? = "mp4a"
                    if let codecs = attrs["CODECS"] {
                        let cparts = codecs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        vcodec = cparts.first { !$0.lowercased().hasPrefix("mp4a") && !$0.lowercased().hasPrefix("opus") && !$0.lowercased().hasPrefix("ac-3") }
                        acodec = cparts.first { $0.lowercased().hasPrefix("mp4a") || $0.lowercased().hasPrefix("opus") || $0.lowercased().hasPrefix("ac-3") }
                    }
                    let audioURI = attrs["AUDIO"].flatMap { audioGroups[$0] }
                    if audioURI != nil && acodec == nil { acodec = "mp4a" }
                    let fid = height != nil ? "\(idPrefix)-\(height!)p" : "\(idPrefix)-\(formats.count)"
                    formats.append(MediaFormat(
                        id: fid,
                        url: fullURI,
                        ext: "mp4",
                        proto: .hls,
                        vcodec: vcodec,
                        acodec: acodec,
                        width: width,
                        height: height,
                        fps: fps,
                        bitrate: bw,
                        qualityLabel: attrs["VIDEO"],
                        headers: headers,
                        audioTrackURL: audioURI
                    ))
                    idx = nextIdx
                }
            }
            idx += 1
        }

        // Also expose standalone audio rendition if available
        if let (_, audioURI) = audioGroups.first {
            formats.append(MediaFormat(
                id: "\(idPrefix)-audio",
                url: audioURI,
                ext: "m4a",
                proto: .hls,
                vcodec: "none",
                acodec: "mp4a",
                qualityLabel: "Audio",
                headers: headers
            ))
        }
        return formats
    }

    public static func parseMediaPlaylist(_ text: String, baseURL: URL) -> HLSVals.MediaPlaylist {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var initURL: String?
        var initByteRange: ByteRange?
        var segments: [HLSVals.Segment] = []
        var curDur: Decimal = 0
        var curRange: ByteRange?
        var prevRangeEnd: Int64 = 0
        var curKeyURL: String?
        var curIV: Data?
        var mediaSeq: UInt64 = 0
        var targetDur: Double = 4.0

        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDur = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 4.0
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSeq = UInt64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let u = attrs["URI"] { initURL = resolve(u, base: baseURL) }
                if let br = attrs["BYTERANGE"] {
                    var zero: Int64 = 0
                    initByteRange = parseByteRange(br, prevEnd: &zero)
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                if attrs["METHOD"] == "AES-128", let u = attrs["URI"] {
                    curKeyURL = resolve(u, base: baseURL)
                    if let ivHex = attrs["IV"] {
                        let clean = ivHex.hasPrefix("0x") || ivHex.hasPrefix("0X") ? String(ivHex.dropFirst(2)) : ivHex
                        curIV = hexDecode(clean)
                    } else {
                        curIV = nil
                    }
                } else if attrs["METHOD"] == "NONE" {
                    curKeyURL = nil
                    curIV = nil
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                curRange = parseByteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), prevEnd: &prevRangeEnd)
            } else if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                let comma = body.firstIndex(of: ",") ?? body.endIndex
                curDur = Decimal(string: String(body[..<comma]), locale: Locale(identifier: "en_US_POSIX")) ?? 0
            } else if !line.hasPrefix("#") {
                let segSeq = mediaSeq + UInt64(segments.count)
                segments.append(HLSVals.Segment(
                    index: segments.count,
                    url: resolve(line, base: baseURL),
                    playlistDuration: curDur,
                    byteRange: curRange,
                    keyURL: curKeyURL,
                    iv: curIV,
                    mediaSequence: segSeq
                ))
                curDur = 0
                curRange = nil
            }
        }
        let isLive = !text.contains("#EXT-X-ENDLIST")
        return HLSVals.MediaPlaylist(
            initURL: initURL,
            initByteRange: initByteRange,
            segments: segments,
            isLive: isLive,
            targetDuration: targetDur
        )
    }

    /// Multiple playlist entries for one URI must read one edition of the object: the same
    /// strong ETag from the same answering URL, or one complete copy.
    private enum RangeSource: Sendable {
        case tagged(HTTPClient.Edition)
        case snapshot(Data)

        static func open(_ url: String, client: HTTPClient, headers: [String: String]?) async throws -> Self {
            if let edition = try await client.probeRemote(url: url, headers: headers).edition { return .tagged(edition) }
            return .snapshot(try await snapshotOf(url, client: client, headers: headers))
        }

        static func snapshotOf(_ url: String, client: HTTPClient, headers: [String: String]?) async throws -> Data {
            // The origin cannot validate separate reads. Stream one response to disk, then
            // map it so that we do not hold a potentially large copy on the Swift heap.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let file = dir.appendingPathComponent("object")
            defer { try? FileManager.default.removeItem(at: dir) }
            try await client.downloadFile(url: url, destination: file, headers: headers, connections: 1)
            return try Data(contentsOf: file, options: .alwaysMapped)
        }
    }

    private static func fetchPart(_ url: String, range: ByteRange?, client: HTTPClient, headers: [String: String]?, source: RangeSource? = nil) async throws -> Data {
        var edition: HTTPClient.Edition?
        switch source {
        case .snapshot(let data):
            guard let range else { return data }
            guard range.start >= 0, range.end >= range.start, range.end < Int64(data.count) else { throw HTTPError.rangeUnsupported }
            return data.subdata(in: Int(range.start)..<(Int(range.end) + 1))
        case .tagged(let value): edition = value
        case nil: break
        }
        if let range {
            let bytes = try await client.fetchRange(url: url, range: range, headers: headers, edition: edition).data
            guard !bytes.isEmpty, Int64(bytes.count - 1) == range.end - range.start else { throw HTTPError.rangeUnsupported }
            return bytes
        }
        var fields = headers ?? [:]
        if let edition { fields["If-Match"] = edition.tag }
        let (data, response) = try await client.fetchData(url: edition?.location ?? url, headers: fields)
        if let edition, HTTPClient.edition(response) != edition { throw HTTPError.rangeUnsupported }
        return data
    }

    private static func hexDecode(_ hex: String) -> Data? {
        var padded = hex
        if padded.count % 2 != 0 { padded = "0" + padded }
        var data = Data(capacity: padded.count / 2)
        var idx = padded.startIndex
        while idx < padded.endIndex {
            let next = padded.index(idx, offsetBy: 2)
            guard let b = UInt8(padded[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data
    }

    public static func decryptAES128(data: Data, key: Data, iv: Data?, sequence: UInt64) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { return data }
        var ivBytes: [UInt8]
        if let iv, iv.count == 16 {
            ivBytes = [UInt8](iv)
        } else {
            ivBytes = [UInt8](repeating: 0, count: 16)
            var seqBE = sequence.bigEndian
            withUnsafeBytes(of: &seqBE) { ptr in
                for i in 0..<8 { ivBytes[8 + i] = ptr[i] }
            }
        }
        let outCap = data.count + kCCBlockSizeAES128
        var out = Data(count: outCap)
        var outLen: size_t = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress,
                        kCCKeySizeAES128,
                        ivBytes,
                        inPtr.baseAddress,
                        data.count,
                        outPtr.baseAddress,
                        outCap,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "HLSEngine", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AES-128 segment decryption failed"])
        }
        out.count = outLen
        return out
    }

    /// Downloads VOD or Live HLS playlist segments into `destination` raw stream (fMP4 or MPEG-TS).
    /// Returns `(isFragmentedMP4, recordedDurationSeconds, startTime)`. `startTime` is the stream time
    /// where the first saved segment starts; it is 0 without a section and for a live recording.
    public static func downloadStream(
        client: HTTPClient,
        playlistURL: String,
        destination: URL,
        headers: [String: String]? = nil,
        section: SectionRange? = nil,
        connections: Int = 8,
        shouldStopLive: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (_ downloaded: Int64, _ estTotal: Int64, _ fraction: Double, _ recordedSec: Double) -> Void)? = nil
    ) async throws -> (isFMP4: Bool, duration: Double, startTime: Double) {
        let (text, finalURL) = try await client.fetchText(url: playlistURL, headers: headers)
        let pl = parseMediaPlaylist(text, baseURL: finalURL)

        if pl.isLive && section == nil {
            let (isFMP4, recorded) = try await recordLiveStream(
                client: client,
                playlistURL: finalURL.absoluteString,
                initialPlaylist: pl,
                destination: destination,
                headers: headers,
                shouldStop: shouldStopLive,
                onProgress: onProgress
            )
            return (isFMP4, recorded, 0)
        }

        // Filter segments if section range was requested. The demuxers start the saved timeline
        // at 0, so the caller needs the stream time where the first kept segment starts.
        var selected = pl.segments
        var startTime: Double = 0
        if let sec = section {
            let start = Decimal(string: String(sec.start ?? 0)) ?? .greatestFiniteMagnitude
            let end = sec.end.flatMap { Decimal(string: String($0)) } ?? .greatestFiniteMagnitude
            // Compare in playlist units. Convert only the base of the saved stream.
            var elapsed: Decimal = 0
            var previousStart: Decimal = 0
            var filtered: [HLSVals.Segment] = []
            for (index, seg) in pl.segments.enumerated() {
                let segStart = elapsed
                elapsed += seg.playlistDuration
                defer { previousStart = segStart }
                if segStart >= end { break }
                guard max(start, segStart) < min(end, elapsed) else { continue }
                if filtered.isEmpty {
                    var base = segStart
                    // Keep the previous segment for keyframe preroll at an exact boundary,
                    // but only after finding a segment with media inside the section.
                    if segStart == start, index > 0 {
                        filtered.append(pl.segments[index - 1])
                        base = previousStart
                    }
                    startTime = Double(base.description)!
                }
                filtered.append(seg)
            }
            // A section that no segment overlaps (for example one after the end) is an error: the
            // whole playlist must not be saved as if it were the clip.
            guard !filtered.isEmpty else {
                throw NSError(domain: "HLSEngine", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The --section range is outside the stream"])
            }
            selected = filtered
        }

        // Segment positions are relative to this selection, not to the playlist.
        let segWorkDir = destination.deletingLastPathComponent()
            .appendingPathComponent(".segs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: segWorkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: segWorkDir) }

        /// Digests of the URIs that the selection reads whole more than once.
        actor WholeReads {
            let urls: Set<String>
            var digests: [String: SHA256.Digest] = [:]
            init(_ urls: Set<String>) { self.urls = urls }
            func check(_ url: String, _ data: Data) throws {
                guard urls.contains(url) else { return }
                let digest = SHA256.hash(data: data)
                guard let first = digests[url] else { digests[url] = digest; return }
                // Compare complete responses rather than join bytes from two editions.
                guard digest == first else { throw HTTPError.rangeUnsupported }
            }
        }

        // A URI that the selection uses more than once must give one edition. A URI with a byte
        // range is pinned (a strong ETag or a complete copy). A URI that is only read whole keeps
        // the digest of its first read, and every later read must give the same bytes.
        var seen = Set<String>(), repeated = Set<String>(), ranged = Set<String>()
        if let url = pl.initURL {
            seen.insert(url)
            if pl.initByteRange != nil { ranged.insert(url) }
        }
        for seg in selected {
            if !seen.insert(seg.url).inserted { repeated.insert(seg.url) }
            if seg.byteRange != nil { ranged.insert(seg.url) }
        }
        var shared = repeated.intersection(ranged)
        let wholeReads = WholeReads(repeated.subtracting(shared))
        var sources: [String: RangeSource] = [:]
        var initData: Data?
        if let initU = pl.initURL {
            if shared.remove(initU) != nil {
                sources[initU] = try await RangeSource.open(initU, client: client, headers: headers)
            }
            let data = try await fetchPart(initU, range: pl.initByteRange, client: client, headers: headers, source: sources[initU])
            try await wholeReads.check(initU, data)
            initData = data
        }
        for url in shared { sources[url] = try await RangeSource.open(url, client: client, headers: headers) }
        let pinned = sources

        actor KeyStore {
            var cache: [String: Data] = [:]
            func get(_ url: String, client: HTTPClient, headers: [String: String]?) async throws -> Data {
                if let d = cache[url] { return d }
                let (d, _) = try await client.fetchData(url: url, headers: headers)
                cache[url] = d
                return d
            }
        }

        actor ProgressTracker {
            var completedCount = 0
            var totalBytes: Int64 = 0
            let totalSegs: Int
            init(totalSegs: Int) { self.totalSegs = max(1, totalSegs) }
            func add(bytes: Int64) -> (Int, Int64, Double) {
                completedCount += 1
                totalBytes += bytes
                let frac = Double(completedCount) / Double(totalSegs)
                let est = frac > 0.01 ? Int64(Double(totalBytes) / frac) : 0
                return (completedCount, est, frac)
            }
            func currentBytes() -> Int64 { totalBytes }
        }

        let keyStore = KeyStore()
        let tracker = ProgressTracker(totalSegs: selected.count)
        let concurrency = max(1, min(16, connections))

        // Parallel worker pool over segment indices
        actor IndexCursor {
            var next = 0
            let count: Int
            init(_ count: Int) { self.count = count }
            func take() -> Int? {
                guard next < count else { return nil }
                defer { next += 1 }
                return next
            }
        }
        let cursor = IndexCursor(selected.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while let pos = await cursor.take() {
                        try Task.checkCancellation()
                        let seg = selected[pos]
                        let segFile = segWorkDir.appendingPathComponent(String(format: "%06d.seg", pos))
                        var raw = try await fetchPart(seg.url, range: seg.byteRange, client: client, headers: headers, source: pinned[seg.url])
                        try await wholeReads.check(seg.url, raw)
                        if let kurl = seg.keyURL {
                            try Task.checkCancellation()
                            let key = try await keyStore.get(kurl, client: client, headers: headers)
                            raw = try decryptAES128(data: raw, key: key, iv: seg.iv, sequence: seg.mediaSequence)
                        }
                        try raw.write(to: segFile, options: .atomic)
                        let (_, est, frac) = await tracker.add(bytes: Int64(raw.count))
                        let cur = await tracker.currentBytes()
                        onProgress?(cur, est, frac, 0)
                    }
                }
            }
            // Throw the first failed fetch and cancel outstanding workers on group exit.
            for try await _ in group {}
        }

        // Concatenate init + segments into destination atomically
        let partOut = segWorkDir.appendingPathComponent("assembled")
        FileManager.default.createFile(atPath: partOut.path, contents: nil)
        let fh = try FileHandle(forWritingTo: partOut)
        var firstBytes = Data()
        if let initData {
            try fh.write(contentsOf: initData)
            firstBytes = initData.prefix(16)
        }
        var totalDur: Double = 0
        for pos in 0..<selected.count {
            try Task.checkCancellation()
            totalDur += selected[pos].duration
            let segFile = segWorkDir.appendingPathComponent(String(format: "%06d.seg", pos))
            let d = try Data(contentsOf: segFile)
            if firstBytes.isEmpty { firstBytes = d.prefix(16) }
            try fh.write(contentsOf: d)
        }
        try fh.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partOut, to: destination)

        let isFMP4 = initData != nil || (firstBytes.count >= 8 && String(decoding: firstBytes[4..<8], as: UTF8.self) == "ftyp") || (firstBytes.first != 0x47)
        return (isFMP4, totalDur, startTime)
    }

    private static func recordLiveStream(
        client: HTTPClient,
        playlistURL: String,
        initialPlaylist: HLSVals.MediaPlaylist,
        destination: URL,
        headers: [String: String]?,
        shouldStop: (@Sendable () -> Bool)?,
        onProgress: (@Sendable (Int64, Int64, Double, Double) -> Void)?
    ) async throws -> (isFMP4: Bool, duration: Double) {
        let partOut = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partOut.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: partOut) }
        let fh = try FileHandle(forWritingTo: partOut)
        defer { try? fh.close() }

        var wroteInit = false
        var isFMP4 = false
        var seenSeq = Set<UInt64>()
        var recordedBytes: Int64 = 0
        var recordedSec: Double = 0
        var keyCache: [String: Data] = [:]

        // Every URI keeps its edition: a strong ETag, a complete copy, or a digest of the
        // complete body. An EVENT playlist can list every past URI, so copies are kept only
        // for byte ranges and only up to `snapshotBudget` bytes in total. An evicted copy and a
        // whole read leave a digest, and a later range of that URI compares a new complete copy.
        var liveSources: [String: RangeSource] = [:]
        var digests: [String: SHA256.Digest] = [:]
        var snapshotOrder: [String] = []
        var snapshotBytes = 0
        let snapshotBudget = 64 << 20
        func evict(_ url: String) {
            guard case .snapshot(let bytes)? = liveSources[url] else { return }
            liveSources.removeValue(forKey: url)
            digests[url] = SHA256.hash(data: bytes)
            snapshotBytes -= bytes.count
            snapshotOrder.removeAll { $0 == url }
        }
        func keep(_ url: String, _ source: RangeSource) {
            liveSources[url] = source
            guard case .snapshot(let bytes) = source else { return }
            snapshotOrder.append(url)
            snapshotBytes += bytes.count
            // Older copies go first. The newest copy stays until it has served its range.
            while snapshotBytes > snapshotBudget, snapshotOrder.count > 1 { evict(snapshotOrder[0]) }
        }
        func livePart(_ url: String, range: ByteRange?) async throws -> Data {
            if let digest = digests[url] {
                // Compare one complete response rather than append bytes from a different edition.
                let fresh = try await RangeSource.snapshotOf(url, client: client, headers: headers)
                guard SHA256.hash(data: fresh) == digest else { throw HTTPError.rangeUnsupported }
                guard range != nil else { return fresh }
                digests.removeValue(forKey: url)
                keep(url, .snapshot(fresh))
            } else if liveSources[url] == nil {
                guard range != nil else {
                    let (data, response) = try await client.fetchData(url: url, headers: headers)
                    if let edition = HTTPClient.edition(response) { liveSources[url] = .tagged(edition) } else { digests[url] = SHA256.hash(data: data) }
                    return data
                }
                keep(url, try await RangeSource.open(url, client: client, headers: headers))
            }
            let part = try await fetchPart(url, range: range, client: client, headers: headers, source: liveSources[url])
            // A copy that alone exceeds the budget is not kept after it has served its range.
            if snapshotBytes > snapshotBudget { evict(url) }
            return part
        }
        var currentPL = initialPlaylist
        var firstIteration = true

        while !(shouldStop?() ?? false) && !Task.isCancelled {
            if !firstIteration {
                let (txt, u) = try await client.fetchText(url: playlistURL, headers: headers)
                currentPL = parseMediaPlaylist(txt, baseURL: u)
                if !snapshotOrder.isEmpty {
                    var active = Set(currentPL.segments.map(\.url))
                    if let url = currentPL.initURL { active.insert(url) }
                    for url in snapshotOrder where !active.contains(url) { evict(url) }
                }
            }
            firstIteration = false

            if !wroteInit, let initU = currentPL.initURL {
                let d = try await livePart(initU, range: currentPL.initByteRange)
                try fh.write(contentsOf: d)
                recordedBytes += Int64(d.count)
                wroteInit = true
                isFMP4 = true
            }

            let candidates = seenSeq.isEmpty ? Array(currentPL.segments.suffix(3)) : currentPL.segments
            for seg in candidates {
                if shouldStop?() == true || Task.isCancelled { break }
                if !seenSeq.insert(seg.mediaSequence).inserted { continue }
                var d = try await livePart(seg.url, range: seg.byteRange)
                if let kurl = seg.keyURL {
                    let key: Data
                    if let cached = keyCache[kurl] { key = cached }
                    else {
                        key = try await client.fetchData(url: kurl, headers: headers).0
                        keyCache[kurl] = key
                    }
                    d = try decryptAES128(data: d, key: key, iv: seg.iv, sequence: seg.mediaSequence)
                }
                if !wroteInit && recordedBytes == 0 && d.first != 0x47 {
                    isFMP4 = true
                }
                try fh.write(contentsOf: d)
                recordedBytes += Int64(d.count)
                recordedSec += seg.duration
                onProgress?(recordedBytes, 0, 0, recordedSec)
            }

            if !currentPL.isLive { break }
            let sleepNs = UInt64(max(1.0, currentPL.targetDuration * 0.5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNs)
        }

        try fh.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partOut, to: destination)
        return (isFMP4, recordedSec)
    }
}
