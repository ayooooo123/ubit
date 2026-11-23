import Foundation
import CryptoKit

public struct SponsorSegment: Sendable {
    public var category: String
    public var start: Double
    public var end: Double
}

public enum SponsorAndSubtitles {

    public static func parseCategories(_ spec: String) -> [String] {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty || s == "default" {
            return ["sponsor", "selfpromo", "interaction"]
        }
        if s == "all" {
            return ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic", "filler"]
        }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Queries SponsorBlock using k-anonymous 4-hex SHA-256 videoID prefix so the full videoID is not leaked in the URL path.
    public static func fetchSponsorSegments(
        client: HTTPClient,
        videoID: String,
        categories: [String]
    ) async throws -> [SponsorSegment] {
        guard !videoID.isEmpty, !categories.isEmpty else { return [] }
        let digest = SHA256.hash(data: Data(videoID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(4))
        guard let catJSON = try? JSONSerialization.data(withJSONObject: categories),
              let catParam = String(data: catJSON, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let url = "https://sponsor.ajay.app/api/skipSegments/\(prefix)?categories=\(catParam)"
        guard let any = try await ExtractorUtils.optionalRequest({ try await client.fetchJSON(url: url, includeCookies: false) }) as? [[String: Any]] else {
            return []
        }
        var out: [SponsorSegment] = []
        for entry in any where (entry["videoID"] as? String) == videoID {
            guard let segs = entry["segments"] as? [[String: Any]] else { continue }
            for s in segs {
                guard let pair = s["segment"] as? [Double], pair.count == 2, pair[1] > pair[0] else { continue }
                let cat = (s["category"] as? String) ?? "sponsor"
                out.append(SponsorSegment(category: cat, start: pair[0], end: pair[1]))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    public static func chaptersFromDescription(_ description: String?, totalDuration: Double?) -> [Chapter] {
        guard let description, !description.isEmpty else { return [] }
        let pattern = "(?:^|\\s)(\\d{1,2}:\\d{2}(?::\\d{2})?)\\s+[-–—:|]?\\s*(.+)$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var rawPoints: [(time: Double, title: String)] = []
        for line in description.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let m = re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let r1 = Range(m.range(at: 1), in: trimmed),
                  let r2 = Range(m.range(at: 2), in: trimmed),
                  let sec = SectionRange.parseTimestamp(String(trimmed[r1])) else { continue }
            let title = String(trimmed[r2]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|[]()"))
            if !title.isEmpty {
                rawPoints.append((sec, title))
            }
        }
        guard rawPoints.count >= 2 else { return [] }
        rawPoints.sort { $0.time < $1.time }
        var chapters: [Chapter] = []
        for i in 0..<rawPoints.count {
            let end = (i + 1 < rawPoints.count) ? rawPoints[i + 1].time : (totalDuration ?? (rawPoints[i].time + 60))
            if end > rawPoints[i].time {
                chapters.append(Chapter(title: rawPoints[i].title, startTime: rawPoints[i].time, endTime: end))
            }
        }
        return chapters
    }

    public static func squeezeCues(
        _ cues: [(start: Double, end: Double, text: String)],
        removed: [(start: Double, end: Double)]
    ) -> [(start: Double, end: Double, text: String)] {
        guard !removed.isEmpty else { return cues }
        func mapTime(_ t: Double) -> Double {
            var shift = 0.0
            for r in removed {
                if t >= r.end { shift += (r.end - r.start) }
                else if t > r.start { shift += (t - r.start) }
            }
            return max(0, t - shift)
        }
        return cues.compactMap { c in
            let ns = mapTime(c.start)
            let ne = mapTime(c.end)
            return ne > ns + 0.05 ? (ns, ne, c.text) : nil
        }
    }

    public static func squeezeChapters(_ chapters: [Chapter], removed: [(start: Double, end: Double)]) -> [Chapter] {
        let cues = squeezeCues(chapters.map { ($0.startTime, $0.endTime, $0.title) }, removed: removed)
        return cues.map { Chapter(title: $0.text, startTime: $0.start, endTime: $0.end) }
    }

    // MARK: - Subtitle Parsing (WebVTT, SRT, YouTube XML/SRV3) & VTT Formatting

    public static func parseSubtitleCues(_ raw: String) -> [(start: Double, end: Double, text: String)] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<timedtext") || trimmed.hasPrefix("<transcript") {
            return parseXMLSubtitles(trimmed)
        }

        var out: [(Double, Double, String)] = []
        let normalized = trimmed.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let arrowIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timingLine = lines[arrowIdx]
            let parts = timingLine.components(separatedBy: "-->")
            guard parts.count >= 2 else { continue }
            let lhs = parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            let rhs = (parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? "").replacingOccurrences(of: ",", with: ".")
            guard let s = SectionRange.parseTimestamp(lhs), let e = SectionRange.parseTimestamp(rhs), e > s else { continue }
            let textLines = lines[(arrowIdx + 1)...].map { stripTags($0) }.filter { !$0.isEmpty }
            if !textLines.isEmpty {
                out.append((s, e, textLines.joined(separator: "\n")))
            }
        }
        return out
    }

    private static func parseXMLSubtitles(_ xml: String) -> [(Double, Double, String)] {
        // Supports YouTube <text start="1.23" dur="4.56"> and <p t="1230" d="4560">
        var out: [(Double, Double, String)] = []
        if let re = try? NSRegularExpression(pattern: "<(?:text|p)\\s+([^>]+)>([\\s\\S]*?)</(?:text|p)>") {
            for m in re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                guard let aR = Range(m.range(at: 1), in: xml), let tR = Range(m.range(at: 2), in: xml) else { continue }
                let attrs = String(xml[aR])
                let body = decodeHTMLEntities(stripTags(String(xml[tR]))).trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty { continue }
                if let tMs = attrDouble(attrs, "t"), let dMs = attrDouble(attrs, "d") {
                    out.append((tMs / 1000.0, (tMs + dMs) / 1000.0, body))
                } else if let st = attrDouble(attrs, "start") {
                    let dur = attrDouble(attrs, "dur") ?? 2.5
                    out.append((st, st + dur, body))
                }
            }
        }
        return out
    }

    private static func attrDouble(_ attrs: String, _ name: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)=\"([0-9.]+)\""),
              let m = re.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
              let r = Range(m.range(at: 1), in: attrs) else { return nil }
        return Double(attrs[r])
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// Named references for the whitespace and punctuation used by captions and notices.
    private static let namedEntities: [Substring: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "AMP": "&", "LT": "<", "GT": ">", "QUOT": "\"",
        "nbsp": "\u{A0}", "NonBreakingSpace": "\u{A0}", "Tab": "\t", "NewLine": "\n",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "emsp13": "\u{2004}", "emsp14": "\u{2005}",
        "numsp": "\u{2007}", "puncsp": "\u{2008}", "thinsp": "\u{2009}", "ThinSpace": "\u{2009}",
        "hairsp": "\u{200A}", "VeryThinSpace": "\u{200A}", "MediumSpace": "\u{205F}",
        "rsquo": "’", "rsquor": "’", "CloseCurlyQuote": "’", "lsquo": "‘", "OpenCurlyQuote": "‘",
        "rdquo": "”", "ldquo": "“", "ndash": "–", "mdash": "—", "hellip": "…",
        "period": ".", "excl": "!", "quest": "?",
    ]

    /// Decode once. HTML numeric references start with ASCII digits, never a sign.
    public static func decodeHTMLEntities(_ s: String) -> String {
        let bytes = s.utf8
        guard var amp = bytes.firstIndex(of: 0x26) else { return s }
        var out = String(s[..<amp])
        while amp < bytes.endIndex {
            let start = bytes.index(after: amp)
            var end = start
            var scalar: Unicode.Scalar?
            if end < bytes.endIndex, bytes[end] == 0x23 {
                bytes.formIndex(after: &end)
                let hex = end < bytes.endIndex && (bytes[end] == 0x78 || bytes[end] == 0x58)
                if hex { bytes.formIndex(after: &end) }
                let digits = end
                while end < bytes.endIndex {
                    let c = bytes[end]
                    guard (0x30...0x39).contains(c) || (hex && (0x41...0x46).contains(c & 0xDF)) else { break }
                    bytes.formIndex(after: &end)
                }
                if end > digits, let code = UInt32(s[digits..<end], radix: hex ? 16 : 10) {
                    // HTML maps these two Windows-1252 values to their Unicode quotes.
                    scalar = Unicode.Scalar(code == 145 ? 0x2018 : code == 146 ? 0x2019 : code)
                    if end < bytes.endIndex, bytes[end] == 0x3B { bytes.formIndex(after: &end) }
                }
            } else if let semicolon = bytes[start...].prefix(17).firstIndex(of: 0x3B),
                      let named = namedEntities[s[start..<semicolon]] {
                scalar = named
                end = bytes.index(after: semicolon)
            } else if bytes[start...].starts(with: "nbsp".utf8) {
                scalar = "\u{A0}"
                end = bytes.index(start, offsetBy: 4)
            }
            if let scalar {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("&")
                end = start
            }
            amp = bytes[end...].firstIndex(of: 0x26) ?? bytes.endIndex
            out.append(contentsOf: s[end..<amp])
        }
        return out
    }

    public static func formatWebVTT(_ cues: [(start: Double, end: Double, text: String)]) -> String {
        func ts(_ sec: Double) -> String {
            let ms = Int((max(0, sec) * 1000).rounded())
            let h = ms / 3_600_000
            let m = (ms % 3_600_000) / 60_000
            let s = (ms % 60_000) / 1000
            let f = ms % 1000
            return String(format: "%02d:%02d:%02d.%03d", h, m, s, f)
        }
        var lines = ["WEBVTT", ""]
        for c in cues {
            lines.append("\(ts(c.start)) --> \(ts(c.end))")
            lines.append(c.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
