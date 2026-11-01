import Foundation
import IOKit.pwr_mgt
import AppKit

// MARK: - Library Store & Subscription Store

public final class LibraryStore: @unchecked Sendable {
    public static let shared = LibraryStore()
    private let lock = NSLock()
    private var items: [LibraryItem] = []

    public init() {
        reload()
    }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: AppPaths.libraryFile),
           let loaded = try? dec.decode([LibraryItem].self, from: data) {
            items = loaded
        }
    }

    public func all() -> [LibraryItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func upsert(_ item: LibraryItem) {
        lock.lock()
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.insert(item, at: 0)
        }
        saveLocked()
        lock.unlock()
    }

    public func remove(id: String) {
        lock.lock()
        items.removeAll { $0.id == id }
        saveLocked()
        lock.unlock()
    }

    public func clearFinished() {
        lock.lock()
        items.removeAll { $0.state == .done || $0.state == .canceled }
        saveLocked()
        lock.unlock()
    }

    private func saveLocked() {
        try? AppPaths.ensureAppSupport()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(items) {
            try? data.write(to: AppPaths.libraryFile, options: .atomic)
        }
    }
}

public final class SubscriptionStore: @unchecked Sendable {
    public static let shared = SubscriptionStore()
    private let lock = NSLock()
    private var subs: [Subscription] = []

    public init() {
        reload()
    }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: AppPaths.subsFile),
           let loaded = try? dec.decode([Subscription].self, from: data) {
            subs = loaded
        }
    }

    public func all() -> [Subscription] {
        lock.lock()
        defer { lock.unlock() }
        return subs
    }

    public func add(url: String, audioOnly: Bool = false, engine: DownloadEngine, settings: Settings) async throws -> Subscription {
        let opts = DownloadRequestOptions.from(settings: settings)
        let info = try await engine.extract(url: url, settings: settings, options: opts)
        guard !info.entries.isEmpty else {
            throw ExtractorError.unsupported("That's a single item — subscribe to a channel or playlist URL instead.")
        }
        let initialSeen = Set(info.entries.map(\.id))
        let sub = Subscription(
            url: info.webpageURL,
            title: info.title,
            site: info.site,
            thumbnail: info.thumbnail ?? info.entries.first?.thumbnail,
            audioOnly: audioOnly,
            seenIDs: initialSeen,
            lastCheckedAt: Date(),
            lastNewCount: 0
        )
        upsertSubscription(sub)
        return sub
    }

    private func upsertSubscription(_ sub: Subscription) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = subs.firstIndex(where: { $0.url == sub.url }) {
            subs[idx] = sub
        } else {
            subs.append(sub)
        }
        saveLocked()
    }

    public func remove(atIndex oneBasedIndex: Int) -> Subscription? {
        lock.lock()
        defer { lock.unlock() }
        let idx = oneBasedIndex - 1
        guard subs.indices.contains(idx) else { return nil }
        let removed = subs.remove(at: idx)
        saveLocked()
        return removed
    }

    public func remove(id: String) {
        lock.lock()
        subs.removeAll { $0.id == id }
        saveLocked()
        lock.unlock()
    }

    public func update(_ sub: Subscription) {
        lock.lock()
        if let idx = subs.firstIndex(where: { $0.id == sub.id }) {
            subs[idx] = sub
            saveLocked()
        }
        lock.unlock()
    }

    /// Checks all subscriptions and returns newly discovered entries along with their parent subscription.
    public func checkAll(engine: DownloadEngine, settings: Settings) async -> [(Subscription, [PlaylistEntry])] {
        let current = all()
        var discovered: [(Subscription, [PlaylistEntry])] = []
        let opts = DownloadRequestOptions.from(settings: settings)

        for var sub in current {
            guard let info = try? await engine.extract(url: sub.url, settings: settings, options: opts) else { continue }
            let newEntries = info.entries.filter { !sub.seenIDs.contains($0.id) }
            for e in newEntries { sub.seenIDs.insert(e.id) }
            sub.lastCheckedAt = Date()
            sub.lastNewCount = newEntries.count
            update(sub)
            if !newEntries.isEmpty {
                discovered.append((sub, newEntries))
            }
        }
        return discovered
    }

    private func saveLocked() {
        try? AppPaths.ensureAppSupport()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(subs) {
            try? data.write(to: AppPaths.subsFile, options: .atomic)
        }
    }
}

// MARK: - App Download Queue Manager + Keep-Awake + IPC

@MainActor
public final class QueueManager {
    public static let shared = QueueManager()

    public private(set) var items: [LibraryItem] = []
    public var onChange: (() -> Void)?

    private let engine = DownloadEngine()
    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var liveStopFlags: [String: Bool] = [:]
    private var customOptionsByID: [String: DownloadRequestOptions] = [:]
    private var sleepAssertionID: IOPMAssertionID = 0
    private var hasSleepAssertion = false

    private init() {
        LibraryStore.shared.reload()
        var loaded = LibraryStore.shared.all()
        // Any downloads interrupted by a previous quit return to `.paused` so user can resume cleanly
        for i in loaded.indices {
            if [.downloading, .extracting, .processing, .queued].contains(loaded[i].state) {
                loaded[i].state = .paused
                loaded[i].speedBytesPerSec = 0
                LibraryStore.shared.upsert(loaded[i])
            }
        }
        self.items = loaded
    }

    public func enqueue(
        url: String,
        title: String? = nil,
        thumbnail: String? = nil,
        preExtracted: MediaInfo? = nil,
        optionsOverride: DownloadRequestOptions? = nil
    ) {
        let settings = Settings.load()
        var opts = optionsOverride ?? DownloadRequestOptions.from(settings: settings)
        let isAudio = opts.audioOnly || (settings.mode == "audio" && optionsOverride == nil)
        opts.audioOnly = isAudio

        let item = LibraryItem(
            url: url,
            title: title ?? preExtracted?.title ?? url,
            site: preExtracted?.site ?? (URL(string: url)?.host ?? ""),
            author: preExtracted?.author,
            ext: opts.targetFormat ?? (isAudio ? settings.audioFormat : settings.videoFormat),
            thumbnail: thumbnail ?? preExtracted?.thumbnail,
            duration: preExtracted?.duration,
            state: .queued,
            isAudio: isAudio,
            isLive: preExtracted?.isLive ?? false,
            formatID: opts.formatSelector,
            section: opts.section
        )
        customOptionsByID[item.id] = opts
        items.insert(item, at: 0)
        LibraryStore.shared.upsert(item)
        notifyChanged()
        pump()
    }

    public func pause(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            if items[idx].isLive && runningTasks[id] != nil {
                // Graceful stop & save for live streams!
                liveStopFlags[id] = true
                return
            }
            runningTasks[id]?.cancel()
            runningTasks.removeValue(forKey: id)
            items[idx].state = .paused
            items[idx].speedBytesPerSec = 0
            items[idx].etaSeconds = nil
            LibraryStore.shared.upsert(items[idx])
            notifyChanged()
            pump()
        }
    }

    public func resume(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }),
           [.paused, .failed, .canceled].contains(items[idx].state) {
            items[idx].state = .queued
            items[idx].error = nil
            LibraryStore.shared.upsert(items[idx])
            notifyChanged()
            pump()
        }
    }

    public func cancelAndRemove(id: String, moveFileToTrash: Bool = false) {
        runningTasks[id]?.cancel()
        runningTasks.removeValue(forKey: id)
        if let item = items.first(where: { $0.id == id }), moveFileToTrash, let p = item.path {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
        }
        items.removeAll { $0.id == id }
        LibraryStore.shared.remove(id: id)
        notifyChanged()
        pump()
    }

    public func pauseAll() {
        for item in items where [.downloading, .extracting, .queued].contains(item.state) {
            pause(id: item.id)
        }
    }

    public func resumeAll() {
        for i in items.indices where items[i].state == .paused {
            items[i].state = .queued
            LibraryStore.shared.upsert(items[i])
        }
        notifyChanged()
        pump()
    }

    public func clearFinished() {
        items.removeAll { $0.state == .done || $0.state == .canceled }
        LibraryStore.shared.clearFinished()
        notifyChanged()
    }

    public func downloadNext(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: idx)
        if item.state == .paused || item.state == .failed { item.state = .queued }
        items.insert(item, at: 0)
        notifyChanged()
        pump()
    }

    public func pump() {
        let settings = Settings.load()
        let maxConc = max(1, min(16, settings.concurrent))
        while runningTasks.count < maxConc {
            guard let nextIdx = items.lastIndex(where: { $0.state == .queued }) ?? items.firstIndex(where: { $0.state == .queued }) else {
                break
            }
            let item = items[nextIdx]
            startItem(id: item.id, settings: settings)
        }
        updateSystemPowerAndDock(settings: settings)
    }

    private func startItem(id: String, settings: Settings) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .extracting
        items[idx].error = nil
        let url = items[idx].url
        var opts = customOptionsByID[id] ?? DownloadRequestOptions.from(settings: settings)
        if items[idx].isAudio { opts.audioOnly = true }
        if let f = items[idx].formatID { opts.formatSelector = f }
        if let s = items[idx].section { opts.section = s }
        liveStopFlags[id] = false
        notifyChanged()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.engine.downloadSingle(
                    url: url,
                    settings: settings,
                    options: opts,
                    shouldStopLive: { [weak self] in
                        MainActor.assumeIsolated { self?.liveStopFlags[id] == true }
                    },
                    onEvent: { [weak self] ev in
                        Task { @MainActor [weak self] in
                            self?.handleEvent(id: id, event: ev, settings: settings)
                        }
                    }
                )
            } catch is CancellationError {
                // Handled by pause/cancel
            } catch {
                await MainActor.run {
                    if let i = self.items.firstIndex(where: { $0.id == id }), self.items[i].state != .paused {
                        self.items[i].state = .failed
                        self.items[i].error = error.localizedDescription
                        self.items[i].speedBytesPerSec = 0
                        LibraryStore.shared.upsert(self.items[i])
                    }
                }
            }
            await MainActor.run {
                self.runningTasks.removeValue(forKey: id)
                self.liveStopFlags.removeValue(forKey: id)
                self.notifyChanged()
                self.pump()
            }
        }
        runningTasks[id] = task
    }

    private func handleEvent(id: String, event: DownloadEventPayload, settings: Settings) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .start:
            items[idx].state = .extracting
        case .info(let title, let site, let quality, let ext, let path, let isLive, let thumb, let dur):
            items[idx].title = title
            items[idx].site = site
            items[idx].quality = quality
            items[idx].ext = ext
            items[idx].path = path
            items[idx].isLive = isLive
            if let thumb { items[idx].thumbnail = thumb }
            if let dur { items[idx].duration = dur }
            items[idx].state = .downloading
            LibraryStore.shared.upsert(items[idx])
        case .progress(let frac, let done, let total, let speed, let eta, _):
            items[idx].state = .downloading
            items[idx].fraction = frac
            items[idx].downloadedBytes = done
            items[idx].totalBytes = total
            items[idx].speedBytesPerSec = speed
            items[idx].etaSeconds = eta
        case .process(let stage):
            items[idx].state = .processing
            items[idx].stage = stage
            items[idx].speedBytesPerSec = 0
        case .done(let path, let size, _):
            items[idx].state = .done
            items[idx].path = path
            items[idx].fraction = 1.0
            items[idx].downloadedBytes = size
            items[idx].totalBytes = size
            items[idx].speedBytesPerSec = 0
            items[idx].etaSeconds = nil
            items[idx].stage = nil
            items[idx].finishedAt = Date()
            LibraryStore.shared.upsert(items[idx])
            if settings.removeFinished {
                items.remove(at: idx)
                LibraryStore.shared.remove(id: id)
            }
            if settings.notify && !NSApp.isActive {
                NSSound.beep()
            }
        case .stopped:
            items[idx].state = .paused
            LibraryStore.shared.upsert(items[idx])
        case .error(let msg):
            items[idx].state = .failed
            items[idx].error = msg
            LibraryStore.shared.upsert(items[idx])
        }
        updateSystemPowerAndDock(settings: settings)
        notifyChanged()
    }

    private func updateSystemPowerAndDock(settings: Settings) {
        let active = items.filter { [.downloading, .extracting, .processing].contains($0.state) }
        // Dock badge
        if active.isEmpty {
            NSApp?.dockTile.badgeLabel = nil
        } else {
            let avgPct = Int((active.map(\.fraction).reduce(0, +) / Double(active.count) * 100).rounded())
            NSApp?.dockTile.badgeLabel = active.count == 1 ? "\(avgPct)%" : "\(active.count) · \(avgPct)%"
        }

        // Keep Mac awake via IOKit power assertion
        if !active.isEmpty && settings.keepAwake {
            if !hasSleepAssertion {
                let reason = "uBit is downloading media" as CFString
                if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &sleepAssertionID) == kIOReturnSuccess {
                    hasSleepAssertion = true
                }
            }
        } else if hasSleepAssertion {
            IOPMAssertionRelease(sleepAssertionID)
            hasSleepAssertion = false
        }
    }

    private func notifyChanged() {
        onChange?()
    }
}

// MARK: - Local IPC Bridge (`ubit open` / `ubit browse`)

public enum LocalIPC {
    public struct Message: Codable, Sendable {
        public var action: String // "open" or "browse"
        public var urls: [String]
        public init(action: String, urls: [String]) {
            self.action = action
            self.urls = urls
        }
    }

    public static func sendToRunningApp(_ msg: Message) -> Bool {
        let sockPath = AppPaths.ipcSocketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sockPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, b) in pathBytes.enumerated() { ptr[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
        guard connected, let payload = try? JSONEncoder().encode(msg) else { return false }
        _ = payload.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, payload.count)
        }
        return true
    }

    public static func startServer(onMessage: @escaping @Sendable (Message) -> Void) {
        try? AppPaths.ensureAppSupport()
        let sockPath = AppPaths.ipcSocketPath
        unlink(sockPath)

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sockPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(serverFD); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, b) in pathBytes.enumerated() { ptr[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, len) == 0 }
        }
        guard bound, listen(serverFD, 8) == 0 else { close(serverFD); return }

        DispatchQueue.global(qos: .utility).async {
            while true {
                let clientFD = accept(serverFD, nil, nil)
                if clientFD < 0 { continue }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(clientFD, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                close(clientFD)
                if let msg = try? JSONDecoder().decode(Message.self, from: data) {
                    onMessage(msg)
                }
            }
        }
    }
}
