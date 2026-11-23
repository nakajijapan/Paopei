import AppKit
import SwiftUI
import WebKit

struct PreviewWorkspacePane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var previewController: HugoPreviewController
    @ObservedObject var workspace: PreviewWorkspaceStore

    @ObservedObject private var browserTabs: BrowserTabStore

    init(previewController: HugoPreviewController, workspace: PreviewWorkspaceStore) {
        self.previewController = previewController
        self.workspace = workspace
        _browserTabs = ObservedObject(wrappedValue: workspace.browserTabs)
    }

    var body: some View {
        NativePreviewWorkspaceContainer(
            previewController: previewController,
            workspace: workspace,
            model: model
        )
            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Owns the WebKit view and its tab chrome in one AppKit hierarchy. A SwiftUI
/// overlay is not sufficient here: WKWebView is composited above adjacent
/// SwiftUI views and can otherwise hide the controls.
private struct NativePreviewWorkspaceContainer: NSViewRepresentable {
    @ObservedObject var previewController: HugoPreviewController
    @ObservedObject var workspace: PreviewWorkspaceStore
    let model: AppModel

    func makeNSView(context: Context) -> PreviewWorkspaceContainerView {
        PreviewWorkspaceContainerView(
            previewRootView: previewContent,
            browserRootView: browserContent,
            workspace: workspace,
            previewController: previewController
        )
    }

    func updateNSView(_ nsView: PreviewWorkspaceContainerView, context: Context) {
        nsView.update(
            workspace: workspace,
            previewController: previewController
        )
    }

    private var previewContent: AnyView {
        AnyView(HugoPreviewPane(controller: previewController))
    }

    private var browserContent: AnyView {
        AnyView(
            BrowserPreviewPane(tabs: workspace.browserTabs)
                .environmentObject(model)
        )
    }
}

/// The WebKit and text editor views are AppKit surfaces. Their compositor can
/// draw above SwiftUI siblings, so all workspace chrome lives in this same
/// AppKit hierarchy and the hosted content is physically placed below it.
private final class PreviewWorkspaceContainerView: NSView {
    private let previewHost: NSHostingView<AnyView>
    private let browserHost: NSHostingView<AnyView>
    private let tabStrip = NativeWorkspaceTabStrip()
    private let modeHeader = NativeWorkspaceModeHeader()

    init(
        previewRootView: AnyView,
        browserRootView: AnyView,
        workspace: PreviewWorkspaceStore,
        previewController: HugoPreviewController
    ) {
        previewHost = NSHostingView(rootView: previewRootView)
        browserHost = NSHostingView(rootView: browserRootView)
        super.init(frame: .zero)
        wantsLayer = true
        for host in [previewHost, browserHost] {
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            addSubview(host)
        }
        addSubview(modeHeader)
        addSubview(tabStrip)
        update(
            workspace: workspace,
            previewController: previewController
        )
    }

    required init?(coder: NSCoder) { nil }

    func update(
        workspace: PreviewWorkspaceStore,
        previewController: HugoPreviewController
    ) {
        // Keep both hosting views attached. Removing the browser host destroys its
        // WKWebViews, which loses the current page, back/forward history, and
        // in-page state whenever the user returns from Preview. The hosted views
        // observe their stores directly, so they do not need to be recreated here.
        previewHost.isHidden = !workspace.isPreviewSelected
        browserHost.isHidden = workspace.isPreviewSelected
        tabStrip.update(workspace: workspace)
        modeHeader.update(workspace: workspace, previewController: previewController)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    private func layoutChrome() {
        let tabHeight: CGFloat = 48
        let headerHeight: CGFloat = 44
        let contentHeight = max(0, bounds.height - tabHeight - headerHeight)
        let contentFrame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        previewHost.frame = contentFrame
        browserHost.frame = contentFrame
        modeHeader.frame = NSRect(x: 0, y: contentHeight, width: bounds.width, height: headerHeight)
        tabStrip.frame = NSRect(
            x: 0,
            y: max(0, bounds.height - tabHeight),
            width: bounds.width,
            height: tabHeight
        )
    }
}

private final class NativeWorkspaceTabStrip: NSVisualEffectView {
    private let stack = NSStackView()
    private weak var workspace: PreviewWorkspaceStore?

    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        stack.orientation = .horizontal
        // Keep a compact gutter so the selected tab's rounded blue surface
        // remains visually independent from its neighbours.
        stack.spacing = 4
        stack.alignment = .centerY
        addSubview(stack)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // A six-point vertical gutter gives each tab balanced breathing room
        // within the strip above the browser controls.
        stack.frame = NSRect(x: 4, y: 6, width: max(0, bounds.width - 8), height: 36)
    }

    func update(workspace: PreviewWorkspaceStore) {
        self.workspace = workspace
        stack.arrangedSubviews.forEach { subview in
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let preview = NativeWorkspaceTabItemView(
            title: "Preview",
            systemImage: "safari",
            isSelected: workspace.isPreviewSelected,
            close: nil,
            select: { [weak self] in self?.selectPreview() }
        )
        stack.addArrangedSubview(preview)

        for tab in workspace.browserTabs.tabs {
            let item = NativeWorkspaceTabItemView(
                title: tab.displayTitle,
                systemImage: "globe",
                isSelected: workspace.isBrowserSelected(tab.id),
                close: { [weak self] in self?.closeBrowser(tab.id) },
                select: { [weak self] in self?.selectBrowser(tab.id) }
            )
            item.toolTip = tab.displayTitle
            stack.addArrangedSubview(item)
        }

        let add = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新規タブ") ?? NSImage(),
            target: self,
            action: #selector(addBrowserTab)
        )
        add.bezelStyle = .inline
        add.isBordered = false
        add.contentTintColor = .secondaryLabelColor
        add.toolTip = "新規タブ（Command＋T）"
        add.setAccessibilityLabel("新規タブ")
        add.setFrameSize(NSSize(width: 32, height: 32))
        stack.addArrangedSubview(add)
    }

    @objc private func selectPreview() { workspace?.selectPreview() }

    private func selectBrowser(_ tabID: UUID) { workspace?.selectBrowser(tabID) }

    private func closeBrowser(_ tabID: UUID) { workspace?.closeBrowserTab(tabID) }

    @objc private func addBrowserTab() { workspace?.addBrowserTab() }
}

/// Browser-style tab chrome. Keeping selection and dismissal within one view
/// makes the hit areas match the visual tab rather than looking like adjacent
/// toolbar controls.
private final class NativeWorkspaceTabItemView: NSView {
    private let title: String
    private let selectAction: () -> Void
    private let closeAction: (() -> Void)?
    private let selectButton = NSButton()
    private let closeButton = NSButton()

    init(
        title: String,
        systemImage: String,
        isSelected: Bool,
        close: (() -> Void)?,
        select: @escaping () -> Void
    ) {
        self.title = title
        selectAction = select
        closeAction = close
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0
        // Match the sidebar selection affordance: a selected tab is filled
        // with the same accent blue, not outlined in blue.
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.windowBackgroundColor.withAlphaComponent(0.58).cgColor

        selectButton.title = title
        selectButton.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        selectButton.imagePosition = .imageLeading
        selectButton.imageScaling = .scaleProportionallyDown
        selectButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        selectButton.lineBreakMode = .byTruncatingTail
        selectButton.bezelStyle = .inline
        selectButton.isBordered = false
        selectButton.contentTintColor = isSelected ? .white : .secondaryLabelColor
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        selectButton.setAccessibilityLabel("\(title)タブ")
        selectButton.setAccessibilityHelp("このタブを表示します")
        addSubview(selectButton)

        if close != nil {
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "タブを閉じる")
            closeButton.imageScaling = .scaleProportionallyDown
            closeButton.bezelStyle = .inline
            closeButton.isBordered = false
            closeButton.contentTintColor = isSelected ? .white : .secondaryLabelColor
            closeButton.target = self
            closeButton.action = #selector(closeTab)
            closeButton.toolTip = "\(title)を閉じる（Command＋W）"
            closeButton.setAccessibilityLabel("\(title)を閉じる")
            addSubview(closeButton)
        }

        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let titleWidth = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        ]).width
        let controlsWidth: CGFloat = closeAction == nil ? 42 : 66
        return NSSize(width: min(max(titleWidth + controlsWidth, 144), 224), height: 36)
    }

    override func layout() {
        super.layout()
        let closeWidth: CGFloat = closeAction == nil ? 0 : 28
        selectButton.frame = NSRect(x: 10, y: 4, width: max(0, bounds.width - 16 - closeWidth), height: 28)
        closeButton.frame = NSRect(x: bounds.width - 34, y: 4, width: 28, height: 28)
    }

    @objc private func selectTab() { selectAction() }

    @objc private func closeTab() { closeAction?() }
}

private final class NativeWorkspaceModeHeader: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "Preview")
    private let reloadButton = NSButton()
    private weak var workspace: PreviewWorkspaceStore?
    private weak var previewController: HugoPreviewController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .contentBackground
        blendingMode = .withinWindow
        state = .active
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        addSubview(titleLabel)
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "プレビューを再読み込み")
        reloadButton.bezelStyle = .texturedRounded
        reloadButton.target = self
        reloadButton.action = #selector(reloadPreview)
        reloadButton.toolTip = "プレビューを再読み込み"
        reloadButton.setAccessibilityLabel("プレビューを再読み込み")
        addSubview(reloadButton)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 12, y: 11, width: max(0, bounds.width - 60), height: 22)
        reloadButton.frame = NSRect(x: max(12, bounds.width - 42), y: 7, width: 30, height: 30)
    }

    func update(workspace: PreviewWorkspaceStore, previewController: HugoPreviewController) {
        self.workspace = workspace
        self.previewController = previewController
        let isPreview = workspace.isPreviewSelected
        titleLabel.stringValue = isPreview ? "Preview" : "Webブラウザ"
        reloadButton.isHidden = !isPreview
    }

    @objc private func reloadPreview() { previewController?.reload() }
}

@MainActor
final class PreviewWorkspaceStore: ObservableObject {
    enum TabSelection: Hashable {
        case preview
        case browser(UUID)
    }

    @Published private(set) var selectedTab: TabSelection = .preview
    let browserTabs: BrowserTabStore

    init(browserTabs: BrowserTabStore = BrowserTabStore()) {
        self.browserTabs = browserTabs
    }

    var isPreviewSelected: Bool { selectedTab == .preview }

    func isBrowserSelected(_ id: UUID) -> Bool {
        selectedTab == .browser(id)
    }

    func selectPreview() {
        selectedTab = .preview
    }

    func selectBrowser(_ id: UUID) {
        guard browserTabs.tabs.contains(where: { $0.id == id }) else { return }
        browserTabs.select(id)
        selectedTab = .browser(id)
    }

    func addBrowserTab() {
        browserTabs.addTab()
        selectedTab = .browser(browserTabs.selectedTabID)
    }

    func closeBrowserTab(_ id: UUID) {
        let closedSelectedBrowserTab = isBrowserSelected(id)
        browserTabs.closeTab(id)
        if closedSelectedBrowserTab {
            selectedTab = .browser(browserTabs.selectedTabID)
        }
    }
}

struct BrowserTab: Identifiable {
    enum CommandKind {
        case load(URL)
        case back
        case forward
        case reload
    }

    struct Command: Identifiable {
        let id = UUID()
        let kind: CommandKind
    }

    let id: UUID
    var pageTitle: String?
    var address: String
    var currentURL: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var errorMessage: String?
    var command: Command?

    init(id: UUID = UUID(), pageTitle: String? = nil, address: String = "", currentURL: URL? = nil) {
        self.id = id
        self.pageTitle = pageTitle
        self.address = address
        self.currentURL = currentURL
    }

    var displayTitle: String {
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return String(title.prefix(24)) }
        if let host = currentURL?.host, !host.isEmpty { return host }
        return "新規タブ"
    }
}

@MainActor
final class BrowserTabStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab]
    @Published private(set) var selectedTabID: UUID

    init(tabs: [BrowserTab] = [BrowserTab()], selectedTabID: UUID? = nil) {
        let resolvedTabs = tabs.isEmpty ? [BrowserTab()] : tabs
        self.tabs = resolvedTabs
        self.selectedTabID = selectedTabID.flatMap { candidate in
            resolvedTabs.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? resolvedTabs[0].id
    }

    var selectedTab: BrowserTab? { tabs.first(where: { $0.id == selectedTabID }) }
    var selectedAddress: String { selectedTab?.address ?? "" }
    var selectedErrorMessage: String? { selectedTab?.errorMessage }
    var selectedIsLoading: Bool { selectedTab?.isLoading == true }
    var hasLoadedSelectedPage: Bool { selectedTab?.currentURL != nil }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func addTab() {
        let tab = BrowserTab()
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            let replacement = BrowserTab()
            tabs = [replacement]
            selectedTabID = replacement.id
            return
        }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[max(0, index - 1)].id
        }
    }

    func setSelectedAddress(_ value: String) {
        mutateSelected { $0.address = value }
    }

    func loadSelectedAddress() {
        guard let address = selectedTab?.address else { return }
        switch BrowserAddressResolver.resolve(address) {
        case .navigate(let url):
            mutateSelected {
                $0.errorMessage = nil
                $0.address = url.absoluteString
                $0.command = BrowserTab.Command(kind: .load(url))
            }
        case .empty:
            return
        case .rejected:
            mutateSelected {
                $0.errorMessage = "HTTPSの公開URLを入力してください。file:、data:、javascript:、ローカルネットワークは開けません。"
            }
        }
    }

    func goBack() { mutateSelected { $0.command = BrowserTab.Command(kind: .back) } }
    func goForward() { mutateSelected { $0.command = BrowserTab.Command(kind: .forward) } }
    func reload() { mutateSelected { $0.command = BrowserTab.Command(kind: .reload) } }

    func navigationStarted(for id: UUID) {
        mutate(id) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
    }

    func navigationFinished(
        for id: UUID,
        url: URL?,
        title: String?,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        mutate(id) {
            $0.isLoading = false
            $0.canGoBack = canGoBack
            $0.canGoForward = canGoForward
            if let url, url.scheme != "about" {
                $0.currentURL = url
                $0.address = url.absoluteString
            }
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                $0.pageTitle = title
            }
        }
    }

    func navigationFailed(_ error: Error, for id: UUID) {
        guard !BrowserNavigationError.isCancellation(error) else {
            mutate(id) { $0.isLoading = false }
            return
        }
        mutate(id) {
            $0.isLoading = false
            $0.errorMessage = error.localizedDescription
        }
    }

    private func mutateSelected(_ body: (inout BrowserTab) -> Void) {
        mutate(selectedTabID, body)
    }

    private func mutate(_ id: UUID, _ body: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&tabs[index])
    }
}

struct BrowserPreviewPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tabs: BrowserTabStore

    var body: some View {
        GeometryReader { proxy in
            let headerHeight: CGFloat = 56
            let footerHeight: CGFloat = 42
            let errorHeight: CGFloat = tabs.selectedErrorMessage == nil ? 0 : 42

            VStack(spacing: 0) {
                browserHeader
                    .frame(width: proxy.size.width, height: headerHeight)

                if let message = tabs.selectedErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(height: errorHeight)
                        .background(.orange.opacity(0.1))
                }

                browserContent
                    .frame(
                        width: proxy.size.width,
                        height: max(0, proxy.size.height - headerHeight - errorHeight - footerHeight),
                        alignment: .top
                    )
                    .clipped()

                browserFooter
                    .frame(width: proxy.size.width, height: footerHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
        .frame(minWidth: 340, maxHeight: .infinity)
        .clipped()
    }

    private var browserHeader: some View {
        HStack(spacing: 6) {
                Button(action: tabs.goBack) {
                    Label("戻る", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .disabled(tabs.selectedTab?.canGoBack != true)
                .help("戻る")

                Button(action: tabs.goForward) {
                    Label("進む", systemImage: "chevron.forward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .disabled(tabs.selectedTab?.canGoForward != true)
                .help("進む")

                Button(action: tabs.reload) {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .help("再読み込み")

                TextField("URLまたは検索キーワード", text: Binding(
                    get: { tabs.selectedAddress },
                    set: { tabs.setSelectedAddress($0) }
                ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.callout)
                    .frame(height: 34)
                    .onSubmit { tabs.loadSelectedAddress() }
                    .accessibilityLabel("URLまたは検索キーワード")
                    .accessibilityHint("公開HTTPS URLを開くか、通常の語句をGoogleで検索します")

                Button("移動", action: tabs.loadSelectedAddress)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minWidth: 60, minHeight: 34)
                    .disabled(tabs.selectedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("入力したURLを開く、またはキーワードを検索")
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
    }

    private var browserContent: some View {
        ZStack(alignment: .top) {
                ForEach(tabs.tabs) { tab in
                    BrowserWebView(tab: tab, store: tabs) { imageURL, sourcePageURL in
                        model.requestRemoteImageImport(imageURL, sourcePageURL: sourcePageURL)
                    } onDroppedFiles: { files in
                        model.importImages(files)
                    } onDroppedURL: { imageURL, sourcePageURL in
                        model.requestRemoteImageImport(imageURL, sourcePageURL: sourcePageURL)
                    }
                    .opacity(tab.id == tabs.selectedTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == tabs.selectedTabID)
                    .accessibilityHidden(tab.id != tabs.selectedTabID)
                }

                if !tabs.hasLoadedSelectedPage {
                    ContentUnavailableView(
                        "Webブラウザ",
                        systemImage: "globe",
                        description: Text("URLを入力してページを開きます。画像を右クリック、または画像URL・画像ファイルをここへドロップすると、確認後に記事へ保存できます。")
                    )
                    .allowsHitTesting(false)
                    .padding(.top, 120)
                }

                if tabs.selectedIsLoading {
                    ProgressView("読み込み中…")
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
    }

    private var browserFooter: some View {
        Text("外部画像の利用条件・著作権を確認してください。確認後のみJPEG・PNG・GIF（10MB以下）を保存し、出典URLをMarkdownへ追加します。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .background(.bar)
    }
}

private struct WorkspacePreviewTabButton: View {
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Label("Preview", systemImage: "safari")
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(minWidth: 70, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help("記事のPreviewを表示")
        .accessibilityLabel("Previewタブ")
        .accessibilityHint("記事のPreviewを表示します")
    }
}

private struct BrowserTabButton: View {
    let tab: BrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let showsCloseShortcut: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(minWidth: 70, maxWidth: 150, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("\(tab.displayTitle)を表示")
            .accessibilityLabel("ブラウザタブ: \(tab.displayTitle)")
            .accessibilityHint("このタブを表示します")

            if showsCloseShortcut {
                closeButton
                    .keyboardShortcut("w", modifiers: .command)
            } else {
                closeButton
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var closeButton: some View {
        Button(action: close) {
            Label("タブを閉じる", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("タブを閉じる（Command＋W）")
        .accessibilityLabel("\(tab.displayTitle)を閉じる")
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let tab: BrowserTab
    @ObservedObject var store: BrowserTabStore
    let onContextImage: @MainActor (URL, URL?) -> Void
    let onDroppedFiles: @MainActor ([URL]) -> Void
    let onDroppedURL: @MainActor (URL, URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tabID: tab.id,
            store: store,
            onContextImage: onContextImage,
            onDroppedFiles: onDroppedFiles,
            onDroppedURL: onDroppedURL
        )
    }

    func makeNSView(context: Context) -> ImageDropWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.userContentController.add(context.coordinator, name: Coordinator.imageContextHandlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Coordinator.contextMenuScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))

        let webView = ImageDropWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.onFilesDropped = context.coordinator.receiveDroppedFiles
        webView.onURLDropped = context.coordinator.receiveDroppedURL
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: ImageDropWKWebView, context: Context) {
        context.coordinator.perform(command: tab.command)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let imageContextHandlerName = "nkjImageContextMenu"
        static let contextMenuScript = """
        document.addEventListener('contextmenu', function(event) {
          const image = event.target && event.target.closest ? event.target.closest('img') : null;
          if (!image) return;
          const imageURL = image.currentSrc || image.src;
          if (!imageURL) return;
          event.preventDefault();
          window.webkit.messageHandlers.nkjImageContextMenu.postMessage({ imageURL: imageURL, pageURL: window.location.href });
        }, true);
        """

        weak var webView: ImageDropWKWebView?
        private let tabID: UUID
        private weak var store: BrowserTabStore?
        private let onContextImage: @MainActor (URL, URL?) -> Void
        private let onDroppedFiles: @MainActor ([URL]) -> Void
        private let onDroppedURL: @MainActor (URL, URL?) -> Void
        private var performedCommandIDs = Set<UUID>()
        private var contextImage: (URL, URL?)?

        init(
            tabID: UUID,
            store: BrowserTabStore,
            onContextImage: @escaping @MainActor (URL, URL?) -> Void,
            onDroppedFiles: @escaping @MainActor ([URL]) -> Void,
            onDroppedURL: @escaping @MainActor (URL, URL?) -> Void
        ) {
            self.tabID = tabID
            self.store = store
            self.onContextImage = onContextImage
            self.onDroppedFiles = onDroppedFiles
            self.onDroppedURL = onDroppedURL
        }

        func perform(command: BrowserTab.Command?) {
            guard let command, performedCommandIDs.insert(command.id).inserted,
                  let webView else { return }
            switch command.kind {
            case .load(let url):
                webView.load(URLRequest(url: url))
            case .back where webView.canGoBack:
                webView.goBack()
            case .forward where webView.canGoForward:
                webView.goForward()
            case .reload:
                webView.reload()
            default:
                break
            }
        }

        func receiveDroppedFiles(_ urls: [URL]) { onDroppedFiles(urls) }
        func receiveDroppedURL(_ url: URL) {
            onDroppedURL(url, webView?.url)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.imageContextHandlerName,
                  let payload = message.body as? [String: Any],
                  let rawImageURL = payload["imageURL"] as? String,
                  let imageURL = URL(string: rawImageURL) else { return }
            let pageURL = (payload["pageURL"] as? String).flatMap(URL.init(string:))
            contextImage = (imageURL, pageURL)
            let menu = NSMenu()
            let item = NSMenuItem(
                title: "記事に画像を保存して挿入…",
                action: #selector(requestContextImageImport(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.popUp(positioning: item, at: NSEvent.mouseLocation, in: nil)
        }

        @objc private func requestContextImageImport(_ sender: Any?) {
            guard let contextImage else { return }
            onContextImage(contextImage.0, contextImage.1)
            self.contextImage = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            store?.navigationStarted(for: tabID)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            store?.navigationFinished(
                for: tabID,
                url: webView.url,
                title: webView.title,
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward
            )
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            store?.navigationFailed(error, for: tabID)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            store?.navigationFailed(error, for: tabID)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, BrowserURLPolicy.isAllowed(url) else {
                store?.navigationFailed(BrowserNavigationError.blockedURL, for: tabID)
                return .cancel
            }
            return .allow
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url,
                  BrowserURLPolicy.isAllowed(url) else { return nil }
            webView.load(URLRequest(url: url))
            return nil
        }
    }
}

private final class ImageDropWKWebView: WKWebView {
    var onFilesDropped: (([URL]) -> Void)?
    var onURLDropped: ((URL) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return .copy
        }
        if pasteboard.string(forType: .string) != nil || pasteboard.string(forType: .URL) != nil {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let files = urls.filter { $0.isFileURL }
            if !files.isEmpty {
                onFilesDropped?(files)
                return true
            }
            if let remote = urls.first(where: { !$0.isFileURL }) {
                onURLDropped?(remote)
                return true
            }
        }
        let raw = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string)
        guard let raw,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              !url.isFileURL else { return false }
        onURLDropped?(url)
        return true
    }
}

enum BrowserAddressResolution: Equatable {
    case navigate(URL)
    case empty
    case rejected
}

enum BrowserAddressResolver {
    static func resolve(_ raw: String) -> BrowserAddressResolution {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }

        // A declared scheme must be honored as a URL attempt, never silently searched.
        if let scheme = URLComponents(string: value)?.scheme?.lowercased() {
            guard scheme == "https", let url = URL(string: value), BrowserURLPolicy.isAllowed(url) else {
                return .rejected
            }
            return .navigate(url)
        }
        guard !value.contains("://") else { return .rejected }

        // Bare public hosts are convenient, but recognizably local/IP hosts remain blocked.
        if !value.contains(where: { $0.isWhitespace }),
           let url = URL(string: "https://\(value)"),
           isLikelyHost(value, url: url) {
            return BrowserURLPolicy.isAllowed(url) ? .navigate(url) : .rejected
        }

        return .navigate(googleSearchURL(query: value))
    }

    static func googleSearchURL(query: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // These components are fixed and always create a URL; retain a safe fallback defensively.
        return components.url ?? URL(string: "https://www.google.com/search")!
    }

    private static func isLikelyHost(_ raw: String, url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.contains(".") || host.contains(":") { return true }
        // Bracketed IPv6 URL input is intentionally treated as a URL attempt and rejected by policy.
        return raw.hasPrefix("[")
    }
}

private enum BrowserURLPolicy {
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil else { return false }
        return !isPrivateOrLocal(host)
    }

    private static func isPrivateOrLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "0.0.0.0" { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (172, 16...31), (192, 168), (100, 64...127):
            return true
        default:
            return false
        }
    }
}

private enum BrowserNavigationError: LocalizedError {
    case blockedURL

    static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue
    }

    var errorDescription: String? {
        "このURLは開けません。HTTPSの公開URLだけを利用できます。"
    }
}
