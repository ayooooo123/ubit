import Foundation

public enum HTTPError: LocalizedError {
    case badURL(String)
    case status(Int, String)
    case staleLink(Int)
    case rangeUnsupported
    case canceled

    public var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Invalid URL: \(u)"
        case .status(let code, let u): return "HTTP \(code) from \(URL(string: u)?.host ?? u)"
        case .staleLink(let code): return "Stream link expired (HTTP \(code))"
        case .rangeUnsupported: return "Server stopped serving byte ranges"
        case .canceled: return "Canceled"
        }
    }
}

public actor RateLimiter {
    private let bytesPerSec: Int64
    private var nextAllowedTime: TimeInterval = 0

    public init(bytesPerSec: Int64?) {
        self.bytesPerSec = bytesPerSec ?? 0
    }

    public func consume(_ bytes: Int) async {
        guard bytesPerSec > 0, bytes > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = Double(bytes) / Double(bytesPerSec)
        let start = max(now, nextAllowedTime)
        nextAllowedTime = start + duration
        let delay = start - now
        if delay > 0.002 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

public struct ChunkStateFile: Codable, Sendable {
    public var totalSize: Int64
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
    func recordChunk(workerID: Int, start: Int64, length: Int) -> (keepGoing: Bool, allowedLength: Int, totalDone: Int64) {
        guard var w = active[workerID] else {
            return (false, 0, state.downloadedBytes)
        }
        let maxEnd = w.endPos
        if start > maxEnd {
            active.removeValue(forKey: workerID)
            return (false, 0, state.downloadedBytes)
        }
        let clampedEnd = min(maxEnd, start + Int64(length) - 1)
        let allowed = Int(clampedEnd - start + 1)
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

    func failWorker(workerID: Int) {
        if let w = active.removeValue(forKey: workerID), w.currentPos <= w.endPos {
            pending.insert(ByteRange(start: w.currentPos, end: w.endPos), at: 0)
        }
    }

    func flushState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    func downloadedBytes() -> Int64 {
        state.downloadedBytes
    }
}

public final class HTTPClient: @unchecked Sendable {
    public static let defaultBrowserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"

    public let session: URLSession
    public let cookies: CookieVault
    public let limiter: RateLimiter
    public let defaultHeaders: [String: String]
    public let userAgent: String

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

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpMaximumConnectionsPerHost = 32
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 86400
        cfg.waitsForConnectivity = false

        if let p = proxy, !p.isEmpty, let purl = URL(string: p), let host = purl.host {
            let port = purl.port ?? (purl.scheme?.hasPrefix("socks") == true ? 1080 : 8080)
            if purl.scheme?.lowercased().hasPrefix("socks") == true {
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
                let (data, resp) = try await session.data(for: req)
                await limiter.consume(data.count)
                guard let http = resp as? HTTPURLResponse else {
                    throw HTTPError.badURL(url)
                }
                if (200..<300).contains(http.statusCode) {
                    return (data, http)
                }
                if http.statusCode == 403 || http.statusCode == 410 {
                    throw HTTPError.status(http.statusCode, url)
                }
                if [429, 500, 502, 503, 504].contains(http.statusCode) && attempt + 1 < retries {
                    try await Task.sleep(nanoseconds: UInt64(400_000_000 * (1 << attempt)))
                    continue
                }
                throw HTTPError.status(http.statusCode, url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastErr = error
                if attempt + 1 < retries, (error as? URLError) != nil {
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
        includeCookies: Bool = true
    ) async throws -> Any {
        let (data, _) = try await fetchData(url: url, method: method, headers: headers, body: body, includeCookies: includeCookies)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public func fetchRangeBytes(url: String, range: ByteRange, headers: [String: String]? = nil) async throws -> Data {
        var hdrs = headers ?? [:]
        hdrs["Range"] = "bytes=\(range.start)-\(range.end)"
        let (data, _) = try await fetchData(url: url, headers: hdrs)
        return data
    }

    /// Probes total file size and range support using a tiny `Range: bytes=0-0` request.
    private func probeRemote(url: String, headers: [String: String]?) async throws -> (totalSize: Int64?, acceptsRanges: Bool, etag: String?) {
        var hdrs = headers ?? [:]
        hdrs["Range"] = "bytes=0-0"
        let req = try makeRequest(url: url, headers: hdrs)
        let (_, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { return (nil, false, nil) }
        if http.statusCode == 403 || http.statusCode == 410 {
            throw HTTPError.staleLink(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, url)
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range") {
            // bytes 0-0/12345678
            if let slash = cr.lastIndex(of: "/"),
               let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
                return (total, true, etag)
            }
        }
        let clen = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        return (clen, false, etag)
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

        let probe = try await probeRemote(url: url, headers: headers)
        let totalSize = probe.totalSize ?? knownSize

        guard let total = totalSize, total > 512 * 1024, probe.acceptsRanges, connections > 1 else {
            // Single-stream streaming download (with Range resume if .part exists and server supports ranges)
            try await singleStreamDownload(
                url: url,
                partURL: partURL,
                destination: destination,
                headers: headers,
                acceptsRanges: probe.acceptsRanges,
                totalSize: totalSize,
                onProgress: onProgress
            )
            try? FileManager.default.removeItem(at: stateURL)
            return
        }

        // Load or create chunk state
        var chunkState: ChunkStateFile
        if FileManager.default.fileExists(atPath: partURL.path),
           let stateData = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(ChunkStateFile.self, from: stateData),
           saved.totalSize == total,
           (saved.etag == nil || probe.etag == nil || saved.etag == probe.etag) {
            chunkState = saved
        } else {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let fh = try FileHandle(forWritingTo: partURL)
            try fh.truncate(atOffset: UInt64(total))
            try fh.close()
            chunkState = ChunkStateFile(totalSize: total, etag: probe.etag, completed: [])
        }

        let initialDone = chunkState.downloadedBytes
        onProgress?(initialDone, total)
        if initialDone >= total {
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

        let numWorkers = max(1, min(32, connections))
        let workQueue = WorkStealingQueue(state: chunkState, stateURL: stateURL, initialSplits: numWorkers * 2)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<numWorkers {
                    group.addTask { [self] in
                        while !Task.isCancelled {
                            guard let claim = await workQueue.claimWork() else { break }
                            try await self.runRangeWorker(
                                workerID: claim.workerID,
                                initialRange: claim.range,
                                url: url,
                                headers: headers,
                                fd: fd,
                                totalSize: total,
                                workQueue: workQueue,
                                onProgress: onProgress
                            )
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            await workQueue.flushState()
            throw error
        }

        await workQueue.flushState()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func runRangeWorker(
        workerID: Int,
        initialRange: ByteRange,
        url: String,
        headers: [String: String]?,
        fd: Int32,
        totalSize: Int64,
        workQueue: WorkStealingQueue,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        var curStart = initialRange.start
        let origEnd = initialRange.end
        var attempts = 0
        let isGoogleVideo = url.contains("googlevideo.com")
        let maxWindowBytes: Int64 = isGoogleVideo ? 8 * 1024 * 1024 : Int64.max

        while curStart <= origEnd {
            try Task.checkCancellation()
            do {
                let reqEnd = (maxWindowBytes == Int64.max) ? origEnd : min(origEnd, curStart + maxWindowBytes - 1)
                var hdrs = headers ?? [:]
                hdrs["Range"] = "bytes=\(curStart)-\(reqEnd)"
                let req = try makeRequest(url: url, headers: hdrs)
                let (bytes, resp) = try await session.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw HTTPError.badURL(url)
                }
                if http.statusCode == 403 || http.statusCode == 410 {
                    await workQueue.failWorker(workerID: workerID)
                    throw HTTPError.staleLink(http.statusCode)
                }
                guard http.statusCode == 206 else {
                    await workQueue.failWorker(workerID: workerID)
                    throw HTTPError.rangeUnsupported
                }

                var buf = Data()
                buf.reserveCapacity(131_072)
                var flushCounter = 0

                for try await b in bytes {
                    buf.append(b)
                    if buf.count >= 65_536 {
                        let res = try await commitBuffer(&buf, workerID: workerID, offset: curStart, fd: fd, totalSize: totalSize, workQueue: workQueue, onProgress: onProgress)
                        curStart += Int64(res.written)
                        flushCounter += 1
                        if flushCounter % 16 == 0 {
                            await workQueue.flushState()
                        }
                        if !res.keepGoing { return }
                        if Task.isCancelled {
                            await workQueue.failWorker(workerID: workerID)
                            throw CancellationError()
                        }
                    }
                }
                if !buf.isEmpty {
                    let res = try await commitBuffer(&buf, workerID: workerID, offset: curStart, fd: fd, totalSize: totalSize, workQueue: workQueue, onProgress: onProgress)
                    curStart += Int64(res.written)
                    if !res.keepGoing { return }
                }
                attempts = 0
                if reqEnd >= origEnd { return }
            } catch is CancellationError {
                await workQueue.failWorker(workerID: workerID)
                throw CancellationError()
            } catch let e as HTTPError {
                await workQueue.failWorker(workerID: workerID)
                throw e
            } catch {
                attempts += 1
                if attempts >= 4 {
                    await workQueue.failWorker(workerID: workerID)
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
        let count = buf.count
        await limiter.consume(count)
        let decision = await workQueue.recordChunk(workerID: workerID, start: offset, length: count)
        if decision.allowedLength > 0 {
            try buf.withUnsafeBytes { rawPtr in
                guard let base = rawPtr.baseAddress else { return }
                var written = 0
                while written < decision.allowedLength {
                    let w = pwrite(fd, base.advanced(by: written), decision.allowedLength - written, offset + Int64(written))
                    if w < 0 {
                        if errno == EINTR { continue }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    written += w
                }
            }
        }
        buf.removeAll(keepingCapacity: true)
        onProgress?(decision.totalDone, totalSize)
        return (decision.keepGoing, decision.allowedLength)
    }

    private func singleStreamDownload(
        url: String,
        partURL: URL,
        destination: URL,
        headers: [String: String]?,
        acceptsRanges: Bool,
        totalSize: Int64?,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        var existingOffset: Int64 = 0
        if acceptsRanges, let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
           let sz = attrs[.size] as? Int64, sz > 0 {
            existingOffset = sz
        } else {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }

        var hdrs = headers ?? [:]
        if existingOffset > 0 {
            hdrs["Range"] = "bytes=\(existingOffset)-"
        }
        let req = try makeRequest(url: url, headers: hdrs)
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.badURL(url) }
        if http.statusCode == 403 || http.statusCode == 410 {
            throw HTTPError.staleLink(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, url)
        }
        if http.statusCode == 200 && existingOffset > 0 {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            existingOffset = 0
        }

        let fh = try FileHandle(forWritingTo: partURL)
        defer { try? fh.close() }
        if existingOffset > 0 {
            try fh.seekToEnd()
        }

        let expectedTotal = totalSize ?? (http.expectedContentLength > 0 ? existingOffset + http.expectedContentLength : 0)
        var downloaded = existingOffset
        var buf = Data()
        buf.reserveCapacity(65_536)

        for try await b in bytes {
            buf.append(b)
            if buf.count >= 65_536 {
                try Task.checkCancellation()
                await limiter.consume(buf.count)
                try fh.write(contentsOf: buf)
                downloaded += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
                onProgress?(downloaded, expectedTotal)
            }
        }
        if !buf.isEmpty {
            await limiter.consume(buf.count)
            try fh.write(contentsOf: buf)
            downloaded += Int64(buf.count)
            onProgress?(downloaded, expectedTotal)
        }
        try fh.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partURL, to: destination)
    }
}
