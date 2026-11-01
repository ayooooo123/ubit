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

    public static func load(source: String) -> CookieVault {
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
