import SwiftUI
import WebKit

enum HugoPreviewResourcePolicy {
    private static let YouTubeHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "youtube-nocookie.com",
        "www.youtube-nocookie.com"
    ]

    static func allowsTopLevelNavigation(_ url: URL, localPort: Int?) -> Bool {
        url.scheme?.lowercased() == "about" || isLocalPreview(url, localPort: localPort)
    }

    static func allowsEmbeddedNavigation(_ url: URL, localPort: Int?) -> Bool {
        isLocalPreview(url, localPort: localPort) || isYouTubeResource(url)
    }

    static func contentRuleList(port: Int) -> String {
        let allowURLFilters = [
            "^http://127\\.0\\.0\\.1:\(port)/",
            "^https://(www\\.)?youtube\\.com/",
            "^https://(www\\.)?youtube-nocookie\\.com/",
            "^https://([A-Za-z0-9-]+\\.)?ytimg\\.com/",
            "^https://([A-Za-z0-9-]+\\.)?googlevideo\\.com/",
            "^https://cdn\\.jsdelivr\\.net/npm/mermaid@11/"
        ]
        let rules: [[String: Any]] = [
            [
                "trigger": ["url-filter": ".*"],
                "action": ["type": "block"]
            ]
        ] + allowURLFilters.map { filter in
            [
                "trigger": ["url-filter": filter],
                "action": ["type": "ignore-previous-rules"]
            ]
        }

        guard let encoded = try? JSONSerialization.data(withJSONObject: rules) else {
            return #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func isLocalPreview(_ url: URL, localPort: Int?) -> Bool {
        url.scheme?.lowercased() == "http"
            && url.host?.lowercased() == "127.0.0.1"
            && url.port == localPort
    }

    private static func isYouTubeResource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return YouTubeHosts.contains(host)
            || isSubdomain(of: "ytimg.com", host: host)
            || isSubdomain(of: "googlevideo.com", host: host)
            || isMermaidResource(url, host: host)
    }

    private static func isMermaidResource(_ url: URL, host: String) -> Bool {
        host == "cdn.jsdelivr.net" && url.path.hasPrefix("/npm/mermaid@11/")
    }

    private static func isSubdomain(of domain: String, host: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

struct HugoPreviewPane: View {
    @ObservedObject var controller: HugoPreviewController

    var body: some View {
        previewContent
            .frame(minWidth: 340, maxHeight: .infinity)
            .clipped()
    }

    @ViewBuilder
    private var previewContent: some View {
        switch controller.state {
        case .idle, .preparing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Hugo Previewを準備しています…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hugo Previewを準備しています")
        case .ready(let url):
            RestrictedPreviewWebView(
                url: url,
                revision: controller.revision,
                controller: controller
            )
                .accessibilityLabel("記事プレビュー")
        case .failed(let failure):
            ContentUnavailableView {
                Label("Previewを表示できません", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
                    .textSelection(.enabled)
            } actions: {
                if failure.canRepairDate {
                    Button("日付を修正して保存") {
                        controller.repairDateAndRetry()
                    }
                    .help("月または日だけがゼロ埋めされていない date を、安全なISO 8601形式へ修正して元の記事へ保存します")
                    .accessibilityLabel("日付を修正して保存")
                }
                Button("再試行") { controller.retry() }
                    .buttonStyle(.borderedProminent)
                    .help("Hugo Previewの生成をもう一度試す")
            }
        }
    }

}

private struct RestrictedPreviewWebView: NSViewRepresentable {
    let url: URL
    let revision: Int
    @ObservedObject var controller: HugoPreviewController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        // YouTube's iframe player requires JavaScript. Network access remains restricted
        // to the local Hugo server and the minimum YouTube resource allowlist below.
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.update(url: url, revision: revision)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(url: url, revision: revision)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        private var isRuleReady = false
        private var pendingURL: URL?
        private var pendingRevision = 0
        private var loadedURL: URL?
        private var loadedRevision = -1
        private var allowedPort: Int?
        private var pendingScrollPosition: ScrollPosition?
        private var pendingScrollGeneration: Int?
        private var loadGeneration = 0

        private func prepareContentRules(port: Int) {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "NKJBlogPosterLocalPreviewOnly-\(port)",
                encodedContentRuleList: HugoPreviewResourcePolicy.contentRuleList(port: port)
            ) { [weak self] ruleList, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.allowedPort == port, let ruleList else { return }
                    self.webView?.configuration.userContentController.removeAllContentRuleLists()
                    self.webView?.configuration.userContentController.add(ruleList)
                    self.isRuleReady = true
                    self.loadIfNeeded()
                }
            }
        }

        func update(url: URL, revision: Int) {
            pendingURL = url
            pendingRevision = revision
            if allowedPort != url.port, let port = url.port {
                allowedPort = port
                // The top-level navigation delegate already permits only this
                // loopback origin. Do not leave the preview as a blank WebKit
                // surface while the asynchronous content-rule compiler runs.
                isRuleReady = true
                loadedURL = nil
            }
            loadIfNeeded()
        }

        private func loadIfNeeded() {
            guard isRuleReady, let webView, let pendingURL else { return }
            guard loadedURL != pendingURL || loadedRevision != pendingRevision else { return }
            loadedURL = pendingURL
            loadedRevision = pendingRevision
            loadGeneration += 1
            let generation = loadGeneration
            webView.evaluateJavaScript("JSON.stringify({ x: window.scrollX || 0, y: window.scrollY || 0 })") { [weak self, weak webView] value, _ in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView, generation == self.loadGeneration else { return }
                    self.pendingScrollPosition = Self.scrollPosition(from: value)
                    self.pendingScrollGeneration = generation
                    var request = URLRequest(url: pendingURL)
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    webView.load(request)
                }
            }
        }

        private static func scrollPosition(from value: Any?) -> ScrollPosition? {
            guard let string = value as? String,
                  let data = string.data(using: .utf8),
                  let position = try? JSONDecoder().decode(ScrollPosition.self, from: data) else {
                return nil
            }
            return position
        }

        private struct ScrollPosition: Decodable {
            let x: Double
            let y: Double
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard let position = pendingScrollPosition,
                  let generation = pendingScrollGeneration,
                  generation == loadGeneration else { return }
            pendingScrollPosition = nil
            pendingScrollGeneration = nil
            restore(position, in: webView, for: generation)
        }

        private func restore(_ position: ScrollPosition, in webView: WKWebView, for generation: Int) {
            let script = "window.scrollTo(\(position.x), \(position.y));"
            webView.evaluateJavaScript(script)

            // Theme images, syntax highlighting, and embedded content can change the
            // document height after navigation finishes. Reapply the exact same offset
            // after those asynchronous layout passes, unless a newer reload superseded it.
            for delay in [80, 280] {
                Task { @MainActor [weak self, weak webView] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard let self, let webView, generation == self.loadGeneration else { return }
                    _ = try? await webView.evaluateJavaScript(script)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let target = navigationAction.request.url else {
                return .cancel
            }
            let isEmbeddedFrame = navigationAction.targetFrame?.isMainFrame == false
            let isAllowed = isEmbeddedFrame
                ? HugoPreviewResourcePolicy.allowsEmbeddedNavigation(target, localPort: allowedPort)
                : HugoPreviewResourcePolicy.allowsTopLevelNavigation(target, localPort: allowedPort)
            return isAllowed ? .allow : .cancel
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}
