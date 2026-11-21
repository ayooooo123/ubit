import Foundation
import SQLite3

public struct CookieEntry: Codable, Sendable {
    public var domain: String
    public var includeSubdomains: Bool
    public var path: String
    public var secure: Bool
    public var expires: Int64
    public var name: String
    public var value: String

    public init(domain: String, includeSubdomains: Bool = true, path: String = "/", secure: Bool = false, expires: Int64 = 0, name: String, value: String) {
        self.domain = domain
        self.includeSubdomains = includeSubdomains
        self.path = path
        self.secure = secure
        self.expires = expires
        self.name = name
        self.value = value
    }

    public func matches(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let dom = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostMatches = (host == dom) || (includeSubdomains && host.hasSuffix("." + dom))
        guard hostMatches else { return false }
        if secure && url.scheme?.lowercased() != "https" { return false }
        let urlPath = url.path.isEmpty ? "/" : url.path
        if !urlPath.hasPrefix(path) { return false }
        if expires > 0 && Double(expires) < Date().timeIntervalSince1970 { return false }
        return true
    }
}

public final class CookieVault: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CookieEntry] = []

    public init(entries: [CookieEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    public func all() -> [CookieEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func cookieHeader(for url: URL) -> String? {
        lock.lock()
        let matching = entries.filter { $0.matches(url: url) }
        lock.unlock()
        guard !matching.isEmpty else { return nil }
        var seen = Set<String>()
        var pairs: [String] = []
        // Prefer more specific path first
        for c in matching.sorted(by: { $0.path.count > $1.path.count }) {
            if seen.insert(c.name).inserted {
                pairs.append("\(c.name)=\(c.value)")
            }
        }
        return pairs.joined(separator: "; ")
    }

    public func cookieValue(named name: String, forDomain domainSuffix: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let target = domainSuffix.lowercased()
        return entries.first {
            $0.name == name && $0.domain.lowercased().contains(target)
        }?.value
    }

    /// Loads cookies for a CLI/API source. Recognised browsers are imported directly; an
    /// unsupported browser name throws instead of quietly returning an empty vault, because an
    /// empty vault looks exactly like "the site rejected my session" when nothing was ever read.
    public static func load(source: String) throws -> CookieVault {
        let s = source.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.lowercased() == "none" {
            return CookieVault()
        }
        if s.lowercased() == "builtin" {
            if FileManager.default.fileExists(atPath: AppPaths.cookiesFile.path) {
                return parseNetscapeFile(at: AppPaths.cookiesFile)
            }
            return CookieVault()
        }
        if s.lowercased() == "firefox" {
            return loadFirefoxCookies()
        }
        if s.lowercased() == "safari" {
            return try loadSafariCookies()
        }
        if Self.chromiumFamily.contains(s.lowercased()) {
            throw CookieError.browserNotSupported(s)
        }
        let expanded = (s as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return parseNetscapeFile(at: URL(fileURLWithPath: expanded))
        }
        // Check workspace sample cookies fallback if explicitly passed relative path
        let rel = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(s)
        if FileManager.default.fileExists(atPath: rel.path) {
            return parseNetscapeFile(at: rel)
        }
        return CookieVault()
    }

    private static let chromiumFamily = ["chrome", "chromium", "brave", "edge", "vivaldi", "opera"]

    /// Safari stores cookies in an unencrypted `Cookies.binarycookies` blob, so importing its
    /// session needs no keychain access and no Chromium-style AES unwrapping. macOS TCC still
    /// guards the container, so an unreadable file is reported instead of returning an empty vault.
    /// `UBIT_SAFARI_COOKIES` overrides the path (used by the test fixture).
    public static func loadSafariCookies() throws -> CookieVault {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["UBIT_SAFARI_COOKIES"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        candidates.append(NSHomeDirectory() + "/Library/Cookies/Cookies.binarycookies")

        var foundButUnreadable: String?
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let entries = SafariBinaryCookies.parse(data)
                if !entries.isEmpty { return CookieVault(entries: entries) }
                if foundButUnreadable == nil { foundButUnreadable = path }
            } catch {
                // TCC denies reading another app's container without Full Disk Access.
                throw CookieError.unreadable(path, error.localizedDescription)
            }
        }
        if let path = foundButUnreadable {
            throw CookieError.empty(path)
        }
        throw CookieError.notFound("Safari")
    }

    public static func parseNetscapeFile(at url: URL) -> CookieVault {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return CookieVault() }
        var parsed: [CookieEntry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#HttpOnly_") {
                line = String(line.dropFirst("#HttpOnly_".count))
            } else if line.hasPrefix("#") {
                continue
            }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }
            let domain = parts[0]
            let includeSub = parts[1].uppercased() == "TRUE" || domain.hasPrefix(".")
            let path = parts[2]
            let secure = parts[3].uppercased() == "TRUE"
            let expires = Int64(parts[4]) ?? 0
            let name = parts[5]
            let value = parts[6]
            parsed.append(CookieEntry(
                domain: domain,
                includeSubdomains: includeSub,
                path: path,
                secure: secure,
                expires: expires,
                name: name,
                value: value
            ))
        }
        return CookieVault(entries: parsed)
    }

    public static func writeNetscapeFile(_ cookies: [HTTPCookie], to url: URL) throws {
        try AppPaths.ensureAppSupport()
        var lines = ["# Netscape HTTP Cookie File", "# Generated by uBit"]
        for c in cookies {
            let sub = c.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let sec = c.isSecure ? "TRUE" : "FALSE"
            let exp = Int64(c.expiresDate?.timeIntervalSince1970 ?? Date().addingTimeInterval(86400 * 30).timeIntervalSince1970)
            lines.append("\(c.domain)\t\(sub)\t\(c.path)\t\(sec)\t\(exp)\t\(c.name)\t\(c.value)")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func loadFirefoxCookies() -> CookieVault {
        let profilesDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Firefox/Profiles")
        guard let subdirs = try? FileManager.default.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil) else {
            return CookieVault()
        }
        for dir in subdirs {
            let dbPath = dir.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: dbPath.path) else { continue }
            let tmpCopy = FileManager.default.temporaryDirectory.appendingPathComponent("ubit-ff-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: tmpCopy) }
            guard (try? FileManager.default.copyItem(at: dbPath, to: tmpCopy)) != nil else { continue }

            var db: OpaquePointer?
            guard sqlite3_open_v2(tmpCopy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            let sql = "SELECT host, path, isSecure, expiry, name, value FROM moz_cookies"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            defer { sqlite3_finalize(stmt) }

            var out: [CookieEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let h = sqlite3_column_text(stmt, 0),
                      let p = sqlite3_column_text(stmt, 1),
                      let n = sqlite3_column_text(stmt, 4),
                      let v = sqlite3_column_text(stmt, 5) else { continue }
                let host = String(cString: h)
                out.append(CookieEntry(
                    domain: host,
                    includeSubdomains: host.hasPrefix("."),
                    path: String(cString: p),
                    secure: sqlite3_column_int(stmt, 2) != 0,
                    expires: sqlite3_column_int64(stmt, 3),
                    name: String(cString: n),
                    value: String(cString: v)
                ))
            }
            if !out.isEmpty { return CookieVault(entries: out) }
        }
        return CookieVault()
    }
}

public enum CookieError: LocalizedError {
    case browserNotSupported(String)
    case unreadable(String, String)
    case empty(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .browserNotSupported(let name):
            return "\(name) cookies need its keychain password and an AES unwrap, which uBit does not do. Use --cookies-from-browser safari or firefox, or export a cookies.txt."
        case .unreadable(let path, let reason):
            return "Cannot read \(path) (\(reason)). Grant uBit Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then run it again."
        case .empty(let path):
            return "\(path) parsed to zero cookies. Open Safari, sign in to the site, quit Safari so it flushes cookies, then retry."
        case .notFound(let browser):
            return "No \(browser) cookie file found on this Mac."
        }
    }
}

/// Minimal reader for Safari's `Cookies.binarycookies`: big-endian page table, little-endian page
/// records, NUL-terminated strings, double expiry in Apple absolute time (2001-01-01).
enum SafariBinaryCookies {
    private static let appleEpochOffset: Double = 978_307_200  // 2001-01-01 in Unix seconds

    static func parse(_ data: Data) -> [CookieEntry] {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0] == 0x63, bytes[1] == 0x6F, bytes[2] == 0x6F, bytes[3] == 0x6B else {
            return []   // "cook"
        }
        let pageCount = Int(beU32(bytes, 4))
        guard pageCount > 0, pageCount < 10_000 else { return [] }

        // No offset table: the header stores page sizes, and the pages follow it back to back.
        var sizes: [Int] = []
        var cursor = 8
        for _ in 0..<pageCount {
            guard cursor + 4 <= bytes.count else { return [] }
            sizes.append(Int(beU32(bytes, cursor)))
            cursor += 4
        }

        var out: [CookieEntry] = []
        var pageStart = cursor
        for size in sizes {
            defer { pageStart += size }
            guard size > 8, pageStart + size <= bytes.count else { continue }
            let count = Int(leU32(bytes, pageStart + 4))
            guard count > 0, count < 100_000 else { continue }
            for i in 0..<count {
                let slot = pageStart + 8 + i * 4
                guard slot + 4 <= bytes.count else { break }
                let record = pageStart + Int(leU32(bytes, slot))
                if let entry = cookie(at: record, in: bytes) { out.append(entry) }
            }
        }
        return out
    }

    private static func cookie(at record: Int, in bytes: [UInt8]) -> CookieEntry? {
        // 4 size, 4 ?, 4 flags, 4 ?, 4 url, 4 name, 4 path, 4 value, 4 comment, 4 commentURL,
        // 8 expiry, 8 creation  == 56 bytes before the NUL-terminated strings.
        guard record >= 0, record + 56 <= bytes.count else { return nil }
        let size = Int(leU32(bytes, record))
        guard size > 56, record + size <= bytes.count else { return nil }

        let flags = leU32(bytes, record + 8)
        func string(_ relOffset: UInt32) -> String? {
            let start = record + Int(relOffset)
            guard start >= record, start < record + size, start < bytes.count else { return nil }
            var end = start
            while end < record + size, end < bytes.count, bytes[end] != 0 { end += 1 }
            guard end > start else { return nil }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        guard let domain = string(leU32(bytes, record + 16)),
              let name = string(leU32(bytes, record + 20)),
              let path = string(leU32(bytes, record + 24)),
              let value = string(leU32(bytes, record + 28)),
              !name.isEmpty, !domain.isEmpty else { return nil }

        let macExpiry = leDouble(bytes, record + 40)
        let unix = macExpiry > 0 ? Int64(macExpiry + appleEpochOffset) : 0
        if unix > 0 && Double(unix) < Date().timeIntervalSince1970 { return nil }

        return CookieEntry(
            domain: domain,
            includeSubdomains: domain.hasPrefix("."),
            path: path.isEmpty ? "/" : path,
            secure: (flags & 0x1) != 0,
            expires: unix,
            name: name,
            value: value
        )
    }

    private static func beU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private static func leU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func leDouble(_ b: [UInt8], _ o: Int) -> Double {
        guard o + 8 <= b.count else { return 0 }
        var raw: UInt64 = 0
        for i in (0..<8).reversed() { raw = (raw << 8) | UInt64(b[o + i]) }
        return Double(bitPattern: raw)
    }
}
