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
        /// The number of `#EXT-X-DISCONTINUITY` tags before this segment. Media times
        /// of two segments compare only when this number is the same.
        public var discontinuity: Int
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

    private static func resolve(_ rel: String, base: URL) -> String {
        if rel.hasPrefix("http://") || rel.hasPrefix("https://") { return rel }
        return URL(string: rel, relativeTo: base)?.absoluteURL.absoluteString ?? rel
    }

    /// The group of spellings that can name one resource, for edition checks only. Requests use
    /// the URL as the playlist wrote it, because an origin can route two spellings differently,
    /// and a pinned source serves only the URL that opened it. Every spelling in a group is
    /// requested itself, and all of them must give one edition, so a group that joins two
    /// resources can only stop a download. The key keeps the path and the query as URLSession
    /// sends them, with their percent-encoding unchanged. It drops the fragment, user
    /// information (URLSession sends no credentials before a challenge), the case of the scheme
    /// and the host, the spelling of an IPv6 address and of the port, an IPv6 zone (a scoped and
    /// an unscoped loopback address send the same request), and dot segments.
    static func resourceKey(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              let host = parts.percentEncodedHost, !host.isEmpty else { return url }
        let port = parts.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        var path = removeDotSegments(parts.percentEncodedPath)
        if path.isEmpty { path = "/" }
        let query = parts.percentEncodedQuery.map { "?" + $0 } ?? ""
        return "\(scheme)://\(canonicalHost(host)):\(port)\(path)\(query)"
    }

    /// A lowercase host name, or an IPv6 literal in its shortest form without its zone.
    private static func canonicalHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host.lowercased() }
        let inner = host.dropFirst().dropLast()
        let address = inner[..<(inner.range(of: "%25")?.lowerBound ?? inner.endIndex)]
        var bytes = in6_addr()
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_pton(AF_INET6, String(address), &bytes) == 1,
              inet_ntop(AF_INET6, &bytes, &text, socklen_t(text.count)) != nil else { return host.lowercased() }
        return "[" + String(cString: text) + "]"
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
        var discontinuities = 0
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
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuities += 1
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
                    mediaSequence: segSeq,
                    discontinuity: discontinuities
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
    fileprivate enum RangeSource: Sendable {
        case tagged(HTTPClient.Edition)
        case snapshot(Data)

        func observe(in renditions: RenditionEditions, key: String) async throws {
            switch self {
            case .tagged(let edition): try await renditions.observe(key, edition: edition)
            case .snapshot(let data): try await renditions.observe(key, digest: SHA256.hash(data: data))
            }
        }

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

    /// Evidence shared by all HLS renditions of one output, never by independent downloads.
    /// Keep validators and hashes, not the media bodies of a completed rendition.
    public actor RenditionEditions {
        private var seen: [String: (HTTPClient.Edition?, SHA256.Digest?)] = [:]

        fileprivate func observe(_ key: String, edition: HTTPClient.Edition? = nil, digest: SHA256.Digest? = nil) throws {
            if let (original, hash) = seen[key] {
                if let hash, let digest {
                    guard hash == digest else { throw HTTPError.rangeUnsupported }
                } else {
                    guard let original, original == edition else { throw HTTPError.rangeUnsupported }
                }
            } else {
                seen[key] = (edition, digest)
            }
        }

        /// What an earlier rendition used to prove one edition of this resource.
        fileprivate func evidence(_ key: String) -> (edition: HTTPClient.Edition?, digest: SHA256.Digest?)? {
            seen[key]
        }
    }

    // A resource that an earlier rendition proved by its ETag must give that ETag again.
    // Otherwise, several spellings must give the same complete copy.
    private static func pin(_ key: String, urls: [String], sources: inout [String: RangeSource],
                            client: HTTPClient, headers: [String: String]?, renditions: RenditionEditions?) async throws {
        guard urls.contains(where: { sources[$0] == nil }) else { return }
        let earlier = await renditions?.evidence(key)
        let tagged = earlier.map { $0.edition != nil } ?? (urls.count == 1)
        var first: SHA256.Digest?
        for url in urls {
            let source: RangeSource
            if let saved = sources[url] {
                if renditions != nil { continue } // This source already supplied its evidence.
                source = saved
            } else if tagged {
                source = try await RangeSource.open(url, client: client, headers: headers)
            } else {
                source = .snapshot(try await RangeSource.snapshotOf(url, client: client, headers: headers))
            }
            if let renditions {
                try await source.observe(in: renditions, key: key)
            } else if urls.count > 1, case .snapshot(let copy) = source {
                let digest = SHA256.hash(data: copy)
                if let first, digest != first { throw HTTPError.rangeUnsupported }
                first = digest
            }
            sources[url] = source
        }
    }

    /// The playlist and bytes that supplied the clock for a paired rendition.
    public struct SectionOrigin: Sendable {
        fileprivate let playlist: HLSVals.MediaPlaylist
        fileprivate let finalURL: URL
        fileprivate var initialization: Data?
        fileprivate var first: Data?
        fileprivate var key: Data?
        fileprivate var sources: [String: RangeSource] = [:]
        var zero: SectionTimeBase?
    }

    private static func fetchPart(_ url: String, range: ByteRange?, client: HTTPClient, headers: [String: String]?, source: RangeSource? = nil, renditions: RenditionEditions? = nil) async throws -> Data {
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
        if source == nil, let renditions {
            try await renditions.observe(resourceKey(url), edition: HTTPClient.edition(response), digest: SHA256.hash(data: data))
        }
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
        renditions: RenditionEditions? = nil,
        findZero: Bool = true,
        prepared: SectionOrigin? = nil,
        shouldStopLive: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (_ downloaded: Int64, _ estTotal: Int64, _ fraction: Double, _ recordedSec: Double) -> Void)? = nil
    ) async throws -> (isFMP4: Bool, duration: Double, startTime: Double, zero: SectionTimeBase?) {
        let pl: HLSVals.MediaPlaylist, finalURL: URL
        if let prepared {
            (pl, finalURL) = (prepared.playlist, prepared.finalURL)
        } else {
            let (text, url) = try await client.fetchText(url: playlistURL, headers: headers)
            (pl, finalURL) = (parseMediaPlaylist(text, baseURL: url), url)
        }

        if pl.isLive && section == nil {
            let (isFMP4, recorded) = try await recordLiveStream(
                client: client,
                playlistURL: finalURL.absoluteString,
                initialPlaylist: pl,
                destination: destination,
                headers: headers,
                renditions: renditions,
                shouldStop: shouldStopLive,
                onProgress: onProgress
            )
            return (isFMP4, recorded, 0, nil)
        }

        // Filter segments if section range was requested. The demuxers start the saved timeline
        // at 0, so the caller needs the stream time where the first kept segment starts.
        var selected = pl.segments
        var startTime: Double = 0
        var preceding: (segment: HLSVals.Segment, start: Double)?
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
                    // but only after finding a segment with media inside the section. A
                    // segment after a discontinuity has its own clock, so it gets no preroll.
                    let previous = index > 0 ? pl.segments[index - 1] : nil
                    if let previous, previous.discontinuity == seg.discontinuity {
                        if segStart == start {
                            filtered.append(previous)
                            base = previousStart
                        } else if pl.initURL != nil {
                            preceding = (previous, Double(previousStart.description)!)
                        }
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

        // A resource that the selection uses more than once must give one edition. A resource
        // with a byte range is pinned (a strong ETag or a complete copy). A resource that is only
        // read whole keeps the digest of its first read, and every later read must give the same
        // bytes. `resourceKey` groups the spellings of one resource; requests use each spelling.
        // A pinned source serves only the URL that opened it, because an origin can route two
        // spellings that `resourceKey` joins to different objects.
        var seen = Set<String>(), repeated = Set<String>(), ranged = Set<String>()
        var spellings: [String: [String]] = [:]
        func note(_ url: String, ranged isRanged: Bool) {
            let key = resourceKey(url)
            if !seen.insert(key).inserted { repeated.insert(key) }
            if spellings[key]?.contains(url) != true { spellings[key, default: []].append(url) }
            if isRanged { ranged.insert(key) }
        }
        // Section times count from the first presented time of the stream, which the first
        // segment gives. That time compares with the selection only on the same timeline.
        let origin = findZero && section != nil && selected.first?.index != 0
            && pl.segments.first?.discontinuity == selected.first?.discontinuity ? pl.segments.first : nil
        let initKey = pl.initURL.map(resourceKey)
        // An origin stored in the init's resource close to the init is read with the init in
        // one response, so that the two reads need no pinned edition.
        var joined: ByteRange?
        if let origin, let initRange = pl.initByteRange, let range = origin.byteRange, origin.url == pl.initURL {
            let start = min(initRange.start, range.start), end = max(initRange.end, range.end)
            let gap = max(initRange.start, range.start) - min(initRange.end, range.end)
            if gap <= 65_537 { joined = ByteRange(start: start, end: end) }
        }
        if let url = pl.initURL { note(url, ranged: pl.initByteRange != nil) }
        if let origin, joined == nil { note(origin.url, ranged: origin.byteRange != nil) }
        for seg in selected { note(seg.url, ranged: seg.byteRange != nil) }
        // A range used only once here may occur again in the other rendition.
        func pinnedKeys() -> Set<String> { renditions == nil ? repeated.intersection(ranged) : ranged }
        var sources = prepared?.sources ?? [:]
        func pinSelection(_ key: String) async throws {
            try await pin(key, urls: spellings[key] ?? [], sources: &sources,
                          client: client, headers: headers, renditions: renditions)
        }
        func readInit(_ url: String) async throws -> (initial: Data, origin: Data?) {
            guard let joined, let initRange = pl.initByteRange, let range = origin?.byteRange else {
                return (try await fetchPart(url, range: pl.initByteRange, client: client, headers: headers, source: sources[url], renditions: renditions), nil)
            }
            let both = try await fetchPart(url, range: joined, client: client, headers: headers, source: sources[url], renditions: renditions)
            func slice(_ part: ByteRange) -> Data { both.subdata(in: Int(part.start - joined.start)..<Int(part.end - joined.start + 1)) }
            return (slice(initRange), slice(range))
        }
        var initData: Data?, originData: Data?
        if let prepared, prepared.first != nil {
            initData = prepared.initialization
        } else if let initU = pl.initURL {
            if let initKey, pinnedKeys().contains(initKey) { try await pinSelection(initKey) }
            (initData, originData) = try await readInit(initU)
        }
        // Muxed media keeps the previous segment, so that the sound before the first picture
        // of the selection is there.
        if let initData, let preceding, MP4Muxer.hasPictureAndSound(initData) {
            selected.insert(preceding.segment, at: 0)
            startTime = preceding.start
            if preceding.segment.index != origin?.index {
                note(preceding.segment.url, ranged: preceding.segment.byteRange != nil)
            }
            // Preroll can add a range or a new spelling of the init's resource. Reopen
            // all its spellings together and check that the earlier reads still agree.
            if let initKey, let initU = pl.initURL, pinnedKeys().contains(initKey),
               let urls = spellings[initKey], urls.contains(where: { sources[$0] == nil }) {
                if renditions == nil {
                    for url in urls { sources.removeValue(forKey: url) }
                }
                try await pinSelection(initKey)
                let pinnedInit = try await readInit(initU)
                guard pinnedInit.initial == initData, pinnedInit.origin == originData else { throw HTTPError.rangeUnsupported }
            }
        }
        var clockOnly = false
        if let origin, selected.first?.index != origin.index {
            selected.insert(origin, at: 0)
            clockOnly = true
        }
        let shared = pinnedKeys()
        let wholeReads = WholeReads(renditions == nil ? repeated.subtracting(shared) : [])
        if let initKey, let initData { try await wholeReads.check(initKey, initData) }
        for key in shared { try await pinSelection(key) }
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

        let firstKey = prepared?.key
        let firstKeyURL = prepared?.playlist.segments.first?.keyURL
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
                        let resource = resourceKey(seg.url)
                        var raw: Data
                        if pos == 0, seg.index == origin?.index, let originData {
                            raw = originData
                        } else if seg.index == 0, let first = prepared?.first {
                            raw = first
                        } else {
                            raw = try await fetchPart(seg.url, range: seg.byteRange, client: client, headers: headers, source: pinned[seg.url], renditions: renditions)
                        }
                        try await wholeReads.check(resource, raw)
                        if let kurl = seg.keyURL {
                            try Task.checkCancellation()
                            let key: Data
                            if let firstKey, kurl == firstKeyURL {
                                key = firstKey
                            } else {
                                key = try await keyStore.get(kurl, client: client, headers: headers)
                            }
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
        var zero = prepared?.zero
        for pos in 0..<selected.count {
            try Task.checkCancellation()
            if !clockOnly || pos > 0 { totalDur += selected[pos].duration }
            let segFile = segWorkDir.appendingPathComponent(String(format: "%06d.seg", pos))
            let d = try Data(contentsOf: segFile, options: .mappedIfSafe)
            if findZero, pos == 0, section != nil, selected[0].index == 0 {
                // Media that cannot be timed keeps the playlist clock (`startTime`).
                zero = try? presentationStart(of: d, initialization: initData)
            }
            if clockOnly && pos == 0 { continue }
            if firstBytes.isEmpty { firstBytes = d.prefix(16) }
            try fh.write(contentsOf: d)
        }
        try fh.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partOut, to: destination)

        let isFMP4 = initData != nil || (firstBytes.count >= 8 && String(decoding: firstBytes[4..<8], as: UTF8.self) == "ftyp") || (firstBytes.first != 0x47)
        return (isFMP4, totalDur, startTime, zero)
    }

    /// The first presented time of one segment over its tracks, as FFmpeg reports `start_time`.
    private static func presentationStart(of segment: Data, initialization: Data?) throws -> SectionTimeBase {
        if let initialization { return try MP4Muxer.presentationStart(of: segment, initialization: initialization) }
        guard segment.first == 0x47 else { throw HTTPError.rangeUnsupported }
        let (tracks, starts) = TSDemuxer.demux(segment)
        return try MP4Muxer.presentationStart(of: tracks, starts: starts)
    }

    /// Read the sound's clock before choosing the clip. Keep the playlist and bytes
    /// so that the later fetch uses the same edition and does not repeat these reads.
    static func prepareSection(client: HTTPClient, playlistURL: String, headers: [String: String]?,
                               renditions: RenditionEditions) async throws -> SectionOrigin {
        let (text, finalURL) = try await client.fetchText(url: playlistURL, headers: headers)
        let pl = parseMediaPlaylist(text, baseURL: finalURL)
        var origin = SectionOrigin(playlist: pl, finalURL: finalURL)
        guard !pl.isLive, let first = pl.segments.first, pl.segments.last?.discontinuity == 0 else { return origin }

        if let url = pl.initURL, resourceKey(url) == resourceKey(first.url), pl.initByteRange != nil || first.byteRange != nil {
            // Even a whole read must use the pinned edition when it shares a ranged resource.
            try await pin(resourceKey(url), urls: url == first.url ? [url] : [url, first.url],
                          sources: &origin.sources, client: client, headers: headers, renditions: renditions)
        }
        func read(_ url: String, _ range: ByteRange?) async throws -> Data {
            if range != nil, origin.sources[url] == nil {
                try await pin(resourceKey(url), urls: [url], sources: &origin.sources,
                              client: client, headers: headers, renditions: renditions)
            }
            return try await fetchPart(url, range: range, client: client, headers: headers, source: origin.sources[url], renditions: renditions)
        }
        if let url = pl.initURL { origin.initialization = try await read(url, pl.initByteRange) }
        let raw = try await read(first.url, first.byteRange)
        origin.first = raw
        var data = raw
        if let keyURL = first.keyURL {
            let (key, _) = try await client.fetchData(url: keyURL, headers: headers)
            origin.key = key
            data = try decryptAES128(data: raw, key: key, iv: first.iv, sequence: first.mediaSequence)
        }
        origin.zero = try? presentationStart(of: data, initialization: origin.initialization)
        return origin
    }

    private static func recordLiveStream(
        client: HTTPClient,
        playlistURL: String,
        initialPlaylist: HLSVals.MediaPlaylist,
        destination: URL,
        headers: [String: String]?,
        renditions: RenditionEditions?,
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

        // Every resource keeps its edition: a strong ETag, a complete copy, or a digest of the
        // complete body. An EVENT playlist can list every past URI, so copies are kept only
        // for byte ranges and only up to `snapshotBudget` bytes in total. An evicted copy and a
        // whole read leave a digest, and a later range of that resource compares a new complete
        // copy. The maps use `resourceKey`; requests use the URL that the playlist wrote. The
        // first spelling of a resource owns its entry. An origin can route two spellings that
        // `resourceKey` joins to different objects, so another spelling reads a complete copy,
        // and that copy must match the edition of the first spelling.
        var liveSources: [String: RangeSource] = [:]
        var digests: [String: SHA256.Digest] = [:]
        var snapshotOrder: [String] = []
        var snapshotBytes = 0
        let snapshotBudget = 64 << 20
        func evict(_ key: String) {
            guard case .snapshot(let bytes)? = liveSources[key] else { return }
            liveSources.removeValue(forKey: key)
            digests[key] = SHA256.hash(data: bytes)
            snapshotBytes -= bytes.count
            snapshotOrder.removeAll { $0 == key }
        }
        func keep(_ key: String, _ source: RangeSource) {
            liveSources[key] = source
            guard case .snapshot(let bytes) = source else { return }
            snapshotOrder.append(key)
            snapshotBytes += bytes.count
            // Older copies go first. The newest copy stays until it has served its range.
            while snapshotBytes > snapshotBudget, snapshotOrder.count > 1 { evict(snapshotOrder[0]) }
        }
        var firstSpelling: [String: String] = [:]
        var taggedDigests: [String: SHA256.Digest] = [:]
        func editionDigest(_ key: String, first: String) async throws -> SHA256.Digest {
            if let digest = digests[key] ?? taggedDigests[key] { return digest }
            switch liveSources[key] {
            case .snapshot(let bytes)?: return SHA256.hash(data: bytes)
            case .tagged?:
                let whole = try await fetchPart(first, range: nil, client: client, headers: headers, source: liveSources[key])
                let digest = SHA256.hash(data: whole)
                taggedDigests[key] = digest
                return digest
            case nil: throw HTTPError.rangeUnsupported
            }
        }
        func livePart(_ url: String, range: ByteRange?) async throws -> Data {
            let key = resourceKey(url)
            let first = firstSpelling[key] ?? url
            firstSpelling[key] = first
            if url != first {
                let expected = try await editionDigest(key, first: first)
                let fresh = try await RangeSource.snapshotOf(url, client: client, headers: headers)
                guard SHA256.hash(data: fresh) == expected else { throw HTTPError.rangeUnsupported }
                return try await fetchPart(url, range: range, client: client, headers: headers, source: .snapshot(fresh))
            }
            if let digest = digests[key] {
                // Compare one complete response rather than append bytes from a different edition.
                let fresh = try await RangeSource.snapshotOf(url, client: client, headers: headers)
                guard SHA256.hash(data: fresh) == digest else { throw HTTPError.rangeUnsupported }
                guard range != nil else { return fresh }
                digests.removeValue(forKey: key)
                keep(key, .snapshot(fresh))
            } else if liveSources[key] == nil {
                guard range != nil else {
                    let (data, response) = try await client.fetchData(url: url, headers: headers)
                    let edition = HTTPClient.edition(response)
                    let digest = edition == nil || renditions != nil ? SHA256.hash(data: data) : nil
                    try await renditions?.observe(key, edition: edition, digest: digest)
                    if let edition { liveSources[key] = .tagged(edition) } else { digests[key] = digest }
                    return data
                }
                let source = try await RangeSource.open(url, client: client, headers: headers)
                if let renditions { try await source.observe(in: renditions, key: key) }
                keep(key, source)
            }
            let part = try await fetchPart(url, range: range, client: client, headers: headers, source: liveSources[key])
            // A copy that alone exceeds the budget is not kept after it has served its range.
            if snapshotBytes > snapshotBudget { evict(key) }
            return part
        }
        var currentPL = initialPlaylist
        var firstIteration = true

        while !(shouldStop?() ?? false) && !Task.isCancelled {
            if !firstIteration {
                let (txt, u) = try await client.fetchText(url: playlistURL, headers: headers)
                currentPL = parseMediaPlaylist(txt, baseURL: u)
                if !snapshotOrder.isEmpty {
                    var active = Set(currentPL.segments.map { resourceKey($0.url) })
                    if let url = currentPL.initURL { active.insert(resourceKey(url)) }
                    for key in snapshotOrder where !active.contains(key) { evict(key) }
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
