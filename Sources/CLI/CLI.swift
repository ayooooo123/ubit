import Foundation
import AppKit

private final class InterruptController: @unchecked Sendable {
    static let shared = InterruptController()
    private let lock = NSLock()
    private var count = 0
    private var activeTaskCancel: (() -> Void)?

    func install() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInteractive))
        src.setEventHandler { [weak self] in
            self?.handleSIGINT()
        }
        src.resume()
        // retain source for process lifetime
        _ = Unmanaged.passRetained(src as AnyObject)
    }

    func setCancelHandler(_ fn: (() -> Void)?) {
        lock.lock()
        activeTaskCancel = fn
        lock.unlock()
    }

    var interruptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private func handleSIGINT() {
        lock.lock()
        count += 1
        let c = count
        let cb = activeTaskCancel
        lock.unlock()
        if c == 1 {
            cb?()
        } else {
            fputs("\nDiscarded.\n", stderr)
            _exit(130)
        }
    }
}

public enum CLIRunner {

    public static func shouldRunCLI(arguments: [String]) -> Bool {
        // Ignore macOS Finder / LaunchServices `-psn_...` or `-NSDocumentRevisionsDebugMode` flags when launching .app
        let args = Array(arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        return !args.isEmpty
    }

    public static func run(arguments: [String]) async -> Int32 {
        let rawArgs = Array(arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        guard let first = rawArgs.first else { return 0 }

        InterruptController.shared.install()

        switch first {
        case "-h", "--help", "help":
            printMainHelp()
            return 0
        case "-v", "--version", "version":
            print("ubit \(UBIT_VERSION)")
            return 0
        case "--llms", "llms":
            printLLMManifest()
            return 0
        case "get":
            return await runGet(Array(rawArgs.dropFirst()))
        case "info":
            return await runInfo(Array(rawArgs.dropFirst()), formatsOnly: false)
        case "formats":
            return await runInfo(Array(rawArgs.dropFirst()), formatsOnly: true)
        case "list":
            return runList(Array(rawArgs.dropFirst()))
        case "subs":
            return await runSubs(Array(rawArgs.dropFirst()))
        case "settings":
            return runSettings(Array(rawArgs.dropFirst()))
        case "sites":
            return runSites(Array(rawArgs.dropFirst()))
        case "open":
            return runOpenOrBrowse(action: "open", args: Array(rawArgs.dropFirst()))
        case "browse":
            return runOpenOrBrowse(action: "browse", args: Array(rawArgs.dropFirst()))
        default:
            if first.hasPrefix("-") {
                // Allow `ubit -a <url>` shorthand directly!
                return await runGet(rawArgs)
            }
            // Bare URL(s): `ubit <url>...` runs `get` just like `downbit <url>`!
            return await runGet(rawArgs)
        }
    }

    // MARK: - `ubit get`

    private static func runGet(_ args: [String]) async -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            printGetHelp()
            return 0
        }

        let settings = Settings.load()
        var opts = DownloadRequestOptions.from(settings: settings)
        var urls: [String] = []
        var inputFile: String?
        var itemsSpec: String?
        var forcePlaylist = false
        var noPlaylist = false
        var jsonMode = false
        var quietMode = false
        var noLibrary = false

        var i = 0
        func nextVal(_ flag: String) -> String? {
            guard i + 1 < args.count else {
                fputs("ubit get: missing value for \(flag)\n", stderr)
                return nil
            }
            i += 1
            return args[i]
        }

        while i < args.count {
            let a = args[i]
            switch a {
            case "-o", "--output":
                guard let v = nextVal(a) else { return 2 }
                opts.outputDir = (v as NSString).expandingTildeInPath
            case "-a", "--audio":
                opts.audioOnly = true
            case "--mp3":
                opts.audioOnly = true
                opts.targetFormat = "mp3"
            case "--to":
                guard let v = nextVal(a) else { return 2 }
                opts.targetFormat = v.lowercased()
                if ["m4a", "mp3", "opus", "flac", "wav", "aiff"].contains(v.lowercased()) {
                    opts.audioOnly = true
                }
            case "-q", "--quality":
                guard let v = nextVal(a) else { return 2 }
                opts.maxQuality = v.lowercased().replacingOccurrences(of: "p", with: "")
            case "-f", "--format":
                guard let v = nextVal(a) else { return 2 }
                opts.formatSelector = v
            case "--compatible":
                opts.preferCompatible = true
            case "--best-codec":
                opts.preferCompatible = false
            case "--subs":
                opts.downloadSubtitles = true
            case "--sub-langs":
                guard let v = nextVal(a) else { return 2 }
                opts.downloadSubtitles = true
                opts.subtitleLangs = v
            case "--sub-files":
                opts.externalSubtitles = true
            case "-i", "--input":
                guard let v = nextVal(a) else { return 2 }
                inputFile = v
            case "--playlist":
                forcePlaylist = true
            case "--no-playlist":
                noPlaylist = true
            case "--items":
                guard let v = nextVal(a) else { return 2 }
                itemsSpec = v
            case "--section":
                guard let v = nextVal(a), let sec = SectionRange.parse(v) else {
                    fputs("ubit get: invalid --section (expected e.g. 1:00-2:30)\n", stderr)
                    return 2
                }
                opts.section = sec
            case "--sponsors-remove":
                guard let v = nextVal(a) else { return 2 }
                opts.sponsorMode = "remove"
                opts.sponsorCategories = v
            case "--sponsors-mark":
                guard let v = nextVal(a) else { return 2 }
                opts.sponsorMode = "mark"
                opts.sponsorCategories = v
            case "--keep-sponsors":
                opts.sponsorMode = "keep"
            case "--title":
                guard let v = nextVal(a) else { return 2 }
                opts.customTitle = v
            case "--name":
                guard let v = nextVal(a) else { return 2 }
                opts.filenameTemplate = v
            case "--rate":
                guard let v = nextVal(a) else { return 2 }
                opts.rateLimit = v
            case "--connections":
                guard let v = nextVal(a), let n = Int(v), (1...32).contains(n) else {
                    fputs("ubit get: --connections must be 1..32\n", stderr)
                    return 2
                }
                opts.connections = n
            case "--cookies":
                guard let v = nextVal(a) else { return 2 }
                opts.cookieSource = v
            case "--cookies-from-browser":
                guard let v = nextVal(a) else { return 2 }
                opts.cookieSource = v
            case "--no-cookies":
                opts.cookieSource = "none"
            case "--proxy":
                guard let v = nextVal(a) else { return 2 }
                opts.proxy = v
            case "--referer":
                guard let v = nextVal(a) else { return 2 }
                opts.referer = v
            case "--user-agent":
                guard let v = nextVal(a) else { return 2 }
                opts.userAgent = v
            case "--header":
                guard let v = nextVal(a), let colon = v.firstIndex(of: ":") else {
                    fputs("ubit get: --header expects 'Key: Value'\n", stderr)
                    return 2
                }
                let k = String(v[..<colon]).trimmingCharacters(in: .whitespaces)
                let val = String(v[v.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                opts.extraHeaders[k] = val
            case "--json":
                jsonMode = true
            case "--quiet", "-s":
                quietMode = true
            case "--no-library":
                noLibrary = true
            default:
                if a.hasPrefix("-") {
                    fputs("ubit get: unknown flag \(a)\n", stderr)
                    return 2
                }
                urls.append(a)
            }
            i += 1
        }

        if let inputFile {
            let content: String?
            if inputFile == "-" {
                content = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
            } else {
                content = try? String(contentsOfFile: (inputFile as NSString).expandingTildeInPath, encoding: .utf8)
            }
            guard let content else {
                fputs("ubit get: cannot read input file \(inputFile)\n", stderr)
                return 1
            }
            for line in content.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !t.hasPrefix("#") { urls.append(t) }
            }
        }

        guard !urls.isEmpty else {
            printGetHelp()
            return 2
        }

        let engine = DownloadEngine()
        var anyFailed = false
        let isTTY = isatty(STDERR_FILENO) != 0

        for var targetURL in urls {
            if noPlaylist, let u = URL(string: targetURL), u.host?.contains("youtube") == true,
               let vid = YouTubeExtractor.extractVideoID(from: u) {
                targetURL = "https://www.youtube.com/watch?v=\(vid)"
            } else if forcePlaylist, let u = URL(string: targetURL),
                      let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
                      let lid = comps.queryItems?.first(where: { $0.name == "list" })?.value {
                targetURL = "https://www.youtube.com/playlist?list=\(lid)"
            }

            // Probe first in case targetURL is a playlist / channel
            do {
                let initialInfo = try await engine.extract(url: targetURL, settings: settings, options: opts)
                if !initialInfo.entries.isEmpty && initialInfo.formats.isEmpty {
                    let chosenEntries = filterPlaylistEntries(initialInfo.entries, spec: itemsSpec)
                    var itemOpts = opts
                    itemOpts.playlistTitle = initialInfo.title
                    for entry in chosenEntries {
                        let code = await executeOneDownload(
                            url: entry.url,
                            preExtracted: nil,
                            engine: engine,
                            settings: settings,
                            options: itemOpts,
                            jsonMode: jsonMode,
                            quietMode: quietMode,
                            noLibrary: noLibrary,
                            isTTY: isTTY
                        )
                        if code == 130 { return 130 }
                        if code != 0 { anyFailed = true }
                    }
                    continue
                }

                let code = await executeOneDownload(
                    url: targetURL,
                    preExtracted: initialInfo,
                    engine: engine,
                    settings: settings,
                    options: opts,
                    jsonMode: jsonMode,
                    quietMode: quietMode,
                    noLibrary: noLibrary,
                    isTTY: isTTY
                )
                if code == 130 { return 130 }
                if code != 0 { anyFailed = true }
            } catch {
                anyFailed = true
                if jsonMode {
                    emitNDJSON(["event": "error", "url": targetURL, "error": error.localizedDescription])
                } else {
                    fputs("error: \(error.localizedDescription)\n", stderr)
                }
            }
        }

        return anyFailed ? 1 : 0
    }

    private static func executeOneDownload(
        url: String,
        preExtracted: MediaInfo?,
        engine: DownloadEngine,
        settings: Settings,
        options: DownloadRequestOptions,
        jsonMode: Bool,
        quietMode: Bool,
        noLibrary: Bool,
        isTTY: Bool
    ) async -> Int32 {
        final class RunState: @unchecked Sendable {
            let lock = NSLock()
            var libItem: LibraryItem
            var stop = false
            var isLive: Bool
            init(url: String, audioOnly: Bool, isLive: Bool) {
                self.libItem = LibraryItem(url: url, state: .downloading, isAudio: audioOnly)
                self.isLive = isLive
            }
            func mutateItem(_ fn: (inout LibraryItem) -> Void) -> LibraryItem {
                lock.lock()
                defer { lock.unlock() }
                fn(&libItem)
                return libItem
            }
        }
        let state = RunState(url: url, audioOnly: options.audioOnly, isLive: preExtracted?.isLive ?? false)
        let workTask = Task<URL, Error> {
            try await engine.downloadSingle(
                url: url,
                preExtracted: preExtracted,
                settings: settings,
                options: options,
                shouldStopLive: { state.stop },
                onEvent: { ev in
                    switch ev {
                    case .start(let u):
                        if jsonMode { emitNDJSON(["event": "start", "url": u]) }
                    case .info(let title, let site, let quality, let ext, let path, let live, let thumb, let dur):
                        state.isLive = live
                        let updated = state.mutateItem { item in
                            item.title = title
                            item.site = site
                            item.quality = quality
                            item.ext = ext
                            item.path = path
                            item.isLive = live
                            item.thumbnail = thumb
                            item.duration = dur
                        }
                        if !noLibrary { LibraryStore.shared.upsert(updated) }
                        if jsonMode {
                            emitNDJSON([
                                "event": "info",
                                "title": title,
                                "site": site,
                                "quality": quality,
                                "ext": ext,
                                "path": path,
                                "live": live,
                            ])
                        } else if !quietMode {
                            fputs("▸ \(title) [\(site) · \(quality)]\n", stderr)
                        }
                    case .progress(let frac, let done, let total, let speed, let eta, let recSec):
                        if jsonMode {
                            var obj: [String: Any] = [
                                "event": "progress",
                                "fraction": Double((frac * 1000).rounded()) / 1000.0,
                                "downloaded": done,
                                "total": total,
                                "speed": speed,
                            ]
                            if let eta { obj["eta"] = eta }
                            if let recSec { obj["live"] = true; obj["seconds"] = recSec }
                            emitNDJSON(obj)
                        } else if !quietMode && isTTY {
                            if let recSec {
                                fputs("\r\u{001B}[K  ● LIVE  \(FormatHelpers.formatDuration(recSec)) recorded · \(FormatHelpers.formatBytes(done)) (Ctrl-C to save)", stderr)
                            } else {
                                let pct = Int((frac * 100).rounded())
                                let barW = 24
                                let filled = max(0, min(barW, Int((frac * Double(barW)).rounded())))
                                let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barW - filled)
                                let spd = speed > 0 ? " · \(FormatHelpers.formatBytes(speed))/s" : ""
                                let etaStr = eta.map { " · \($0)s left" } ?? ""
                                fputs("\r\u{001B}[K  [\(bar)] \(String(format: "%3d%%", pct))  \(FormatHelpers.formatBytes(done))\(total > 0 ? " / \(FormatHelpers.formatBytes(total))" : "")\(spd)\(etaStr)", stderr)
                            }
                        }
                    case .process(let stage):
                        if jsonMode {
                            emitNDJSON(["event": "process", "stage": stage])
                        } else if !quietMode && isTTY {
                            fputs("\r\u{001B}[K  ⚙ \(stage)…", stderr)
                        }
                    case .done(let path, let size, let secs):
                        let updated = state.mutateItem { item in
                            item.state = .done
                            item.path = path
                            item.downloadedBytes = size
                            item.totalBytes = size
                            item.fraction = 1.0
                            item.finishedAt = Date()
                        }
                        if !noLibrary { LibraryStore.shared.upsert(updated) }
                        if jsonMode {
                            emitNDJSON([
                                "event": "done",
                                "path": path,
                                "size": size,
                                "seconds": Double((secs * 100).rounded()) / 100.0,
                            ])
                        } else if quietMode {
                            print(path)
                        } else {
                            if isTTY { fputs("\r\u{001B}[K", stderr) }
                            fputs("✓ Saved \(path) (\(FormatHelpers.formatBytes(size)) in \(String(format: "%.1fs", secs)))\n", stderr)
                        }
                    case .stopped, .error:
                        break
                    }
                }
            )
        }

        InterruptController.shared.setCancelHandler {
            if state.isLive {
                state.stop = true
                if jsonMode { emitNDJSON(["event": "stopping"]) }
            } else {
                workTask.cancel()
            }
        }
        defer { InterruptController.shared.setCancelHandler(nil) }

        do {
            _ = try await workTask.value
            return 0
        } catch is CancellationError {
            let updated = state.mutateItem { $0.state = .paused }
            if !noLibrary { LibraryStore.shared.upsert(updated) }
            if jsonMode {
                emitNDJSON(["event": "stopped", "url": url])
            } else {
                if isTTY { fputs("\r\u{001B}[K", stderr) }
                fputs("Stopped (run again to resume).\n", stderr)
            }
            return 130
        } catch {
            if InterruptController.shared.interruptCount > 0 {
                if jsonMode { emitNDJSON(["event": "stopped", "url": url]) }
                return 130
            }
            let updated = state.mutateItem {
                $0.state = .failed
                $0.error = error.localizedDescription
            }
            if !noLibrary { LibraryStore.shared.upsert(updated) }
            if jsonMode {
                emitNDJSON(["event": "error", "url": url, "error": error.localizedDescription])
            } else {
                if isTTY { fputs("\r\u{001B}[K", stderr) }
                fputs("error: \(error.localizedDescription)\n", stderr)
            }
            return 1
        }
    }

    private static func filterPlaylistEntries(_ entries: [PlaylistEntry], spec: String?) -> [PlaylistEntry] {
        guard let spec, !spec.isEmpty else { return entries }
        var indices = Set<Int>()
        for part in spec.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 1 {
                indices.insert(bounds[0])
            } else if bounds.count == 2 && bounds[1] >= bounds[0] {
                for k in bounds[0]...bounds[1] { indices.insert(k) }
            }
        }
        return entries.enumerated().compactMap { (i, e) in indices.contains(i + 1) ? e : nil }
    }

    // MARK: - `ubit info` & `ubit formats`

    private static func runInfo(_ args: [String], formatsOnly: Bool) async -> Int32 {
        let jsonMode = args.contains("--json")
        var cookieSrc = Settings.load().cookies
        var targetURL: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--json" { /* handled */ }
            else if a == "--cookies" && i + 1 < args.count { i += 1; cookieSrc = args[i] }
            else if a == "--no-cookies" { cookieSrc = "none" }
            else if !a.hasPrefix("-") && targetURL == nil { targetURL = a }
            i += 1
        }
        guard let url = targetURL else {
            fputs("Usage: ubit \(formatsOnly ? "formats" : "info") <url> [--json]\n", stderr)
            return 2
        }

        let settings = Settings.load()
        var opts = DownloadRequestOptions.from(settings: settings)
        opts.cookieSource = cookieSrc
        let engine = DownloadEngine()

        do {
            let info = try await engine.extract(url: url, settings: settings, options: opts)
            if info.isDRM && info.formats.isEmpty {
                fputs("error: this media is protected by DRM and can't be downloaded\n", stderr)
                return 1
            }
            if jsonMode {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if formatsOnly {
                    let data = try enc.encode(info.formats)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    let data = try enc.encode(info)
                    print(String(decoding: data, as: UTF8.self))
                }
                return 0
            }

            if !formatsOnly {
                print("Title:    \(info.title)")
                print("Site:     \(info.site)")
                if let a = info.author { print("Author:   \(a)") }
                if let d = info.duration { print("Duration: \(FormatHelpers.formatDuration(d))") }
                if info.isLive { print("Live:     yes") }
                if !info.subtitles.isEmpty {
                    let langs = Array(Set(info.subtitles.map(\.lang))).sorted().joined(separator: ", ")
                    print("Subs:     \(langs)")
                }
                if !info.entries.isEmpty {
                    print("\nItems (\(info.entries.count)):")
                    for (idx, e) in info.entries.enumerated() {
                        let dur = e.duration.map { " (\(FormatHelpers.formatDuration($0)))" } ?? ""
                        let num = String(idx + 1).padding(toLength: 3, withPad: " ", startingAt: 0)
                        print("  \(num). \(e.title)\(dur)  \(e.url)")
                    }
                    return 0
                }
                print("")
            }

            print("\(pad("ID", 14)) \(pad("EXT", 6)) \(pad("QUALITY", 12)) \(pad("CODECS", 14)) \(pad("SIZE", 12)) PROTO")
            for f in info.formats {
                let sz = f.filesize.map(FormatHelpers.formatBytes) ?? (f.bitrate.map { "\($0 / 1000) kbps" } ?? "—")
                print("\(pad(f.id, 14)) \(pad(f.ext, 6)) \(pad(f.displayQuality, 12)) \(pad(f.shortCodec, 14)) \(pad(sz, 12)) \(f.proto.rawValue)")
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - `ubit list`, `ubit subs`, `ubit settings`, `ubit sites`, `ubit open`, `ubit browse`

    private static func runList(_ args: [String]) -> Int32 {
        let items = LibraryStore.shared.all()
        if args.contains("--json") {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(items) { print(String(decoding: d, as: UTF8.self)) }
            return 0
        }
        if items.isEmpty {
            print("No downloads yet.")
            return 0
        }
        for item in items {
            let sz = item.totalBytes > 0 ? FormatHelpers.formatBytes(item.totalBytes) : ""
            print("[\(pad(item.state.rawValue, 11))] \(item.title)  \(sz)  \(item.path ?? item.url)")
        }
        return 0
    }

    private static func runSubs(_ args: [String]) async -> Int32 {
        let jsonMode = args.contains("--json")
        let quietMode = args.contains("--quiet")
        let clean = args.filter { !$0.hasPrefix("-") }
        let subcmd = clean.first ?? "list"
        let settings = Settings.load()
        let engine = DownloadEngine()

        switch subcmd {
        case "list":
            let all = SubscriptionStore.shared.all()
            if jsonMode {
                let enc = JSONEncoder()
                enc.dateEncodingStrategy = .iso8601
                if let d = try? enc.encode(all) { print(String(decoding: d, as: UTF8.self)) }
                return 0
            }
            if all.isEmpty {
                print("No subscriptions. Add one with `ubit subs add <channel-or-playlist-url>`.")
                return 0
            }
            for (idx, s) in all.enumerated() {
                print("\(idx + 1). \(s.title) [\(s.site)] — \(s.seenIDs.count) known items — \(s.url)")
            }
            return 0

        case "add":
            guard clean.count >= 2 else {
                fputs("Usage: ubit subs add <url> [-a]\n", stderr)
                return 2
            }
            let audioOnly = args.contains("-a") || args.contains("--audio")
            do {
                let sub = try await SubscriptionStore.shared.add(url: clean[1], audioOnly: audioOnly, engine: engine, settings: settings)
                if jsonMode {
                    emitNDJSON(["event": "subscribed", "title": sub.title, "url": sub.url, "seen": sub.seenIDs.count])
                } else {
                    print("Subscribed to \(sub.title) (\(sub.seenIDs.count) existing items marked seen).")
                }
                return 0
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                return 1
            }

        case "remove":
            guard clean.count >= 2, let num = Int(clean[1]) else {
                fputs("Usage: ubit subs remove <number>\n", stderr)
                return 2
            }
            if let removed = SubscriptionStore.shared.remove(atIndex: num) {
                if !quietMode { print("Unsubscribed from \(removed.title).") }
                return 0
            }
            fputs("error: no subscription #\(num)\n", stderr)
            return 1

        case "check":
            let discovered = await SubscriptionStore.shared.checkAll(engine: engine, settings: settings)
            var failed = false
            for (sub, entries) in discovered {
                var opts = DownloadRequestOptions.from(settings: settings)
                if sub.audioOnly { opts.audioOnly = true }
                opts.playlistTitle = sub.title
                for entry in entries {
                    let rc = await executeOneDownload(
                        url: entry.url,
                        preExtracted: nil,
                        engine: engine,
                        settings: settings,
                        options: opts,
                        jsonMode: jsonMode,
                        quietMode: quietMode,
                        noLibrary: false,
                        isTTY: isatty(STDERR_FILENO) != 0
                    )
                    if rc != 0 { failed = true }
                }
            }
            if discovered.isEmpty && !quietMode && !jsonMode {
                print("All subscriptions are up to date.")
            }
            return failed ? 1 : 0

        default:
            fputs("Usage: ubit subs [add <url> | remove <n> | check]\n", stderr)
            return 2
        }
    }

    private static func runSettings(_ args: [String]) -> Int32 {
        let jsonMode = args.contains("--json")
        let positional = args.filter { !$0.hasPrefix("-") }
        var settings = Settings.load()

        if positional.isEmpty {
            if jsonMode, let d = try? JSONEncoder().encode(settings) {
                print(String(decoding: d, as: UTF8.self))
                return 0
            }
            for e in settings.allEntries() {
                print("\(pad(e.key, 20)) \(pad(e.value, 28)) \(e.description)")
            }
            print("\nChange one with `ubit settings <name> <value>`. \(AppPaths.settingsFile.path)")
            return 0
        }

        if positional.count == 1 {
            guard let found = settings.allEntries().first(where: { $0.key == positional[0] }) else {
                fputs("error: unknown setting '\(positional[0])'\n", stderr)
                return 2
            }
            print(found.value)
            return 0
        }

        let key = positional[0]
        let val = positional.dropFirst().joined(separator: " ")
        guard settings.setByKey(key, value: val) else {
            fputs("error: invalid setting or value '\(key) = \(val)'\n", stderr)
            return 2
        }
        do {
            try settings.save()
            print("\(key) = \(val)")
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runSites(_ args: [String]) -> Int32 {
        let names = ExtractorRegistry.supportedSiteNames
        if args.contains("--json"), let d = try? JSONEncoder().encode(names) {
            print(String(decoding: d, as: UTF8.self))
            return 0
        }
        print("Sites with dedicated native extractors (\(names.count)):")
        for n in names { print("  \(n)") }
        print("\nAny other page works via HTML5/OpenGraph/JSON-LD/HLS/DASH or uBit's built-in Browser (⌘B).")
        return 0
    }

    private static func runOpenOrBrowse(action: String, args: [String]) -> Int32 {
        let urls = args.filter { !$0.hasPrefix("-") }
        let msg = LocalIPC.Message(action: action, urls: urls)
        if LocalIPC.sendToRunningApp(msg) {
            return 0
        }
        // Launch self in background GUI mode and deliver via environment / socket
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        var env = ProcessInfo.processInfo.environment
        if let encoded = try? JSONEncoder().encode(msg), let str = String(data: encoded, encoding: .utf8) {
            env["UBIT_BOOT_IPC"] = str
        }
        proc.environment = env
        proc.arguments = []
        try? proc.run()
        return 0
    }

    private static func emitNDJSON(_ dict: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(d)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func printMainHelp() {
        print("""
        ubit \(UBIT_VERSION) — ultra-small native macOS media downloader & CLI (zero Pro paywalls).

        Usage
          ubit                          Open the native macOS app
          ubit <url>...                 Download, as `ubit get`
          ubit get <url>... [flags]     Download media (see `ubit get --help`)
          ubit info <url> [--json]      Title, formats, subtitles, playlist items
          ubit formats <url> [--json]   List all stream formats for `-f`
          ubit list [--json]            Downloads across the app and CLI
          ubit subs [add|remove|check]  Subscribe to channels and playlists
          ubit settings [name [value]]  View or modify shared app/CLI settings
          ubit sites [--json]           List all \(ExtractorRegistry.supportedSiteNames.count) built-in site extractors
          ubit open [url...]            Send links to the app's download queue
          ubit browse [url]             Open the app's media-sniffer browser
          ubit version
          ubit --llms                   Print machine-readable contract for AI agents

        Exit codes: 0 done, 1 failed, 2 bad usage, 130 stopped with Ctrl-C (run again to resume).
        """)
    }

    private static func printGetHelp() {
        print("""
        Usage: ubit get <url>... [flags]

        What to download
          -o, --output DIR              Folder to save into (default: settings folder)
          -a, --audio                   Audio only (M4A by default)
              --to FORMAT               mp4, m4a, mov, wav, aiff, flac (native zero-FFmpeg),
                                        or mkv, webm, mp3, opus (uses system ffmpeg if present)
              --mp3                     Audio as MP3
          -q, --quality Q               best, 2160, 1440, 1080, 720, 480, 360
          -f, --format IDS              Exact format ID(s), e.g. 299+140 or 140
              --compatible              Prefer H.264/AAC in MP4 (default)
              --best-codec              Allow AV1/VP9/Opus highest resolution
              --subs                    Download subtitles (--sub-langs en,de or all)
              --sub-files               Save .vtt beside video instead of muxing inside MP4
          -i, --input FILE              Read URLs one per line (- reads stdin)
              --playlist / --no-playlist
              --items 1,3,5-7           Select specific playlist items
              --section 1:00-2:30       Keyframe-accurate byte-range clip trim
              --sponsors-remove CATS    Excise SponsorBlock segments (default, all, or list)
              --sponsors-mark CATS      Mark SponsorBlock segments as MP4 chapters
              --keep-sponsors           Keep sponsors regardless of settings
              --title TEXT              Override media title
              --name TEMPLATE           {title} {site} {author} {quality} {date} {id}
              --rate 2M                 Bandwidth limit
              --connections N           Work-stealing range connections (1-32, default 8)

        Network & Output
              --cookies FILE            Netscape cookie file (default: built-in browser)
              --cookies-from-browser B  firefox (or path)
              --no-cookies              Send no cookies
              --proxy URL               socks5://127.0.0.1:1080 or http://127.0.0.1:8080
              --referer URL             Custom Referer header
              --user-agent UA           Custom User-Agent
              --header "K: V"           Extra HTTP header
              --json                    Stream NDJSON events (start, info, progress, process, done, error, stopped)
              --quiet                   Print only saved file paths
              --no-library              Omit from app library
        """)
    }

    private static func printLLMManifest() {
        print("""
        # uBit (\(UBIT_VERSION)) — Agent CLI Contract

        Binary: `ubit` (also inside `uBit.app/Contents/MacOS/ubit`). Zero external dependencies required for MP4, M4A, MOV, WAV, AIFF, FLAC.

        ## Commands
        - `ubit get <url>... [flags]` — Download video/audio. Prefer `--json` (NDJSON events on stdout) or `--quiet` (prints only final saved file path(s), one per line).
        - `ubit info <url> --json` — Probe metadata (`id`, `title`, `site`, `author`, `duration`, `isLive`, `isDRM`, `formats`, `subtitles`, `chapters`, `entries`) without downloading.
        - `ubit formats <url> --json` — Return JSON array of `MediaFormat` objects (`id`, `ext`, `proto`, `vcodec`, `acodec`, `width`, `height`, `fps`, `bitrate`, `filesize`).
        - `ubit list --json` — Return JSON array of library/queue items (`id`, `url`, `title`, `state`, `path`, `downloadedBytes`, `totalBytes`).
        - `ubit subs [list|add <url>|remove <n>|check] [--json] [--quiet]` — Manage channel/playlist subscriptions.
        - `ubit settings [key [value]] [--json]` — Read or mutate persistent settings (`\(AppPaths.settingsFile.path)`).
        - `ubit sites --json` — Return JSON array of \(ExtractorRegistry.supportedSiteNames.count) built-in site extractors.
        - `ubit open <url>...` / `ubit browse <url>` — Dispatch URLs over UNIX socket IPC (`\(AppPaths.ipcSocketPath)`) to the GUI app or WebKit media-sniffer browser.

        ## High-Leverage Flags for Agents (`ubit get`)
        - `--json` — Emit one JSON object per line on stdout:
          - `{"event":"start","url":"..."}`
          - `{"event":"info","ext":"mp4","live":false,"path":"/abs/path.mp4","quality":"1080p60","site":"YouTube","title":"..."}`
          - `{"event":"progress","downloaded":1048576,"eta":4,"fraction":0.25,"speed":2097152,"total":4194304}`
          - `{"event":"process","stage":"Merging"}`
          - `{"event":"done","path":"/abs/path.mp4","seconds":1.84,"size":4194304}`
          - `{"event":"error","error":"...","url":"..."}`
          - `{"event":"stopped","url":"..."}`
        - `--quiet` — Suppress progress bars; print ONLY saved absolute file paths to stdout (ideal for command substitution `FILE=$(ubit get --quiet ...)`).
        - `--no-library` — Ephemeral run; do not append agent scratch downloads to the user's GUI library.
        - `--section START-END` — Keyframe-accurate clip trim (e.g. `0:30-1:15` or `90-135`). Uses `sidx` HTTP byte-range planning so a 15s clip from a 2h video downloads only ~2–4 MB.
        - `-a --to wav` — Extract 16-bit 44.1 kHz stereo PCM `.wav` natively via macOS AudioToolbox (zero FFmpeg) for ASR/transcription pipelines.
        - `-q <best|2160|1440|1080|720|480|360>` / `-f <vid+aid>` — Bound resolution or select exact stream IDs.
        - `--subs --sub-langs en --sub-files` — Download WebVTT `.vtt` subtitle sidecar files alongside media.
        - `--sponsors-remove default` / `--sponsors-mark default` — Strip or chapter-mark SponsorBlock segments on YouTube.
        - `UBIT_CONFIG_DIR=/tmp/agent-ubit` — Environment variable to isolate settings, cookies, and state per agent sandbox.

        ## Exit Codes
        - `0` — All requested URLs completed
        - `1` — Extraction, network, DRM, or muxing failure
        - `2` — Invalid CLI flags/arguments
        - `130` — Interrupted (`SIGINT`); `.part` + `.part.json` state preserved for instant resume on identical re-run
        """)
    }
}
