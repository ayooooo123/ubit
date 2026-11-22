import Foundation
import CryptoKit

public enum HTTPError: LocalizedError {
    case badURL(String)
    case status(Int, String)
    case rangeUnsupported
    case incomplete(received: Int64, expected: Int64)
    case canceled
    /// The request failed before uBit could read its status, and the task metrics do not prove
    /// that no response had started. The response may have been a refusal.
    case noStatus(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Invalid URL: \(u)"
        case .status(let code, let u): return "HTTP \(code) from \(URL(string: u)?.host ?? u)"
        case .rangeUnsupported: return "Server stopped serving byte ranges"
        case .incomplete(let received, let expected):
            return "Incomplete download: received \(received) of \(expected) bytes"
        case .canceled: return "Canceled"
        case .noStatus(let u):
            return "No HTTP status from \(URL(string: u)?.host ?? u): the request failed before uBit could read the status, and the response may have been a refusal. uBit does not repeat the request."
        }
    }
}

public actor RateLimiter {
    private let bytesPerSec: Int64
    private var nextAllowedTime: TimeInterval = 0

    public init(bytesPerSec: Int64?) {
        self.bytesPerSec = bytesPerSec ?? 0
    }

    public func consume(_ bytes: Int) async throws {
        try Task.checkCancellation()
        guard bytesPerSec > 0, bytes > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = Double(bytes) / Double(bytesPerSec)
        let start = max(now, nextAllowedTime)
        nextAllowedTime = start + duration
        let delay = start - now
        if delay > 0.002 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

public struct ChunkStateFile: Codable, Sendable {
    public var totalSize: Int64
    public var resourceDigest: Data?
    public var etag: String?
    public var completed: [ByteRange]

    public mutating func addCompleted(_ range: ByteRange) {
        completed.append(range)
        completed.sort { $0.start < $1.start }
        var merged: [ByteRange] = []
        for r in completed {
            if let last = merged.last, r.start <= last.end + 1 {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        completed = merged
    }

    public var downloadedBytes: Int64 {
        completed.reduce(0) { $0 + $1.length }
    }

    public func missingRanges() -> [ByteRange] {
        guard totalSize > 0 else { return [] }
        var missing: [ByteRange] = []
        var cursor: Int64 = 0
        for r in completed.sorted(by: { $0.start < $1.start }) {
            if r.start > cursor {
                missing.append(ByteRange(start: cursor, end: r.start - 1))
            }
            cursor = max(cursor, r.end + 1)
        }
        if cursor < totalSize {
            missing.append(ByteRange(start: cursor, end: totalSize - 1))
        }
        return missing
    }
}

/// Coordinates dynamic work-stealing byte-range chunks across N concurrent HTTP workers.
private actor WorkStealingQueue {
    struct ActiveWorker {
        var currentPos: Int64
        var endPos: Int64
    }

    private var state: ChunkStateFile
    private let stateURL: URL
    private var pending: [ByteRange]
    private var active: [Int: ActiveWorker] = [:]
    private var nextID: Int = 1
    private var stopped = false
    private let minStealSize: Int64 = 512 * 1024 // 512 KB minimum split

    init(state: ChunkStateFile, stateURL: URL, initialSplits: Int) {
        self.state = state
        self.stateURL = stateURL
        var splitRanges: [ByteRange] = []
        let rawMissing = state.missingRanges()
        let totalMissing = rawMissing.reduce(0) { $0 + $1.length }
        let targetPiece = max(512 * 1024, totalMissing / Int64(max(1, initialSplits)))

        for r in rawMissing {
            var cur = r.start
            while cur <= r.end {
                let pieceEnd = min(r.end, cur + targetPiece - 1)
                splitRanges.append(ByteRange(start: cur, end: pieceEnd))
                cur = pieceEnd + 1
            }
        }
        self.pending = splitRanges
    }

    func claimWork() -> (workerID: Int, range: ByteRange)? {
        guard !stopped else { return nil }
        if !pending.isEmpty {
            let r = pending.removeFirst()
            let id = nextID
            nextID += 1
            active[id] = ActiveWorker(currentPos: r.start, endPos: r.end)
            return (id, r)
        }
        // Work stealing: find active worker with largest remaining span and bisect it!
        var bestID: Int?
        var bestRem: Int64 = 0
        for (id, w) in active {
            let rem = w.endPos - w.currentPos + 1
            if rem > bestRem {
                bestRem = rem
                bestID = id
            }
        }
        guard let victimID = bestID, bestRem >= minStealSize * 2, var victim = active[victimID] else {
            return nil
        }
        let mid = victim.currentPos + (bestRem / 2)
        let stolen = ByteRange(start: mid, end: victim.endPos)
        victim.endPos = mid - 1
        active[victimID] = victim

        let newID = nextID
        nextID += 1
        active[newID] = ActiveWorker(currentPos: stolen.start, endPos: stolen.end)
        return (newID, stolen)
    }

    /// Returns true if worker should keep reading, false if its tail was stolen and it reached its new endPos.
    func writeChunk(_ bytes: Data, fd: Int32, workerID: Int, start: Int64) throws -> (keepGoing: Bool, allowedLength: Int, totalDone: Int64) {
        guard !stopped else { return (false, 0, state.downloadedBytes) }
        guard var w = active[workerID] else {
            return (false, 0, state.downloadedBytes)
        }
        let maxEnd = w.endPos
        if start > maxEnd {
            active.removeValue(forKey: workerID)
            return (false, 0, state.downloadedBytes)
        }
        let allowed = min(bytes.count, Int(maxEnd - start + 1))
        let clampedEnd = start + Int64(allowed - 1)
        try bytes.withUnsafeBytes { raw in
            var written = 0
            while written < allowed {
                let count = pwrite(fd, raw.baseAddress!.advanced(by: written), allowed - written, start + Int64(written))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: count == 0 ? Int(EIO) : Int(errno)) }
                written += count
            }
        }
        state.addCompleted(ByteRange(start: start, end: clampedEnd))
        w.currentPos = clampedEnd + 1
        let keepGoing = w.currentPos <= w.endPos
        if keepGoing {
            active[workerID] = w
        } else {
            active.removeValue(forKey: workerID)
        }
        return (keepGoing, allowed, state.downloadedBytes)
    }

    /// A cancelled or refused worker is terminal: no pending tail may start another request.
    func stop() {
        stopped = true
        pending.removeAll()
        active.removeAll()
    }

    func completion() -> (covered: Bool, received: Int64) {
        (state.missingRanges().isEmpty && state.totalSize > 0, state.downloadedBytes)
    }

    func flushState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

}

/// Records whether a task's metrics prove that no response had started when the task ended.
private final class ResponseStart: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var proven = false

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // Only a network load whose last transaction has neither a response nor a response
        // start proves it. Missing, empty or other metrics (for example from a URLProtocol)
        // prove nothing.
        guard let last = metrics.transactionMetrics.last else { return }
        let value = last.resourceFetchType == .networkLoad && last.response == nil && last.responseStartDate == nil
        lock.withLock { proven = value }
    }

    /// True only when the metrics arrived and prove that no response had started.
    var noResponse: Bool { lock.withLock { proven } }
}

/// Lets one request of a client wait for its status at a time. One client serves one operation,
/// so a request starts only after every earlier request of the operation has a status, and no
/// request starts after a refusal or an unknown status, also on another worker. Bodies with a
/// known status still arrive in parallel.
private actor StatusGate {
    private var busy = false
    private var stopped: Error?
    private var waiting: [(id: UInt64, request: CheckedContinuation<Void, Error>)] = []
    private var lastID: UInt64 = 0

    /// Waits until no other request waits for its status. A cancelled task stops waiting at
    /// once and keeps the order of the other waiting requests.
    func enter() async throws {
        if let stopped { throw stopped }
        guard busy else { busy = true; return }
        lastID += 1
        let id = lastID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (request: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { request.resume(throwing: CancellationError()) } else { waiting.append((id, request)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Ends the wait of a cancelled request. A request that `leave` has already admitted is no
    /// longer here: it holds the gate, sees the cancellation in `responseBytes` and leaves.
    private func cancel(_ id: UInt64) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).request.resume(throwing: CancellationError())
    }

    /// Ends the wait of the current request. A `stop` error ends the operation: every waiting
    /// and every later request throws it.
    func leave(stop: Error?) {
        if stopped == nil, let stop { stopped = stop }
        if let stopped {
            busy = false
            for next in waiting { next.request.resume(throwing: stopped) }
            waiting.removeAll()
        } else if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().request.resume()
        }
    }
}

public final class HTTPClient: @unchecked Sendable {
    public static let defaultBrowserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"

    static func canRetryTransport(_ error: Error) -> Bool {
        guard let transport = error as? URLError else { return false }
        switch transport.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet: return true
        default: return false
        }
    }

    /// Provider refusals. A refusal is terminal: it is never retried, and it never becomes a
    /// reason to ask the provider for another URL.
    static func isRefusal(_ code: Int) -> Bool {
        switch code { case 401, 403, 407, 410, 429, 451: return true; default: return false }
    }

    /// True for a proxy URL that `init` can install: an http, https, socks, socks5 or socks5h
    /// scheme and a host. URLSession speaks SOCKS version 5 for every socks scheme, so socks4
    /// and socks4a are refused. Any other string would leave the session without a proxy, so
    /// callers reject it instead of sending the requests directly.
    public static func isValidProxy(_ proxy: String) -> Bool {
        guard let url = URL(string: proxy), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "socks", "socks5", "socks5h"].contains(scheme)
    }

    public let session: URLSession
    private let gate = StatusGate()
    public let cookies: CookieVault
    public let limiter: RateLimiter
    public let defaultHeaders: [String: String]
    public let userAgent: String
    /// The proxy URL this client routes through, or nil for a direct route.
    public let proxy: String?

    public init(
        cookies: CookieVault = CookieVault(),
        proxy: String? = nil,
        rateLimitBytesPerSec: Int64? = nil,
        userAgent: String? = nil,
        extraHeaders: [String: String] = [:]
    ) {
        self.cookies = cookies
        self.limiter = RateLimiter(bytesPerSec: rateLimitBytesPerSec)
        self.userAgent = (userAgent?.isEmpty == false) ? userAgent! : Self.defaultBrowserUA
        self.defaultHeaders = extraHeaders
        self.proxy = (proxy?.isEmpty == false) ? proxy : nil

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpMaximumConnectionsPerHost = 32
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 86400
        cfg.waitsForConnectivity = false

        if let p = proxy, !p.isEmpty, let purl = URL(string: p), let host = purl.host {
            let socks = purl.scheme?.lowercased().hasPrefix("socks") == true
            let port = purl.port ?? (socks ? 1080 : 8080)
            if socks {
                cfg.connectionProxyDictionary = [
                    kCFStreamPropertySOCKSProxyHost as String: host,
                    kCFStreamPropertySOCKSProxyPort as String: port,
                ]
            } else {
                cfg.connectionProxyDictionary = [
                    "HTTPEnable": 1,
                    "HTTPProxy": host,
                    "HTTPPort": port,
                    "HTTPSEnable": 1,
                    "HTTPSProxy": host,
                    "HTTPSPort": port,
                ]
            }
        }
        self.session = URLSession(configuration: cfg)
    }

    public func makeRequest(
        url: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: Data? = nil,
        includeCookies: Bool = true
    ) throws -> URLRequest {
        guard let u = URL(string: url) else { throw HTTPError.badURL(url) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        for (k, v) in defaultHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let headers {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }
        if includeCookies, req.value(forHTTPHeaderField: "Cookie") == nil,
           let cookieStr = cookies.cookieHeader(for: u) {
            req.setValue(cookieStr, forHTTPHeaderField: "Cookie")
        }
        return req
    }

    /// Sends `req` and returns when URLSession hands over the response. URLSession can hold a
    /// response until some of its body arrives, so a refusal that sends headers and then stalls
    /// or fails can reach this code as a transport error. Such an error becomes
    /// `HTTPError.noStatus`, which no caller retries, unless the task metrics prove that no
    /// response had started. Through `gate`, a request starts only when no other request of this
    /// client waits for its status, and never after a refusal or an unknown status.
    func responseBytes(for req: URLRequest, url: String) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await gate.enter()
        let start = ResponseStart()
        do {
            try Task.checkCancellation()
            let reply = try await session.bytes(for: req, delegate: start)
            let code = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
            await gate.leave(stop: Self.isRefusal(code) ? HTTPError.status(code, url) : nil)
            return reply
        } catch let error as URLError where error.code != .cancelled && !start.noResponse {
            await gate.leave(stop: HTTPError.noStatus(url))
            throw HTTPError.noStatus(url)
        } catch {
            await gate.leave(stop: nil)
            throw error
        }
    }

    public func fetchData(
        url: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: Data? = nil,
        includeCookies: Bool = true,
        retries: Int = 3
    ) async throws -> (Data, HTTPURLResponse) {
        var lastErr: Error?
        for attempt in 0..<max(1, retries) {
            try Task.checkCancellation()
            do {
                let req = try makeRequest(url: url, method: method, headers: headers, body: body, includeCookies: includeCookies)
                // The status decides as soon as URLSession hands over the response. A refusal
                // ends here even when its explanation then stalls or breaks off, so a body error
                // cannot cause another request.
                let (bytes, resp) = try await responseBytes(for: req, url: url)
                guard let http = resp as? HTTPURLResponse else {
                    bytes.task.cancel()
                    throw HTTPError.badURL(url)
                }
                guard (200..<300).contains(http.statusCode) else {
                    bytes.task.cancel()
                    if [500, 502, 503, 504].contains(http.statusCode) && attempt + 1 < retries {
                        try await Task.sleep(nanoseconds: UInt64(400_000_000 * (1 << attempt)))
                        continue
                    }
                    throw HTTPError.status(http.statusCode, url)
                }
                var data = Data()
                if http.expectedContentLength > 0 { data.reserveCapacity(Int(min(http.expectedContentLength, 1 << 26))) }
                for try await b in bytes { data.append(b) }
                try await limiter.consume(data.count)
                if http.statusCode == 206, method == "GET", req.value(forHTTPHeaderField: "Range") == nil {
                    guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                          let range = Self.parseContentRange(value), range.first == 0,
                          let total = range.total, range.last == total - 1, Int64(data.count) == total else {
                        throw HTTPError.rangeUnsupported
                    }
                }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                lastErr = error
                if attempt + 1 < retries, Self.canRetryTransport(error) {
                    try await Task.sleep(nanoseconds: UInt64(400_000_000 * (1 << attempt)))
                    continue
                }
                throw error
            }
        }
        throw lastErr ?? HTTPError.badURL(url)
    }

    public func fetchText(
        url: String,
        headers: [String: String]? = nil,
        includeCookies: Bool = true
    ) async throws -> (String, URL) {
        let (data, resp) = try await fetchData(url: url, headers: headers, includeCookies: includeCookies)
        let str = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (str, resp.url ?? URL(string: url)!)
    }

    public func fetchJSON(
        url: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: Data? = nil,
        includeCookies: Bool = true,
        retries: Int = 3
    ) async throws -> Any {
        let (data, _) = try await fetchData(url: url, method: method, headers: headers, body: body, includeCookies: includeCookies, retries: retries)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Returns the bytes `range.start...range.end` (fewer at the end of the file). A server that
    /// ignores `Range` answers 200 with the whole file; the requested bytes are then cut out of it,
    /// so a caller never takes the start of the file for the requested bytes. A partial answer
    /// must contain the full requested interval, or prove that it ends at EOF.
    public func fetchRangeBytes(url: String, range: ByteRange, headers: [String: String]? = nil) async throws -> Data {
        try await fetchRange(url: url, range: range, headers: headers).data
    }

    /// One edition of one resource. A strong ETag names an edition only of the resource that
    /// sent it, so the URL that answered (after redirects) is part of the identity.
    struct Edition: Sendable, Equatable {
        let location: String
        let tag: String
    }

    static func edition(_ response: HTTPURLResponse) -> Edition? {
        guard let tag = strongTag(response), let location = response.url?.absoluteString else { return nil }
        return Edition(location: location, tag: tag)
    }

    /// With `edition`, the read goes to that edition's URL with `If-Match` and must come back
    /// from the same URL with the same strong ETag. The result names the edition that answered.
    func fetchRange(url: String, range: ByteRange, headers: [String: String]?, edition: Edition? = nil) async throws -> (data: Data, fileSize: Int64?, edition: Edition?) {
        guard range.start >= 0, range.end >= range.start else { throw HTTPError.rangeUnsupported }
        var hdrs = headers ?? [:]
        hdrs["Range"] = "bytes=\(range.start)-\(range.end)"
        if let edition { hdrs["If-Match"] = edition.tag }
        let (data, http) = try await fetchData(url: edition?.location ?? url, headers: hdrs)
        let answered = Self.edition(http)
        if let edition, answered != edition { throw HTTPError.rangeUnsupported }
        if http.statusCode == 206 {
            guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let content = Self.parseContentRange(value),
                  content.first == range.start,
                  !data.isEmpty,
                  Int64(data.count - 1) == content.last - content.first else {
                throw HTTPError.rangeUnsupported
            }
            if let size = content.total {
                guard size > content.last, content.last == min(range.end, size - 1) else {
                    throw HTTPError.rangeUnsupported
                }
                return (data, size, answered)
            }
            guard content.last == range.end else { throw HTTPError.rangeUnsupported }
            return (data, nil, answered)
        }
        // A server that ignores Range answers 200 with the whole file. A body shorter than its
        // Content-Length was cut in transit; it is not a smaller file.
        if http.value(forHTTPHeaderField: "Content-Encoding") == nil,
           http.expectedContentLength > 0,
           http.expectedContentLength != Int64(data.count) {
            throw HTTPError.incomplete(received: Int64(data.count), expected: http.expectedContentLength)
        }
        guard Int64(data.count) > range.start else { throw HTTPError.rangeUnsupported }
        let last = min(range.end, Int64(data.count - 1))
        return (data.subdata(in: Int(range.start)..<(Int(last) + 1)), Int64(data.count), answered)
    }

    private struct ContentRange {
        let first: Int64
        let last: Int64
        let total: Int64?
    }

    /// Parses one `Content-Range: bytes first-last/total` value. Nil for every other shape,
    /// including a multipart range list, so a caller never guesses which bytes arrived.
    private static func parseContentRange(_ value: String) -> ContentRange? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let interval = trimmed.dropFirst("bytes ".count)
        guard !interval.contains(","),
              let dash = interval.firstIndex(of: "-"),
              let slash = interval.lastIndex(of: "/"),
              dash < slash,
              let first = Int64(interval[..<dash]),
              let last = Int64(interval[interval.index(after: dash)..<slash]),
              first >= 0, last >= first else { return nil }
        let totalText = interval[interval.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        if totalText == "*" { return ContentRange(first: first, last: last, total: nil) }
        guard let total = Int64(totalText), total > last else { return nil }
        return ContentRange(first: first, last: last, total: total)
    }

    static func strongTag(_ response: HTTPURLResponse) -> String? {
        guard let tag = response.value(forHTTPHeaderField: "ETag"), tag.utf8.count >= 2,
              tag.first == "\"", tag.last == "\"" else { return nil }
        return tag
    }

    /// Probes total file size and range support using a tiny `Range: bytes=0-0` request.
    func probeRemote(url: String, headers: [String: String]?) async throws -> (totalSize: Int64?, acceptsRanges: Bool, edition: Edition?) {
        var hdrs = headers ?? [:]
        hdrs["Range"] = "bytes=0-0"
        let req = try makeRequest(url: url, headers: hdrs)
        let (_, resp) = try await responseBytes(for: req, url: url)
        guard let http = resp as? HTTPURLResponse else { return (nil, false, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, url)
        }
        let edition = Self.edition(http)
        if http.statusCode == 206 {
            // A 206 with `*` gives no file size, and this body's length is not the file length.
            guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = Self.parseContentRange(value), range.first == 0, range.last == 0 else {
                throw HTTPError.rangeUnsupported
            }
            return (range.total, true, edition)
        }
        let clen = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        return (clen, false, edition)
    }

    /// High-throughput multi-connection work-stealing downloader with `.part` + `.part.json` atomic resume.
    public func downloadFile(
        url: String,
        destination: URL,
        headers: [String: String]? = nil,
        knownSize: Int64? = nil,
        connections: Int = 8,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partURL = destination.appendingPathExtension("part")
        let stateURL = destination.appendingPathExtension("part.json")

        let probe: (totalSize: Int64?, acceptsRanges: Bool, edition: Edition?)
        do {
            probe = try await probeRemote(url: url, headers: headers)
        } catch {
            Self.discardRefusedTransfer(partURL: partURL, stateURL: stateURL, after: error)
            throw error
        }
        let totalSize = probe.totalSize ?? knownSize

        // Separate range replies can describe different bytes at the same URL and length, and a
        // redirect can send them to different resources with the same ETag text. Every range
        // therefore goes to the URL that answered the probe and must carry the probed edition.
        guard let total = totalSize, total > 512 * 1024, probe.acceptsRanges, connections > 1,
              let edition = probe.edition else {
            do {
                try await singleStreamDownload(
                    url: url,
                    partURL: partURL,
                    destination: destination,
                    headers: headers,
                    resumeEdition: probe.acceptsRanges ? probe.edition : nil,
                    stateURL: stateURL,
                    totalSize: totalSize,
                    onProgress: onProgress
                )
            } catch {
                Self.discardRefusedTransfer(partURL: partURL, stateURL: stateURL, after: error)
                throw error
            }
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        let resource = Self.resourceDigest(url, edition.location)

        // Load or create chunk state. A state file is trusted only when the part file has the
        // advertised length and every completed range is sorted, disjoint and inside the file.
        var chunkState: ChunkStateFile
        if let partSize = Self.fileSize(partURL), partSize == total,
           let stateData = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(ChunkStateFile.self, from: stateData),
           Self.isValidResumeState(saved, total: total),
           saved.resourceDigest == resource, saved.etag == edition.tag {
            chunkState = saved
        } else {
            try? FileManager.default.removeItem(at: stateURL)
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let fh = try FileHandle(forWritingTo: partURL)
            try fh.truncate(atOffset: UInt64(total))
            try fh.close()
            chunkState = ChunkStateFile(totalSize: total, resourceDigest: resource, etag: edition.tag, completed: [])
        }

        onProgress?(chunkState.downloadedBytes, total)
        if chunkState.missingRanges().isEmpty {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partURL, to: destination)
            try? FileManager.default.removeItem(at: stateURL)
            return
        }

        let fd = open(partURL.path, O_RDWR)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }

        var rangeHeaders = headers ?? [:]
        rangeHeaders["If-Range"] = edition.tag
        let workerHeaders = rangeHeaders
        let numWorkers = max(1, min(32, connections))
        let workQueue = WorkStealingQueue(state: chunkState, stateURL: stateURL, initialSplits: numWorkers * 2)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<numWorkers {
                    group.addTask { [self] in
                        while true {
                            try Task.checkCancellation()
                            guard let claim = await workQueue.claimWork() else { break }
                            try await self.runRangeWorker(
                                workerID: claim.workerID,
                                initialRange: claim.range,
                                edition: edition,
                                headers: workerHeaders,
                                fd: fd,
                                totalSize: total,
                                workQueue: workQueue,
                                onProgress: onProgress
                            )
                        }
                        try Task.checkCancellation()
                    }
                }
                for try await _ in group {}
            }
        } catch {
            await workQueue.flushState()
            Self.discardRefusedTransfer(partURL: partURL, stateURL: stateURL, after: error)
            throw error
        }

        try Task.checkCancellation()
        let completion = await workQueue.completion()
        guard completion.covered else {
            await workQueue.flushState()
            throw HTTPError.incomplete(received: completion.received, expected: total)
        }
        await workQueue.flushState()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// Size of an existing file, or nil when it is missing.
    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// A resume file is usable only when it describes this exact file: sorted, disjoint ranges
    /// that all lie inside the advertised length. Anything else starts from zero.
    private static func isValidResumeState(_ state: ChunkStateFile, total: Int64) -> Bool {
        guard state.totalSize == total else { return false }
        var cursor: Int64 = 0
        for range in state.completed {
            guard range.start >= cursor, range.start >= 0, range.end >= range.start, range.end < total else {
                return false
            }
            cursor = range.end + 1
        }
        return true
    }

    // Do not leave media from a refused operation, or from one whose status is unknown, available
    // for resume.
    private static func discardRefusedTransfer(partURL: URL, stateURL: URL, after error: Error) {
        switch error {
        case HTTPError.status(let code, _) where isRefusal(code): break
        case HTTPError.noStatus: break
        default: return
        }
        try? FileManager.default.removeItem(at: partURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func runRangeWorker(
        workerID: Int,
        initialRange: ByteRange,
        edition: Edition,
        headers: [String: String]?,
        fd: Int32,
        totalSize: Int64,
        workQueue: WorkStealingQueue,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        var curStart = initialRange.start
        let origEnd = initialRange.end
        var attempts = 0
        let url = edition.location
        let isGoogleVideo = url.contains("googlevideo.com")
        let maxWindowBytes: Int64 = isGoogleVideo ? 8 * 1024 * 1024 : Int64.max

        while curStart <= origEnd {
            if Task.isCancelled {
                await workQueue.stop()
                throw CancellationError()
            }
            do {
                let reqEnd = curStart + min(origEnd - curStart, maxWindowBytes - 1)
                var hdrs = headers ?? [:]
                hdrs["Range"] = "bytes=\(curStart)-\(reqEnd)"
                let req = try makeRequest(url: url, headers: hdrs)
                let (bytes, resp) = try await responseBytes(for: req, url: url)
                guard let http = resp as? HTTPURLResponse else {
                    throw HTTPError.badURL(url)
                }
                if Self.isRefusal(http.statusCode) {
                    throw HTTPError.status(http.statusCode, url)
                }
                guard http.statusCode == 206, http.url?.absoluteString == url,
                      http.value(forHTTPHeaderField: "ETag") == nil || Self.strongTag(http) == edition.tag,
                      let value = http.value(forHTTPHeaderField: "Content-Range"),
                      let content = Self.parseContentRange(value),
                      content.first == curStart,
                      content.last == reqEnd,
                      content.last < totalSize else {
                    throw HTTPError.rangeUnsupported
                }
                if let total = content.total, total != totalSize {
                    throw HTTPError.rangeUnsupported
                }
                let declared = content.last - content.first + 1
                var received: Int64 = 0
                var buf = Data()
                buf.reserveCapacity(131_072)
                var flushCounter = 0

                for try await b in bytes {
                    guard received < declared else { throw HTTPError.rangeUnsupported }
                    received += 1
                    buf.append(b)
                    if buf.count >= 65_536 {
                        let res = try await commitBuffer(&buf, workerID: workerID, offset: curStart, fd: fd, totalSize: totalSize, workQueue: workQueue, onProgress: onProgress)
                        curStart += Int64(res.written)
                        flushCounter += 1
                        if flushCounter % 16 == 0 {
                            await workQueue.flushState()
                        }
                        if !res.keepGoing && curStart <= origEnd { return }
                        if Task.isCancelled {
                            await workQueue.stop()
                            throw CancellationError()
                        }
                    }
                }
                if !buf.isEmpty {
                    let res = try await commitBuffer(&buf, workerID: workerID, offset: curStart, fd: fd, totalSize: totalSize, workQueue: workQueue, onProgress: onProgress)
                    curStart += Int64(res.written)
                    if !res.keepGoing && curStart <= origEnd { return }
                }
                guard received == declared else { throw HTTPError.incomplete(received: received, expected: declared) }
                attempts = 0
            } catch {
                attempts += 1
                if attempts >= 4 || Task.isCancelled || !Self.canRetryTransport(error) {
                    await workQueue.stop()
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(350_000_000 * attempts))
            }
        }
    }

    private func commitBuffer(
        _ buf: inout Data,
        workerID: Int,
        offset: Int64,
        fd: Int32,
        totalSize: Int64,
        workQueue: WorkStealingQueue,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> (keepGoing: Bool, written: Int) {
        try await limiter.consume(buf.count)
        try Task.checkCancellation()
        let decision = try await workQueue.writeChunk(buf, fd: fd, workerID: workerID, start: offset)
        buf.removeAll(keepingCapacity: true)
        onProgress?(decision.totalDone, totalSize)
        return (decision.keepGoing, decision.allowedLength)
    }

    /// Names the resource of a resume file: the requested URL and the URL that answered.
    /// Hashed so that a signed query string is not stored in the file.
    private static func resourceDigest(_ url: String, _ location: String) -> Data {
        Data(SHA256.hash(data: Data((url + "\n" + location).utf8)))
    }

    private func singleStreamDownload(
        url: String,
        partURL: URL,
        destination: URL,
        headers: [String: String]?,
        resumeEdition: Edition?,
        stateURL: URL,
        totalSize: Int64?,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        // A `.part` that reaches or passes the advertised length cannot be proven to hold real
        // bytes: a parallel preallocation has the full length and may have no state file. Both
        // cases start from zero.
        var existingOffset: Int64 = 0
        if let resumeEdition, let record = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(ChunkStateFile.self, from: record),
           saved.resourceDigest == Self.resourceDigest(url, resumeEdition.location),
           saved.etag == resumeEdition.tag, saved.completed.isEmpty,
           let sz = Self.fileSize(partURL), sz > 0,
           totalSize.map({ sz < $0 }) ?? true {
            existingOffset = sz
        } else {
            try? FileManager.default.removeItem(at: partURL)
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }

        // A resume reads the rest from the edition that wrote the start of the file.
        let source = existingOffset > 0 ? resumeEdition?.location ?? url : url
        var hdrs = headers ?? [:]
        if existingOffset > 0 {
            hdrs["Range"] = "bytes=\(existingOffset)-"
            hdrs["If-Range"] = resumeEdition?.tag
        }
        let req = try makeRequest(url: source, headers: hdrs)
        let (bytes, resp) = try await responseBytes(for: req, url: url)
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.badURL(url) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, url)
        }

        var expectedTotal = totalSize ?? 0
        var restart = false
        if http.statusCode == 206 {
            guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let content = Self.parseContentRange(value),
                  content.first == existingOffset else {
                throw HTTPError.rangeUnsupported
            }
            guard let total = content.total ?? totalSize, total > 0, content.last == total - 1,
                  totalSize == nil || totalSize == total else { throw HTTPError.rangeUnsupported }
            if existingOffset > 0, http.url?.absoluteString != source
                || (http.value(forHTTPHeaderField: "ETag") != nil && Self.strongTag(http) != resumeEdition?.tag) {
                throw HTTPError.rangeUnsupported
            }
            expectedTotal = total
        } else {
            // 200 is the whole file, even when the request carried a resume range.
            restart = existingOffset > 0
            existingOffset = 0
            if expectedTotal == 0,
               http.value(forHTTPHeaderField: "Content-Encoding") == nil,
               http.expectedContentLength > 0 {
                expectedTotal = http.expectedContentLength
            }
        }

        let fh = try FileHandle(forWritingTo: partURL)
        defer { try? fh.close() }
        if restart {
            try fh.truncate(atOffset: 0)
            try fh.seek(toOffset: 0)
        } else if existingOffset > 0 {
            try fh.seekToEnd()
        }

        if existingOffset == 0 {
            let tag = http.value(forHTTPHeaderField: "Content-Encoding") == nil ? Self.strongTag(http) : nil
            let resource = Self.resourceDigest(url, http.url?.absoluteString ?? url)
            let record = ChunkStateFile(totalSize: expectedTotal, resourceDigest: resource, etag: tag, completed: [])
            try JSONEncoder().encode(record).write(to: stateURL, options: .atomic)
        }
        var downloaded = existingOffset
        var buf = Data()
        buf.reserveCapacity(65_536)

        for try await b in bytes {
            buf.append(b)
            if buf.count >= 65_536 {
                try Task.checkCancellation()
                try await limiter.consume(buf.count)
                try fh.write(contentsOf: buf)
                downloaded += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
                onProgress?(downloaded, expectedTotal)
            }
        }
        if !buf.isEmpty {
            try await limiter.consume(buf.count)
            try fh.write(contentsOf: buf)
            downloaded += Int64(buf.count)
            onProgress?(downloaded, expectedTotal)
        }
        try Task.checkCancellation()
        try fh.truncate(atOffset: UInt64(downloaded))
        if expectedTotal > 0 && downloaded != expectedTotal {
            throw HTTPError.incomplete(received: downloaded, expected: expectedTotal)
        }
        try fh.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partURL, to: destination)
    }
}
