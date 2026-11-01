import Foundation
import AppKit
import SwiftUI
import QuickLookUI
import UniformTypeIdentifiers

// MARK: - Persistent Disk + Memory Thumbnail Loader

@MainActor
public final class ThumbnailCache: ObservableObject {
    public static let shared = ThumbnailCache()
    @Published private var mem: [String: NSImage] = [:]
    private var inFlight = Set<String>()

    public func image(for urlString: String?) -> NSImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let cached = mem[urlString] { return cached }
        let diskFile = AppPaths.thumbCacheDir.appendingPathComponent("\(abs(urlString.hashValue)).jpg")
        if let data = try? Data(contentsOf: diskFile), let img = NSImage(data: data) {
            mem[urlString] = img
            return img
        }
        if inFlight.insert(urlString).inserted {
            Task.detached(priority: .utility) {
                guard let u = URL(string: urlString),
                      let (data, _) = try? await URLSession.shared.data(from: u),
                      let jpg = MediaConverter.normalizeThumbnailToJPEG(data, maxDimension: 640) else {
                    _ = await MainActor.run { self.inFlight.remove(urlString) }
                    return
                }
                try? AppPaths.ensureAppSupport()
                try? jpg.write(to: diskFile, options: .atomic)
                if let img = NSImage(data: jpg) {
                    await MainActor.run {
                        self.mem[urlString] = img
                        self.inFlight.remove(urlString)
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - Signature Grayscale-to-Vivid-Color Progress Artwork View

private struct ColorFillArtworkView: View {
    let thumbnailURL: String?
    let fraction: Double
    let duration: Double?
    @ObservedObject private var cache = ThumbnailCache.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let nsImg = cache.image(for: thumbnailURL) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .saturation(0.0)
                            .brightness(-0.08)

                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                            }
                    }
                }
            } else {
                Rectangle()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.35), .secondary.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
            }

            if let dur = duration, dur > 0 {
                Text(FormatHelpers.formatDuration(dur))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .frame(width: 96, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Quick Look Coordinator (`Space`)

@MainActor
public final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookCoordinator()
    private var previewURL: URL?

    public func toggle(filePath: String?) {
        guard let filePath, FileManager.default.fileExists(atPath: filePath) else { return }
        previewURL = URL(fileURLWithPath: filePath)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }
}

// MARK: - Main App ViewModel

public enum LibraryTab: String, CaseIterable {
    case all = "All"
    case videos = "Videos"
    case audio = "Audio"
    case failed = "Failed"
    case subs = "Subscriptions"
}

@MainActor
public final class MainAppViewModel: ObservableObject {
    @Published public var omniInput: String = ""
    @Published public var isFromClipboard: Bool = false
    @Published public var selectedTab: LibraryTab = .all
    @Published public var items: [LibraryItem] = []
    @Published public var subscriptions: [Subscription] = []
    @Published public var selectedItemID: String?
    @Published public var inspectedItem: LibraryItem?

    // Preview panel state
    @Published public var isProbingPreview: Bool = false
    @Published public var previewInfo: MediaInfo?
    @Published public var previewError: String?
    @Published public var chosenQuality: String = "best"
    @Published public var chosenSaveAs: String = "mp4"
    @Published public var chosenAudioOnly: Bool = false
    @Published public var chosenSubLangs: String = ""
    @Published public var trimStart: String = ""
    @Published public var trimEnd: String = ""
    @Published public var checkedEntryIDs: Set<String> = []
    @Published public var settings: Settings = Settings.load()

    private let engine = DownloadEngine()
    private var probeTask: Task<Void, Never>?
    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount

    public init() {
        self.items = QueueManager.shared.items
        self.subscriptions = SubscriptionStore.shared.all()
        QueueManager.shared.onChange = { [weak self] in
            guard let self else { return }
            self.items = QueueManager.shared.items
        }
    }

    public var looksLikeURL: Bool {
        let t = omniInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://") || (t.contains(".") && !t.contains(" ") && t.contains("/"))
    }

    public func onOmniChanged(_ newValue: String) {
        probeTask?.cancel()
        previewError = nil
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeURL else {
            previewInfo = nil
            isProbingPreview = false
            return
        }
        isProbingPreview = true
        let s = settings
        chosenAudioOnly = (s.mode == "audio")
        chosenQuality = s.quality
        chosenSaveAs = chosenAudioOnly ? s.audioFormat : s.videoFormat

        probeTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let info = try await engine.extract(url: trimmed, settings: s, options: DownloadRequestOptions.from(settings: s))
                guard !Task.isCancelled else { return }
                self.previewInfo = info
                self.checkedEntryIDs = Set(info.entries.map(\.id))
                self.isProbingPreview = false
            } catch {
                guard !Task.isCancelled else { return }
                self.previewInfo = nil
                self.previewError = error.localizedDescription
                self.isProbingPreview = false
            }
        }
    }

    public func submitOmnibox() {
        let trimmed = omniInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !looksLikeURL { return }

        var opts = DownloadRequestOptions.from(settings: settings)
        opts.audioOnly = chosenAudioOnly
        opts.maxQuality = chosenQuality
        opts.targetFormat = chosenSaveAs
        if !chosenSubLangs.isEmpty {
            opts.downloadSubtitles = true
            opts.subtitleLangs = chosenSubLangs
        }
        if !trimStart.isEmpty || !trimEnd.isEmpty {
            opts.section = SectionRange.parse("\(trimStart)-\(trimEnd)")
        }

        if let info = previewInfo, !info.entries.isEmpty && info.formats.isEmpty {
            opts.playlistTitle = info.title
            for entry in info.entries where checkedEntryIDs.contains(entry.id) {
                QueueManager.shared.enqueue(url: entry.url, title: entry.title, thumbnail: entry.thumbnail, optionsOverride: opts)
            }
        } else {
            QueueManager.shared.enqueue(url: trimmed, preExtracted: previewInfo, optionsOverride: opts)
        }

        omniInput = ""
        isFromClipboard = false
        previewInfo = nil
        previewError = nil
        trimStart = ""
        trimEnd = ""
    }

    public func subscribeCurrentPreview() {
        guard let info = previewInfo else { return }
        let s = settings
        let audio = chosenAudioOnly
        Task {
            if let _ = try? await SubscriptionStore.shared.add(url: info.webpageURL, audioOnly: audio, engine: engine, settings: s) {
                await MainActor.run {
                    self.subscriptions = SubscriptionStore.shared.all()
                    self.selectedTab = .subs
                    self.previewInfo = nil
                    self.omniInput = ""
                }
            }
        }
    }

    public func checkClipboardOnActivate() {
        guard settings.watchClipboard else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pb.changeCount
        guard omniInput.isEmpty, let copied = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              (copied.hasPrefix("https://") || copied.hasPrefix("http://")),
              !copied.contains(" "), copied.count < 500 else { return }
        isFromClipboard = true
        omniInput = copied
        onOmniChanged(copied)
    }

    public func pasteAndDownloadImmediately() {
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           (copied.hasPrefix("http://") || copied.hasPrefix("https://")) {
            QueueManager.shared.enqueue(url: copied)
        }
    }

    public var filteredItems: [LibraryItem] {
        let searchQuery = looksLikeURL ? "" : omniInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if !searchQuery.isEmpty && !item.title.lowercased().contains(searchQuery) && !item.site.lowercased().contains(searchQuery) {
                return false
            }
            switch selectedTab {
            case .all: return true
            case .videos: return !item.isAudio && item.state == .done
            case .audio: return item.isAudio && item.state == .done
            case .failed: return item.state == .failed
            case .subs: return false
            }
        }
    }

    public func checkSubscriptionsNow() {
        let s = settings
        Task {
            let found = await SubscriptionStore.shared.checkAll(engine: engine, settings: s)
            await MainActor.run {
                self.subscriptions = SubscriptionStore.shared.all()
                for (sub, entries) in found {
                    var opts = DownloadRequestOptions.from(settings: s)
                    opts.audioOnly = sub.audioOnly
                    opts.playlistTitle = sub.title
                    for e in entries {
                        QueueManager.shared.enqueue(url: e.url, title: e.title, thumbnail: e.thumbnail, optionsOverride: opts)
                    }
                }
            }
        }
    }
}

// MARK: - Main Window SwiftUI View

public struct MainWindowView: View {
    @ObservedObject var vm: MainAppViewModel
    @FocusState private var omniFocused: Bool

    public init(vm: MainAppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Subtle cover-art wash in header
            if let washURL = vm.previewInfo?.thumbnail ?? vm.items.first?.thumbnail,
               let nsImg = ThumbnailCache.shared.image(for: washURL) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 160)
                    .blur(radius: 42)
                    .opacity(0.18)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                // Top Omnibox Toolbar
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        if vm.isProbingPreview {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: vm.looksLikeURL ? "link" : "magnifyingglass")
                                .foregroundStyle(.secondary)
                        }

                        TextField("Paste a link to download, or search", text: $vm.omniInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($omniFocused)
                            .onChange(of: vm.omniInput) { _, val in vm.onOmniChanged(val) }
                            .onSubmit { vm.submitOmnibox() }

                        if vm.isFromClipboard {
                            Text("From clipboard")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }

                        if !vm.omniInput.isEmpty {
                            Button {
                                vm.omniInput = ""
                                vm.previewInfo = nil
                                vm.previewError = nil
                                vm.isFromClipboard = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Text("⌘L")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Button {
                        BrowserWindowController.shared.show(url: vm.looksLikeURL ? vm.omniInput : nil)
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 15))
                    }
                    .help("Open Built-in Media Browser (⌘B)")
                    .buttonStyle(.borderless)

                    Button {
                        SettingsWindowController.shared.show(vm: vm)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15))
                    }
                    .help("Settings (⌘,)")
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // Floating Link Preview Panel directly under omnibox
                if let info = vm.previewInfo {
                    previewCard(info)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                } else if let err = vm.previewError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.system(size: 12))
                            .lineLimit(2)
                        Spacer()
                        Button("Open in Browser") {
                            BrowserWindowController.shared.show(url: vm.omniInput)
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }

                // Library Filter Tabs
                HStack(spacing: 6) {
                    Text("Library")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.trailing, 6)

                    ForEach(LibraryTab.allCases, id: \.self) { tab in
                        Button {
                            vm.selectedTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11.5, weight: vm.selectedTab == tab ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(vm.selectedTab == tab ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    if vm.items.contains(where: { $0.state == .done }) {
                        Button("Clear Finished") {
                            QueueManager.shared.clearFinished()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider()

                // Main Content Area
                if vm.selectedTab == .subs {
                    subscriptionsListView
                } else if vm.filteredItems.isEmpty {
                    emptyStateView
                } else {
                    downloadsListView
                }

                Divider()

                // Footer Bar (Target Folder + Free Disk Space)
                footerBar
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .sheet(item: $vm.inspectedItem) { item in
            ItemInfoSheet(item: item)
        }
        .onDrop(of: [.url, .text], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: String.self) { str, _ in
                    if let str, (str.hasPrefix("http://") || str.hasPrefix("https://")) {
                        Task { @MainActor in
                            vm.omniInput = str.trimmingCharacters(in: .whitespacesAndNewlines)
                            vm.onOmniChanged(vm.omniInput)
                        }
                    }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private func previewCard(_ info: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ColorFillArtworkView(thumbnailURL: info.thumbnail ?? info.entries.first?.thumbnail, fraction: 1.0, duration: info.duration)

                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text([info.site, info.author].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let hint = info.signInHint {
                        Button(hint) {
                            BrowserWindowController.shared.show(url: info.webpageURL)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                    }
                }
                Spacer()

                if !info.entries.isEmpty {
                    Button("Subscribe") { vm.subscribeCurrentPreview() }
                        .controlSize(.small)
                }

                Button("Download") { vm.submitOmnibox() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }

            // Quality pills + Save As + Subtitles + Trim
            HStack(spacing: 8) {
                let heights = Array(Set(info.formats.compactMap(\.height))).sorted(by: >)
                ForEach(["best"] + heights.prefix(4).map(String.init), id: \.self) { q in
                    let isSel = !vm.chosenAudioOnly && vm.chosenQuality == q
                    Button(q == "best" ? "Best" : "\(q)p") {
                        vm.chosenAudioOnly = false
                        vm.chosenQuality = q
                        if ["m4a", "wav", "flac", "mp3", "opus"].contains(vm.chosenSaveAs) {
                            vm.chosenSaveAs = vm.settings.videoFormat
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isSel ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: Capsule())
                }

                Button("Audio") {
                    vm.chosenAudioOnly = true
                    vm.chosenSaveAs = vm.settings.audioFormat
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: vm.chosenAudioOnly ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(vm.chosenAudioOnly ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: Capsule())

                Spacer()

                Picker("Save as", selection: $vm.chosenSaveAs) {
                    if vm.chosenAudioOnly {
                        ForEach(["m4a", "wav", "flac", "aiff", "mp3", "opus"], id: \.self) { Text($0.uppercased()).tag($0) }
                    } else {
                        ForEach(["mp4", "mov", "mkv", "webm"], id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                }
                .labelsHidden()
                .frame(width: 82)
                .controlSize(.small)
            }

            if info.entries.isEmpty {
                HStack(spacing: 8) {
                    Text("Trim:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("0:00", text: $vm.trimStart)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                        .controlSize(.small)
                    Text("to")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("end", text: $vm.trimEnd)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                        .controlSize(.small)

                    if !info.subtitles.isEmpty {
                        Spacer()
                        let availLangs = Array(Set(info.subtitles.map(\.lang))).sorted().prefix(4).joined(separator: ",")
                        Text("Subs (\(info.subtitles.count)):")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField(availLangs, text: $vm.chosenSubLangs)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .controlSize(.small)
                    }
                }
            } else {
                // Playlist items checklist
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(vm.checkedEntryIDs.count) of \(info.entries.count) items selected")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button(vm.checkedEntryIDs.count == info.entries.count ? "Deselect All" : "Select All") {
                            if vm.checkedEntryIDs.count == info.entries.count { vm.checkedEntryIDs.removeAll() }
                            else { vm.checkedEntryIDs = Set(info.entries.map(\.id)) }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(info.entries, id: \.id) { entry in
                                Toggle(isOn: Binding(
                                    get: { vm.checkedEntryIDs.contains(entry.id) },
                                    set: { on in
                                        if on { vm.checkedEntryIDs.insert(entry.id) }
                                        else { vm.checkedEntryIDs.remove(entry.id) }
                                    }
                                )) {
                                    Text(entry.title)
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var downloadsListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(vm.filteredItems) { item in
                    DownloadCardRow(item: item, isSelected: vm.selectedItemID == item.id, onInspect: {
                        vm.inspectedItem = item
                    })
                    .onTapGesture { vm.selectedItemID = item.id }
                    .onTapGesture(count: 2) {
                        if let p = item.path, FileManager.default.fileExists(atPath: p) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: p))
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var subscriptionsListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(vm.subscriptions.count) Subscriptions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { vm.checkSubscriptionsNow() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if vm.subscriptions.isEmpty {
                Spacer()
                Text("Paste a YouTube, SoundCloud, or Bilibili channel/playlist link above and click Subscribe.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.subscriptions) { sub in
                            HStack(spacing: 12) {
                                ColorFillArtworkView(thumbnailURL: sub.thumbnail, fraction: 1.0, duration: nil)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sub.title).font(.system(size: 13, weight: .semibold))
                                    Text("\(sub.site) · \(sub.seenIDs.count) videos tracked · \(sub.audioOnly ? "Audio Only" : "Video")")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Unsubscribe") {
                                    SubscriptionStore.shared.remove(id: sub.id)
                                    vm.subscriptions = SubscriptionStore.shared.all()
                                }
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Paste or drop any link to download")
                .font(.system(size: 14, weight: .medium))
            Text("Try a demo video:")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([
                    ("Big Buck Bunny", "https://www.youtube.com/watch?v=aqz-KE-bpKQ"),
                    ("Sintel", "https://www.youtube.com/watch?v=eRsGyueVLvQ"),
                    ("Tears of Steel", "https://www.youtube.com/watch?v=R6MlUcmOul8"),
                ], id: \.0) { label, link in
                    Button(label) {
                        vm.omniInput = link
                        vm.onOmniChanged(link)
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footerBar: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: vm.settings.folder))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text((vm.settings.folder as NSString).abbreviatingWithTildeInPath)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: vm.settings.folder),
               let free = attrs[.systemFreeSize] as? Int64 {
                Text("\(FormatHelpers.formatBytes(free)) free")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private struct DownloadCardRow: View {
    let item: LibraryItem
    let isSelected: Bool
    let onInspect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ColorFillArtworkView(
                thumbnailURL: item.thumbnail,
                fraction: item.state == .done ? 1.0 : item.fraction,
                duration: item.duration
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                let metaParts = [item.site, item.author, item.quality, item.ext.uppercased()].compactMap { ($0?.isEmpty == false) ? $0 : nil }
                Text(metaParts.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                statusSubtitle

                if [.downloading, .processing, .paused].contains(item.state) {
                    ProgressView(value: max(0, min(1, item.fraction)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                switch item.state {
                case .downloading, .extracting, .queued:
                    Button {
                        QueueManager.shared.pause(id: item.id)
                    } label: {
                        Image(systemName: item.isLive ? "stop.circle.fill" : "pause.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.borderless)
                    .help(item.isLive ? "Stop & Save Live Recording" : "Pause")

                case .paused, .failed:
                    Button {
                        QueueManager.shared.resume(id: item.id)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.borderless)
                    .help("Resume / Retry")

                case .done:
                    Button {
                        if let p = item.path {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                        }
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")

                case .processing, .canceled:
                    EmptyView()
                }

                Button {
                    QueueManager.shared.cancelAndRemove(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from List")
            }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onDrag {
            if let p = item.path, FileManager.default.fileExists(atPath: p) {
                return NSItemProvider(object: URL(fileURLWithPath: p) as NSURL)
            }
            return NSItemProvider(object: item.url as NSString)
        }
        .contextMenu {
            if let p = item.path, FileManager.default.fileExists(atPath: p) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
                Button("Quick Look (Space)") {
                    QuickLookCoordinator.shared.toggle(filePath: p)
                }
            }
            Button("Get Info (⌘I)") { onInspect() }
            Button("Copy Source Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            if item.state == .queued || item.state == .paused {
                Button("Download Next") { QueueManager.shared.downloadNext(id: item.id) }
            }
            Divider()
            Button("Download Again (Audio Only)") {
                var opts = DownloadRequestOptions.from(settings: Settings.load())
                opts.audioOnly = true
                QueueManager.shared.enqueue(url: item.url, title: item.title, thumbnail: item.thumbnail, optionsOverride: opts)
            }
            Button("Remove from List") {
                QueueManager.shared.cancelAndRemove(id: item.id, moveFileToTrash: false)
            }
            if item.path != nil {
                Button("Move to Trash", role: .destructive) {
                    QueueManager.shared.cancelAndRemove(id: item.id, moveFileToTrash: true)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSubtitle: some View {
        switch item.state {
        case .queued:
            Text("Queued").font(.system(size: 11)).foregroundStyle(.secondary)
        case .extracting:
            Text("Looking up streams…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .downloading:
            let pct = "\(Int((item.fraction * 100).rounded()))%"
            let bytes = item.totalBytes > 0
                ? "\(FormatHelpers.formatBytes(item.downloadedBytes)) of \(FormatHelpers.formatBytes(item.totalBytes))"
                : FormatHelpers.formatBytes(item.downloadedBytes)
            let spd = item.speedBytesPerSec > 0 ? " · \(FormatHelpers.formatBytes(item.speedBytesPerSec))/s" : ""
            let eta = item.etaSeconds.map { " · \($0)s left" } ?? ""
            Text("\(pct)  \(bytes)\(spd)\(eta)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        case .processing:
            Text(item.stage ?? "Merging…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .paused:
            Text("Paused · \(FormatHelpers.formatBytes(item.downloadedBytes)) saved").font(.system(size: 11)).foregroundStyle(.orange)
        case .done:
            Text(FormatHelpers.formatBytes(item.totalBytes))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .failed:
            Text(item.error ?? "Download failed")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1)
        case .canceled:
            Text("Canceled").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct ItemInfoSheet: View {
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.system(size: 15, weight: .semibold))
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Site:").foregroundStyle(.secondary); Text(item.site) }
                if let a = item.author { GridRow { Text("Author:").foregroundStyle(.secondary); Text(a) } }
                if let q = item.quality { GridRow { Text("Quality:").foregroundStyle(.secondary); Text("\(q) (\(item.ext.uppercased()))") } }
                if item.totalBytes > 0 { GridRow { Text("Size:").foregroundStyle(.secondary); Text(FormatHelpers.formatBytes(item.totalBytes)) } }
                GridRow { Text("Source:").foregroundStyle(.secondary); Text(item.url).lineLimit(2).textSelection(.enabled) }
                if let p = item.path { GridRow { Text("Saved at:").foregroundStyle(.secondary); Text(p).lineLimit(2).textSelection(.enabled) } }
            }
            .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Settings Window (`⌘,`) — 100% Unlocked, Zero Paywalls

@MainActor
public final class SettingsWindowController {
    public static let shared = SettingsWindowController()
    private var window: NSWindow?

    public func show(vm: MainAppViewModel) {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "uBit Settings"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SettingsView(vm: vm))
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

private struct SettingsView: View {
    @ObservedObject var vm: MainAppViewModel
    @State private var cliInstallStatus: String = ""

    var body: some View {
        TabView {
            Form {
                HStack {
                    TextField("Save downloads to", text: $vm.settings.folder)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let u = panel.url {
                            vm.settings.folder = u.path
                            try? vm.settings.save()
                        }
                    }
                }
                TextField("Filename template", text: $vm.settings.template)
                Toggle("Subfolder per site", isOn: $vm.settings.siteFolders)
                Toggle("Subfolder per playlist", isOn: $vm.settings.playlistFolders)
                Toggle("Offer copied links from clipboard", isOn: $vm.settings.watchClipboard)
                Toggle("Keep Mac awake while downloading", isOn: $vm.settings.keepAwake)
                Toggle("Add finished downloads to Music / TV", isOn: $vm.settings.addToLibrary)
            }
            .padding(18)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Picker("Default mode", selection: $vm.settings.mode) {
                    Text("Video").tag("video")
                    Text("Audio Only").tag("audio")
                }
                Picker("Max quality", selection: $vm.settings.quality) {
                    ForEach(["best", "2160", "1440", "1080", "720", "480", "360"], id: \.self) {
                        Text($0 == "best" ? "Best available" : "\($0)p").tag($0)
                    }
                }
                Toggle("Prefer compatible H.264 + AAC in MP4", isOn: $vm.settings.compatible)
                Picker("Video container", selection: $vm.settings.videoFormat) {
                    ForEach(["mp4", "mov", "mkv", "webm"], id: \.self) { Text($0.uppercased()).tag($0) }
                }
                Picker("Audio format", selection: $vm.settings.audioFormat) {
                    ForEach(["m4a", "wav", "flac", "aiff", "mp3", "opus"], id: \.self) { Text($0.uppercased()).tag($0) }
                }
                Picker("YouTube SponsorBlock", selection: $vm.settings.sponsors) {
                    Text("Keep").tag("keep")
                    Text("Mark as Chapters").tag("mark")
                    Text("Remove Segments").tag("remove")
                }
                Toggle("Embed title, artist, chapters & artwork", isOn: $vm.settings.embedMetadata)
                Toggle("Download subtitles", isOn: $vm.settings.subtitles)
                TextField("Subtitle languages", text: $vm.settings.subtitleLangs)
            }
            .padding(18)
            .tabItem { Label("Formats", systemImage: "film") }

            Form {
                Stepper("Concurrent downloads: \(vm.settings.concurrent)", value: $vm.settings.concurrent, in: 1...16)
                Stepper("Connections per file: \(vm.settings.connections)", value: $vm.settings.connections, in: 1...32)
                TextField("Speed limit (e.g. 5M, 500K)", text: $vm.settings.rateLimit)
                TextField("Proxy (e.g. socks5://127.0.0.1:1080)", text: $vm.settings.proxy)
            }
            .padding(18)
            .tabItem { Label("Network", systemImage: "network") }

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Block ads and trackers in built-in Browser", isOn: $vm.settings.blockAds)
                Button("Sign Out Everywhere & Clear Browser Data") {
                    BrowserModel.clearAllBrowserData()
                }
                Divider()
                Text("Bookmarklets (drag or copy to your browser bookmarks bar):")
                    .font(.system(size: 12, weight: .semibold))
                Text("javascript:location.href='ubit://download?url='+encodeURIComponent(location.href)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Divider()
                HStack {
                    Button("Install `ubit` in /usr/local/bin") {
                        installCLISymlink()
                    }
                    if !cliInstallStatus.isEmpty {
                        Text(cliInstallStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .tabItem { Label("Browser & CLI", systemImage: "terminal") }
        }
        .onChange(of: vm.settings.mode) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.quality) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.compatible) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.videoFormat) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.audioFormat) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.concurrent) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.connections) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.sponsors) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.watchClipboard) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.keepAwake) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.siteFolders) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.playlistFolders) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.embedMetadata) { _, _ in try? vm.settings.save() }
        .onChange(of: vm.settings.subtitles) { _, _ in try? vm.settings.save() }
    }

    private func installCLISymlink() {
        guard let exe = Bundle.main.executablePath else { return }
        let dest = "/usr/local/bin/ubit"
        try? FileManager.default.removeItem(atPath: dest)
        do {
            try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: exe)
            cliInstallStatus = "Installed at /usr/local/bin/ubit"
        } catch {
            let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(exe)' /usr/local/bin/ubit\" with administrator privileges"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
            proc.waitUntilExit()
            cliInstallStatus = proc.terminationStatus == 0 ? "Installed at /usr/local/bin/ubit" : "Canceled"
        }
    }
}

// MARK: - AppKit Delegate, Menu Bar, Keyboard Shortcuts & Deep Links (`ubit://`)

@MainActor
public final class UBitAppDelegate: NSObject, NSApplicationDelegate {
    public let vm = MainAppViewModel()
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenus()
        showMainWindow()

        if vm.settings.menuBarIcon {
            setupStatusItem()
        }

        // Start local UNIX domain socket server for `ubit open` & `ubit browse`
        LocalIPC.startServer { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.handleIPC(msg)
            }
        }

        // Handle boot IPC passed via env when `ubit open` / `ubit browse` launched the app
        if let bootJSON = ProcessInfo.processInfo.environment["UBIT_BOOT_IPC"],
           let d = bootJSON.data(using: .utf8),
           let msg = try? JSONDecoder().decode(LocalIPC.Message.self, from: d) {
            handleIPC(msg)
        }

        // Auto-Quit smoke test hook when `UBIT_SMOKE_SCREENSHOT` is set
        if let shotPath = ProcessInfo.processInfo.environment["UBIT_SMOKE_SCREENSHOT"], !shotPath.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let win = self.mainWindow, let contentView = win.contentView {
                    let bounds = contentView.bounds
                    if let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) {
                        contentView.cacheDisplay(in: bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: shotPath))
                        }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        vm.checkClipboardOnActivate()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            // ubit://download?url=... or ubit://browse?url=... or downbit://...
            let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
            let paramURL = comps?.queryItems?.first(where: { $0.name == "url" })?.value ?? u.absoluteString
            if u.host == "browse" {
                BrowserWindowController.shared.show(url: paramURL)
            } else if paramURL.hasPrefix("http") {
                QueueManager.shared.enqueue(url: paramURL)
            }
        }
    }

    private func handleIPC(_ msg: LocalIPC.Message) {
        showMainWindow()
        if msg.action == "browse" {
            BrowserWindowController.shared.show(url: msg.urls.first)
        } else {
            for u in msg.urls {
                QueueManager.shared.enqueue(url: u)
            }
        }
    }

    public func showMainWindow() {
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "uBit"
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1.0)
        win.center()
        win.isReleasedWhenClosed = false
        let hosted = MainWindowView(vm: vm)
            .background(Color(red: 0.06, green: 0.06, blue: 0.07))
            .preferredColorScheme(.dark)
        win.contentView = NSHostingView(rootView: hosted)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.mainWindow = win
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "uBit")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open uBit", action: #selector(menuShowMain), keyEquivalent: "")
        menu.addItem(withTitle: "Download Copied Link", action: #selector(menuPasteDownload), keyEquivalent: "")
        menu.addItem(withTitle: "Open Browser", action: #selector(menuOpenBrowser), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pause All", action: #selector(menuPauseAll), keyEquivalent: "")
        menu.addItem(withTitle: "Resume All", action: #selector(menuResumeAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit uBit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for m in menu.items where m.action != #selector(NSApplication.terminate(_:)) { m.target = self }
        item.menu = menu
        self.statusItem = item
    }

    private func setupMainMenus() {
        let mainMenu = NSMenu()

        // App Menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About uBit \(UBIT_VERSION)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let prefs = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit uBit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File Menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let dlClip = NSMenuItem(title: "Download Copied Link", action: #selector(menuPasteDownload), keyEquivalent: "V")
        dlClip.keyEquivalentModifierMask = [.command, .shift]
        dlClip.target = self
        fileMenu.addItem(dlClip)

        let openBr = NSMenuItem(title: "Open Browser", action: #selector(menuOpenBrowser), keyEquivalent: "b")
        openBr.target = self
        fileMenu.addItem(openBr)

        let showFolder = NSMenuItem(title: "Show Downloads Folder", action: #selector(menuShowFolder), keyEquivalent: "O")
        showFolder.keyEquivalentModifierMask = [.command, .shift]
        showFolder.target = self
        fileMenu.addItem(showFolder)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit Menu (needed for standard Cmd+C / Cmd+V / Cmd+A in TextFields!)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Downloads Menu
        let dlItem = NSMenuItem()
        let dlMenu = NSMenu(title: "Downloads")
        let pAll = NSMenuItem(title: "Pause All", action: #selector(menuPauseAll), keyEquivalent: "p")
        pAll.keyEquivalentModifierMask = [.command, .option]
        pAll.target = self
        dlMenu.addItem(pAll)

        let rAll = NSMenuItem(title: "Resume All", action: #selector(menuResumeAll), keyEquivalent: "r")
        rAll.keyEquivalentModifierMask = [.command, .option]
        rAll.target = self
        dlMenu.addItem(rAll)

        let clr = NSMenuItem(title: "Clear Finished", action: #selector(menuClearFinished), keyEquivalent: "K")
        clr.keyEquivalentModifierMask = [.command, .shift]
        clr.target = self
        dlMenu.addItem(clr)

        let ql = NSMenuItem(title: "Quick Look Selected", action: #selector(menuQuickLook), keyEquivalent: " ")
        ql.keyEquivalentModifierMask = []
        ql.target = self
        dlMenu.addItem(ql)
        dlItem.submenu = dlMenu
        mainMenu.addItem(dlItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuShowMain() { showMainWindow() }
    @objc private func menuOpenSettings() { SettingsWindowController.shared.show(vm: vm) }
    @objc private func menuPasteDownload() { vm.pasteAndDownloadImmediately() }
    @objc private func menuOpenBrowser() { BrowserWindowController.shared.show() }
    @objc private func menuPauseAll() { QueueManager.shared.pauseAll() }
    @objc private func menuResumeAll() { QueueManager.shared.resumeAll() }
    @objc private func menuClearFinished() { QueueManager.shared.clearFinished() }
    @objc private func menuShowFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: vm.settings.folder)) }
    @objc private func menuQuickLook() {
        if let id = vm.selectedItemID, let item = vm.items.first(where: { $0.id == id }) {
            QuickLookCoordinator.shared.toggle(filePath: item.path)
        }
    }
}
