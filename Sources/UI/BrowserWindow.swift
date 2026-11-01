import Foundation
import AppKit
import WebKit
import SwiftUI

public struct SniffedMediaItem: Identifiable, Hashable, Sendable {
    public var id: String { url }
    public var url: String
    public var kind: String     // "HLS", "DASH", "MP4", "WEBM", "AUDIO"
    public var title: String
    public var pageURL: String
}

@MainActor
public final class BrowserModel: ObservableObject {
    @Published public var addressText: String = "https://www.youtube.com"
    @Published public var pageTitle: String = "Browser"
    @Published public var isLoading: Bool = false
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var detectedMedia: [SniffedMediaItem] = []
    @Published public var toastMessage: String?

    fileprivate weak var webView: WKWebView?

    public func navigate(to raw: String) {
        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if !target.contains("://") {
            if target.contains(".") && !target.contains(" ") {
                target = "https://" + target
            } else {
                let q = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target
                target = "https://duckduckgo.com/?q=\(q)"
            }
        }
        guard let u = URL(string: target) else { return }
        addressText = u.absoluteString
        detectedMedia.removeAll()
        webView?.load(URLRequest(url: u))
    }

    public func addDetected(url: String, kind: String) {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
        // Ignore tiny tracking pixels or segment fragments when master playlist is already captured
        let low = url.lowercased()
        if low.contains("doubleclick.net") || low.contains("googlesyndication") || low.contains("/pagead/") { return }
        if (low.hasSuffix(".ts") || low.contains(".m4s?")) && detectedMedia.contains(where: { $0.kind == "HLS" || $0.kind == "DASH" }) {
            return
        }
        guard !detectedMedia.contains(where: { $0.url == url }) else { return }
        let cleanPageTitle = pageTitle.isEmpty ? (URL(string: url)?.lastPathComponent ?? "Stream") : pageTitle
        detectedMedia.insert(
            SniffedMediaItem(url: url, kind: kind, title: cleanPageTitle, pageURL: addressText),
            at: 0
        )
    }

    public func downloadSniffed(_ item: SniffedMediaItem) {
        var opts = DownloadRequestOptions.from(settings: Settings.load())
        opts.referer = item.pageURL
        opts.customTitle = item.title
        QueueManager.shared.enqueue(url: item.url, title: item.title, optionsOverride: opts)
        showToast("Added \"\(item.title.prefix(36))\" to Downloads")
    }

    public func downloadCurrentPage() {
        guard !addressText.isEmpty else { return }
        exportCookiesNow()
        QueueManager.shared.enqueue(url: addressText, title: pageTitle)
        showToast("Added page to Downloads")
    }

    public func exportCookiesNow() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            try? CookieVault.writeNetscapeFile(cookies, to: AppPaths.cookiesFile)
        }
    }

    public static func clearAllBrowserData() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {}
        }
        try? FileManager.default.removeItem(at: AppPaths.cookiesFile)
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.toastMessage == msg { self.toastMessage = nil }
        }
    }
}

private final class SnifferWebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var model: BrowserModel?

    init(model: BrowserModel) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model else { return }
        if message.name == "ubitMedia", let dict = message.body as? [String: Any],
           let u = dict["url"] as? String, let kind = dict["kind"] as? String {
            Task { @MainActor in model.addDetected(url: u, kind: kind) }
        } else if message.name == "ubitRoute", let href = message.body as? String {
            Task { @MainActor in
                if model.addressText != href {
                    model.addressText = href
                    model.detectedMedia.removeAll()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            model?.isLoading = true
            if let u = webView.url?.absoluteString { model?.addressText = u }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            model?.isLoading = false
            model?.canGoBack = webView.canGoBack
            model?.canGoForward = webView.canGoForward
            if let u = webView.url?.absoluteString { model?.addressText = u }
            if let t = webView.title, !t.isEmpty { model?.pageTitle = t }
            model?.exportCookiesNow()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let u = http.url?.absoluteString {
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if ct.contains("mpegurl") {
                await MainActor.run { model?.addDetected(url: u, kind: "HLS") }
            } else if ct.contains("dash+xml") {
                await MainActor.run { model?.addDetected(url: u, kind: "DASH") }
            } else if ct.hasPrefix("video/") {
                await MainActor.run { model?.addDetected(url: u, kind: "MP4") }
            } else if ct.hasPrefix("audio/") {
                await MainActor.run { model?.addDetected(url: u, kind: "AUDIO") }
            }
        }
        return .allow
    }
}

private struct SnifferWebViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: BrowserModel

    private static let snifferJS = """
    (() => {
      if (window.__ubitSnifferInstalled) return;
      window.__ubitSnifferInstalled = true;
      const post = (url, kind) => {
        try {
          if (!url || typeof url !== 'string' || url.startsWith('blob:') || url.startsWith('data:')) return;
          const abs = new URL(url, location.href).href;
          window.webkit.messageHandlers.ubitMedia.postMessage({ url: abs, kind });
        } catch {}
      };
      const classify = (u, ct, bodyHead) => {
        const low = (u || '').toLowerCase();
        const c = (ct || '').toLowerCase();
        if (low.includes('.m3u8') || c.includes('mpegurl') || (bodyHead && bodyHead.startsWith('#EXTM3U'))) return 'HLS';
        if (low.includes('.mpd') || c.includes('dash+xml') || (bodyHead && bodyHead.includes('<MPD'))) return 'DASH';
        if (/\\.(mp4|mov)(\\?|$)/i.test(low) || c.startsWith('video/mp4')) return 'MP4';
        if (/\\.webm(\\?|$)/i.test(low) || c.startsWith('video/webm')) return 'WEBM';
        if (/\\.(m4a|mp3|opus|flac|wav)(\\?|$)/i.test(low) || c.startsWith('audio/')) return 'AUDIO';
        return null;
      };

      const origFetch = window.fetch;
      window.fetch = async function(...args) {
        const reqUrl = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
        const k0 = classify(reqUrl, '', '');
        if (k0) post(reqUrl, k0);
        const res = await origFetch.apply(this, args);
        try {
          const ct = res.headers.get('content-type') || '';
          let k = classify(res.url || reqUrl, ct, '');
          if (!k && (ct.includes('text/plain') || ct.includes('octet-stream') || ct === '')) {
            const clone = res.clone();
            clone.text().then(t => {
              const k2 = classify(res.url || reqUrl, ct, t.slice(0, 128).trim());
              if (k2) post(res.url || reqUrl, k2);
            }).catch(() => {});
          } else if (k) {
            post(res.url || reqUrl, k);
          }
        } catch {}
        return res;
      };

      const origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        this.__ubitUrl = url;
        const k = classify(String(url || ''), '', '');
        if (k) post(String(url), k);
        this.addEventListener('load', () => {
          try {
            const ct = this.getResponseHeader('content-type') || '';
            const head = typeof this.responseText === 'string' ? this.responseText.slice(0, 128).trim() : '';
            const k2 = classify(this.responseURL || String(this.__ubitUrl || ''), ct, head);
            if (k2) post(this.responseURL || String(this.__ubitUrl), k2);
          } catch {}
        });
        return origOpen.call(this, method, url, ...rest);
      };

      const scanMediaElements = () => {
        document.querySelectorAll('video, audio, source').forEach(el => {
          const src = el.currentSrc || el.src;
          if (src && !src.startsWith('blob:')) {
            post(src, classify(src, '', '') || (el.tagName === 'AUDIO' ? 'AUDIO' : 'MP4'));
          }
        });
      };
      setInterval(scanMediaElements, 1200);

      // Follow SPA pushState/replaceState address changes (e.g. YouTube video-to-video navigation)
      let lastHref = location.href;
      setInterval(() => {
        if (location.href !== lastHref) {
          lastHref = location.href;
          try { window.webkit.messageHandlers.ubitRoute.postMessage(lastHref); } catch {}
        }
      }, 400);
    })();
    """

    private static let builtinAdblockJSON = """
    [
      {"trigger":{"url-filter":"doubleclick\\\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googlesyndication\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googleadservices\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"youtube\\\\.com/api/stats/ads"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"youtube\\\\.com/pagead/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adservice\\\\.google\\\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"scorecardresearch\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"amazon-adsystem\\\\.com"},"action":{"type":"block"}}
    ]
    """

    func makeCoordinator() -> SnifferWebViewCoordinator {
        SnifferWebViewCoordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "ubitMedia")
        ucc.add(context.coordinator, name: "ubitRoute")
        ucc.addUserScript(WKUserScript(source: Self.snifferJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc

        if Settings.load().blockAds {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ubit-core-adblock",
                encodedContentRuleList: Self.builtinAdblockJSON
            ) { list, _ in
                if let list {
                    Task { @MainActor in
                        model.webView?.configuration.userContentController.add(list)
                    }
                }
            }
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = HTTPClient.defaultBrowserUA
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        model.webView = wv
        if let u = URL(string: model.addressText) {
            wv.load(URLRequest(url: u))
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

public struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Browser Toolbar
            HStack(spacing: 8) {
                Button(action: { model.webView?.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .buttonStyle(.borderless)

                Button(action: { model.webView?.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .buttonStyle(.borderless)

                Button(action: { model.webView?.reload() }) {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                TextField("Enter page URL or search", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.navigate(to: model.addressText) }

                Button("Download Page") {
                    model.downloadCurrentPage()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            HSplitView {
                ZStack(alignment: .bottom) {
                    SnifferWebViewRepresentable(model: model)
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                    if let toast = model.toastMessage {
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 16)
                            .transition(.opacity)
                    }
                }

                // Right Side Panel: Media on This Page
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Media on This Page")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if !model.detectedMedia.isEmpty {
                            Button("Download All") {
                                for m in model.detectedMedia { model.downloadSniffed(m) }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                    }
                    .padding(12)

                    Divider()

                    if model.detectedMedia.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.and.magnifyingglass")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                            Text("Play a video or audio stream on the page — every HLS, DASH, MP4, and audio stream it loads appears here ready to download.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(model.detectedMedia) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(item.kind)
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                                            Text(URL(string: item.url)?.host ?? "")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Spacer()
                                            Button {
                                                model.downloadSniffed(item)
                                            } label: {
                                                Image(systemName: "arrow.down.circle.fill")
                                                    .font(.system(size: 15))
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        Text(item.url)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                    }
                                    .padding(8)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            .padding(10)
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                .background(.thinMaterial)
            }
        }
    }
}

@MainActor
public final class BrowserWindowController {
    public static let shared = BrowserWindowController()
    public let model = BrowserModel()
    private var window: NSWindow?

    public func show(url: String? = nil) {
        if let url, !url.isEmpty {
            model.navigate(to: url)
        }
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "uBit Browser — Sign In & Media Sniffer"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: BrowserView(model: model))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}
