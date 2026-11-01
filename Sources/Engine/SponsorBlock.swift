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
    ) async -> [SponsorSegment] {
        guard !videoID.isEmpty, !categories.isEmpty else { return [] }
        let digest = SHA256.hash(data: Data(videoID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(4))
        guard let catJSON = try? JSONSerialization.data(withJSONObject: categories),
              let catParam = String(data: catJSON, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let url = "https://sponsor.ajay.app/api/skipSegments/\(prefix)?categories=\(catParam)"
        guard let any = try? await client.fetchJSON(url: url, includeCookies: false) as? [[String: Any]] else {
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

    public static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&#x27;", with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
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
