import AppKit
import ImageIO
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var selectedDetailPanel: DetailPanel = .chat
    @State private var editorSelection = NSRange(location: 0, length: 0)
    @State private var editorScrollOffset: CGFloat = 0
    @State private var appliedEditorSelectionRequestID: UUID?
    @State private var postPendingDeletion: BlogPost?
    @StateObject private var previewController = HugoPreviewController()
    @StateObject private var previewWorkspace = PreviewWorkspaceStore()
    @FocusState private var isArticleSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 350, ideal: 350, max: 380)
        } content: {
            editor
                .navigationSplitViewColumnWidth(min: 850, ideal: 1_080)
        } detail: {
            detailPanel
                .navigationSplitViewColumnWidth(min: 500, ideal: 530, max: 560)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showingNewPost) {
            NewPostSheet()
                .environmentObject(model)
        }
        .alert("処理できませんでした", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "不明なエラーです。")
        }
        .confirmationDialog(
            "外部画像を記事に保存しますか？",
            isPresented: Binding(
                get: { model.pendingRemoteImage != nil },
                set: { if !$0 { model.cancelRemoteImageImport() } }
            ),
            titleVisibility: .visible
        ) {
            Button("保存してMarkdownへ挿入") { model.confirmRemoteImageImport() }
            Button("キャンセル", role: .cancel) { model.cancelRemoteImageImport() }
        } message: {
            if let candidate = model.pendingRemoteImage {
                Text("画像URL: \(candidate.imageURL.absoluteString)\n出典ページ: \((candidate.sourcePageURL ?? candidate.imageURL).absoluteString)\n\n利用条件・著作権を確認してください。JPEG・PNG・GIF（10MB以下）だけを保存し、出典URLをMarkdownへ追加します。公開・投稿は行いません。")
            }
        }
        .confirmationDialog(
            "この記事をゴミ箱に移動しますか？",
            isPresented: Binding(
                get: { postPendingDeletion != nil },
                set: { if !$0 { postPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("ゴミ箱に移動", role: .destructive) {
                if let postPendingDeletion {
                    model.movePostToTrash(postPendingDeletion)
                }
                postPendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { postPendingDeletion = nil }
        } message: {
            if let postPendingDeletion {
                Text("「\(postPendingDeletion.title)」のMarkdownファイルをゴミ箱へ移動します。参照画像は削除しません。")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            previewController.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: ArticleSearchCommand.focusNotification)) { _ in
            isArticleSearchFocused = true
        }
        .onDisappear {
            previewController.stop()
        }
        .background {
            WindowCloseObserver {
                previewController.stop()
            }
        }
    }

    private var detailPanel: some View {
        NativeDetailPanelContainer(
            selection: $selectedDetailPanel,
            content: detailContent
        )
        .navigationTitle(selectedDetailPanel.rawValue)
    }

    private var detailContent: AnyView {
        switch selectedDetailPanel {
        case .chat:
            AnyView(chat)
        case .images:
            AnyView(ImageManagementView().environmentObject(model))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            articleListControls

            ZStack {
                // `List` section headers are hosted by AppKit's table view. In this split view
                // they can be composited below a row during scrolling. Keep the header and rows
                // in one SwiftUI scroll surface instead, so each pinned header stays opaque and
                // rows always pass behind it.
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.postYearSections) { section in
                            Section {
                                ForEach(section.posts) { post in
                                    VStack(spacing: 0) {
                                        Button {
                                            do { try model.select(post) } catch { model.present(error) }
                                        } label: {
                                            PostRow(post: post, isSelected: model.selectedPost?.url == post.url)
                                                .padding(.vertical, 8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(model.isImportingImages || model.isPublishing)
                                        .contextMenu {
                                            Button("ゴミ箱に移動", systemImage: "trash", role: .destructive) {
                                                postPendingDeletion = post
                                            }
                                            .disabled(model.isImportingImages || model.isPublishing || model.isGenerating)
                                        }

                                        Divider().padding(.leading, 88)
                                    }
                                    .background {
                                        if model.selectedPost?.url == post.url {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(Color.accentColor)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                }
                            } header: {
                                PostYearSectionHeader(
                                    title: section.title,
                                    postCount: section.posts.count
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Keep the pinned header opaque while matching the sidebar surface,
                                // so rows always pass behind it without turning it into a card.
                                .background(Color(nsColor: .windowBackgroundColor))
                                .overlay(alignment: .bottom) { Divider() }
                                .zIndex(1)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.automatic)

                if model.isLoadingPosts && model.posts.isEmpty {
                    ProgressView("記事一覧を読み込んでいます…")
                        .controlSize(.small)
                        .accessibilityLabel("記事一覧を読み込み中")
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("記事")
    }

    private var articleListControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.filteredPosts.count)件の記事")
                    .font(.headline)
                    .accessibilityLabel("表示中の記事 \(model.filteredPosts.count)件")
                Spacer()
                Button { model.showingNewPost = true } label: {
                    Label("追加", systemImage: "plus")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 74, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("新規記事を作成")
                .accessibilityLabel("新規記事を追加")
            }

            AccentSegmentedPicker(
                selection: $model.filter,
                accessibilityLabel: "記事の表示"
            )
            .frame(height: 36)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("記事を検索", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isArticleSearchFocused)
                    .accessibilityLabel("記事を検索")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var editor: some View {
        if let post = model.selectedPost {
            HSplitView {
                HStack(spacing: 0) {
                    MarkdownLineNumberGutter(
                        text: model.editorText,
                        fontSize: model.markdownEditorFontSize,
                        scrollOffset: editorScrollOffset
                    )
                    .frame(width: 44)

                    MarkdownEditor(
                        text: $model.editorText,
                        selection: $editorSelection,
                        appliedSelectionRequestID: $appliedEditorSelectionRequestID,
                        selectionRequest: model.editorSelectionRequest,
                        onPasteImages: { inputs, selection in
                            model.importPastedImages(inputs, replacing: selection)
                        },
                        onScrollOffsetChange: { editorScrollOffset = $0 },
                        fontSize: model.markdownEditorFontSize
                    )
                    .accessibilityLabel("Markdownエディタ")
                    .accessibilityHint("画像をペーストすると記事用フォルダへ保存し、選択位置へMarkdownを挿入します")
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                PreviewWorkspacePane(
                    previewController: previewController,
                    workspace: previewWorkspace
                )
                    .frame(minWidth: 430, maxHeight: .infinity)
                    .clipped()
            }
            .navigationTitle(FrontMatterParser.parse(model.editorText).title)
            .navigationSubtitle(post.relativePath)
            .task(id: post.url) {
                updatePreview(for: post, immediately: true)
            }
            .onChange(of: model.editorText) {
                updatePreview(for: post)
            }
            .onChange(of: model.savedText) {
                updatePreview(for: post, immediately: true)
            }
            .onChange(of: model.sourcePath) {
                previewController.stop()
                updatePreview(for: post, immediately: true)
            }
        } else {
            ContentUnavailableView(
                "記事を選択してください",
                systemImage: "doc.text",
                description: Text("左の一覧から編集する記事を選ぶか、新規記事を作成します。")
            )
        }
    }

    private func updatePreview(for post: BlogPost, immediately: Bool = false) {
        previewController.update(HugoPreviewRequest(
            sourceRepository: URL(fileURLWithPath: model.sourcePath, isDirectory: true),
            postURL: post.url,
            markdown: model.editorText,
            isSaved: !model.isDirty
        ), immediately: immediately)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("チャット", selection: Binding(
                        get: { model.selectedChatSessionID },
                        set: { if let id = $0 { model.selectChatSession(id) } }
                    )) {
                        ForEach(model.chatSessions) { session in
                            Text(session.title).tag(Optional(session.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .disabled(model.isGenerating)
                    .accessibilityLabel("この記事のチャットを切り替え")

                    Button { model.createChatSession() } label: {
                        Label("新しいチャット", systemImage: "plus.bubble")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 26, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.selectedPost == nil || model.isGenerating)
                    .help("この記事に新しいチャットを作成")
                    .accessibilityLabel("新しいチャットを作成")

                    Button(role: .destructive) { model.deleteSelectedChatSession() } label: {
                        Label("チャットを削除", systemImage: "trash")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 26, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.selectedPost == nil || model.isGenerating)
                    .help("表示中のチャットを削除")
                    .accessibilityLabel("表示中のチャットを削除")
                }

                AccentSegmentedPicker(
                    selection: $model.chatMode,
                    accessibilityLabel: "チャットモード"
                )
                .frame(height: 36)
                .help("相談は回答だけ、記事を編集は確認可能なMarkdown更新案を作ります")

                HStack(spacing: 8) {
                    Toggle("ネット検索", isOn: Binding(
                        get: { model.webSearchEnabled },
                        set: { model.setWebSearchEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(model.chatMode != .consultation || model.isGenerating)
                    .accessibilityHint("有効にした送信だけがOpenRouterのWeb検索を利用します")
                    Spacer()
                    Text(model.webSearchEnabled && model.chatMode == .consultation
                         ? "検索は追加料金が発生する場合があります"
                         : "検索は相談モードで有効にできます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.chatMessages.isEmpty {
                            ChatGuide(mode: model.chatMode) { prompt in
                                model.chatInput = prompt
                            }
                        }
                        ForEach(model.chatMessages) { message in
                            if message.role != .assistant || !message.text.isEmpty {
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        if model.isGenerating {
                            ChatGeneratingBubble()
                                .id(ChatGeneratingBubble.scrollID)
                        }

                        if let proposal = model.proposedMarkdown {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("更新案").font(.headline)
                                ScrollView {
                                    Text(proposal)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 220)
                                .padding(8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                                HStack {
                                    Button("破棄") { model.discardProposal() }
                                        .help("この更新案を記事へ反映せず破棄")
                                    Spacer()
                                    Button("記事に反映") { model.applyProposal() }
                                        .buttonStyle(.borderedProminent)
                                        .help("本文が更新案の生成時から変わっていない場合だけMarkdownへ保存して反映")
                                }
                            }
                            .padding(10)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .id(ChatProposalScrollTarget.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: model.chatMessages) {
                    if model.chatProposal != nil {
                        withAnimation { proxy.scrollTo(ChatProposalScrollTarget.id, anchor: .bottom) }
                    } else if let id = model.chatMessages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onChange(of: model.selectedChatSessionID) {
                    if model.chatProposal != nil {
                        proxy.scrollTo(ChatProposalScrollTarget.id, anchor: .bottom)
                    } else if let id = model.chatMessages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .onChange(of: model.chatProposal) { _, proposal in
                    guard proposal != nil else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation { proxy.scrollTo(ChatProposalScrollTarget.id, anchor: .bottom) }
                    }
                }
                .onChange(of: model.isGenerating) { wasGenerating, isGenerating in
                    guard !wasGenerating, isGenerating else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation {
                            proxy.scrollTo(ChatGeneratingBubble.scrollID, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.chatInput)
                    .font(.body)
                    .frame(height: 84)
                    .overlay(alignment: .topLeading) {
                        if model.chatInput.isEmpty {
                            Text("記事について相談する、または編集内容を入力…")
                                .font(.body)
                                .foregroundStyle(Color(nsColor: .placeholderTextColor))
                                .padding(.horizontal, 5)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("チャット入力")
                HStack {
                    Spacer()
                    if model.isGenerating {
                        Button { model.cancelChatGeneration() } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                            .help("生成中の回答をキャンセル")
                            .accessibilityLabel("チャット生成を中止")
                    } else {
                        Button { model.sendChat() } label: {
                            Image(systemName: "arrow.up")
                        }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help(sendButtonHelp)
                            .accessibilityLabel("チャットを送信")
                            .disabled(!model.canSendChat)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .fixedSize(horizontal: false, vertical: true)
            .background(.bar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sendButtonHelp: String {
        if !model.isChatAvailable { return model.chatAvailability }
        if model.chatMode == .edit, model.chatProposal != nil {
            return "未反映の更新案を反映または破棄してください"
        }
        return "送信（Command＋Return）"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.loadInBackground()
            } label: {
                Label("再読み込み", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(model.isLoadingPosts)
            .help("記事一覧を再読み込み")

            Button {
                do { try model.save() } catch { model.present(error) }
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.iconOnly)
            .disabled(model.selectedPost == nil || !model.isDirty)
            .help("編集中の記事を保存（Command＋S）")

            Button {
                model.selectedSettingsSection = .repository
                openSettings()
            } label: {
                Label("リポジトリ設定", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .help("Hugoリポジトリ設定を開く")
            .accessibilityLabel("リポジトリ設定を開く")

            Button { model.publish() } label: {
                Label("投稿", systemImage: "paperplane.fill")
            }
            .labelStyle(.iconOnly)
            .disabled(model.selectedPost == nil || model.isPublishing)
            .help("記事をHugoでビルドして投稿")
        }
    }
}

private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        nsView.onClose = onClose
        nsView.observeCurrentWindow()
    }

    @MainActor
    final class WindowObservingView: NSView {
        var onClose: (@MainActor () -> Void)?
        private weak var observedWindow: NSWindow?
        private static let minimumContentSize = NSSize(width: 1_500, height: 900)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeCurrentWindow()
        }

        func observeCurrentWindow() {
            enforceMinimumContentSize()
            guard observedWindow !== window else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: observedWindow
            )
            observedWindow = window
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        private func enforceMinimumContentSize() {
            guard let window else { return }
            window.minSize = Self.minimumContentSize
            guard let visibleFrame = window.screen?.visibleFrame else { return }
            let targetSize = NSSize(
                width: min(Self.minimumContentSize.width, visibleFrame.width),
                height: min(Self.minimumContentSize.height, visibleFrame.height)
            )
            guard window.frame.width < targetSize.width || window.frame.height < targetSize.height else {
                return
            }
            let previousFrame = window.frame
            var expandedFrame = previousFrame
            expandedFrame.size.width = max(previousFrame.width, targetSize.width)
            expandedFrame.size.height = max(previousFrame.height, targetSize.height)
            expandedFrame.origin.y -= expandedFrame.height - previousFrame.height
            expandedFrame.origin.x = min(
                max(expandedFrame.origin.x, visibleFrame.minX),
                visibleFrame.maxX - expandedFrame.width
            )
            expandedFrame.origin.y = min(
                max(expandedFrame.origin.y, visibleFrame.minY),
                visibleFrame.maxY - expandedFrame.height
            )
            window.setFrame(expandedFrame, display: true)
        }

        @objc private func windowWillClose() {
            onClose?()
        }
    }
}

private enum DetailPanel: String, CaseIterable, Identifiable {
    case chat = "チャット"
    case images = "画像管理"

    var id: Self { self }
}

/// Keeps the app's blue selection language consistent on macOS appearances
/// where the standard segmented picker is rendered in gray.
private struct AccentSegmentedPicker<Option>: View where Option: CaseIterable & Hashable & RawRepresentable, Option.AllCases: RandomAccessCollection, Option.RawValue == String {
    @Binding var selection: Option
    let accessibilityLabel: String

    private var options: [Option] { Array(Option.allCases) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                Button {
                    selection = option
                } label: {
                    Text(option.rawValue)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(selection == option ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(selection == option ? .isSelected : [])

                if index < options.count - 1 {
                    Divider().padding(.vertical, 6)
                }
            }
        }
        .padding(2)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.24))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A SwiftUI sibling of the AppKit text view. Keeping this out of the scroll
/// view hierarchy avoids the AppKit compositing issue caused by ruler overlays.
private struct MarkdownLineNumberGutter: View {
    let text: String
    let fontSize: CGFloat
    let scrollOffset: CGFloat

    private var lineCount: Int {
        max(1, text.reduce(into: 1) { total, character in
            if character == "\n" { total += 1 }
        })
    }

    private var lineHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...lineCount, id: \.self) { line in
                    Text("\(line)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .trailing)
                }
            }
            .padding(.top, 60)
            .padding(.trailing, 8)
            .offset(y: -scrollOffset)
            .frame(width: proxy.size.width, alignment: .trailing)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .trailing) { Divider() }
        .overlay(alignment: .bottom) {
            Color(nsColor: .windowBackgroundColor)
                .frame(height: 25)
        }
        .accessibilityHidden(true)
    }
}

/// The chat transcript is an AppKit scroll view. When its segmented picker is
/// hosted as a SwiftUI sibling, AppKit can composite the scroll surface above
/// it. Keep the existing segmented control in a native header above the hosted
/// detail content so the two controls remain independently addressable.
private struct NativeDetailPanelContainer: NSViewRepresentable {
    @Binding var selection: DetailPanel
    let content: AnyView

    func makeNSView(context: Context) -> NativeDetailPanelView {
        NativeDetailPanelView(
            content: content,
            selection: selection,
            onSelectionChange: { selection = $0 }
        )
    }

    func updateNSView(_ nsView: NativeDetailPanelView, context: Context) {
        nsView.update(
            content: content,
            selection: selection,
            onSelectionChange: { selection = $0 }
        )
    }
}

private final class NativeDetailPanelView: NSView {
    private let contentHost: NSHostingView<AnyView>
    private let header = NSVisualEffectView()
    private let panelSelector = NativeDetailPanelSelector()
    private var onSelectionChange: ((DetailPanel) -> Void)?

    init(
        content: AnyView,
        selection: DetailPanel,
        onSelectionChange: @escaping (DetailPanel) -> Void
    ) {
        contentHost = NSHostingView(rootView: content)
        self.onSelectionChange = onSelectionChange
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        panelSelector.onSelectionChange = { [weak self] selection in
            self?.onSelectionChange?(selection)
        }

        addSubview(contentHost)
        addSubview(header, positioned: .above, relativeTo: contentHost)
        header.addSubview(panelSelector)
        update(content: content, selection: selection, onSelectionChange: onSelectionChange)
    }

    required init?(coder: NSCoder) { nil }

    func update(
        content: AnyView,
        selection: DetailPanel,
        onSelectionChange: @escaping (DetailPanel) -> Void
    ) {
        contentHost.rootView = content
        panelSelector.update(selection: selection)
        self.onSelectionChange = onSelectionChange
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 46
        let contentHeight = max(0, bounds.height - headerHeight)
        contentHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        header.frame = NSRect(x: 0, y: contentHeight, width: bounds.width, height: headerHeight)
        panelSelector.frame = NSRect(
            x: 12,
            y: 6,
            width: max(0, bounds.width - 24),
            height: 34
        )
    }
}

private final class NativeDetailPanelSelector: NSView {
    private var buttons: [NSButton] = []
    private var selection: DetailPanel = .chat
    var onSelectionChange: ((DetailPanel) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setAccessibilityLabel("右パネルの表示")
        setAccessibilityHelp("執筆チャットと画像管理を切り替えます")

        for (index, panel) in DetailPanel.allCases.enumerated() {
            let button = NSButton(title: panel.rawValue, target: self, action: #selector(selectPanel(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.alignment = .center
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.layer?.cornerCurve = .continuous
            button.setAccessibilityLabel(panel.rawValue)
            addSubview(button)
            buttons.append(button)
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let width = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * width + 2, y: 2, width: max(0, width - 4), height: max(0, bounds.height - 4))
        }
    }

    func update(selection: DetailPanel) {
        self.selection = selection
        updateAppearance()
    }

    @objc private func selectPanel(_ sender: NSButton) {
        guard DetailPanel.allCases.indices.contains(sender.tag) else { return }
        let selected = DetailPanel.allCases[sender.tag]
        guard selected != selection else { return }
        selection = selected
        updateAppearance()
        onSelectionChange?(selected)
    }

    private func updateAppearance() {
        for (index, button) in buttons.enumerated() {
            let isSelected = DetailPanel.allCases[index] == selection
            button.contentTintColor = isSelected ? .white : .labelColor
            button.layer?.backgroundColor = isSelected ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor
            button.setAccessibilityValue(isSelected ? "選択中" : "")
        }
    }
}

private struct PostYearSectionHeader: View {
    let title: String
    let postCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: "calendar")
                .font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            Text("\(postCount)件")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)、\(postCount)件")
    }
}

private struct PostRow: View {
    let post: BlogPost
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PostThumbnail(
                imageURL: post.previewImages.first?.fileURL,
                isSelected: isSelected
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(post.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let date = post.date {
                        Text(date, format: .dateTime.year().month().day())
                    }
                }
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
            }

            Spacer(minLength: 8)
            Circle()
                .fill(isSelected ? Color.white.opacity(0.9) : (post.isDraft ? .orange : .green))
                .frame(width: 8, height: 8)
                .accessibilityLabel(post.isDraft ? "下書き" : "公開済み")
        }
        // The card itself is inset by its parent. Keep the thumbnail and
        // publication indicator equally inset within that card.
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let state = post.isDraft ? "下書き" : "公開済み"
        let imageCount = post.previewImages.count
        return "\(post.title)、\(state)、画像\(imageCount)枚"
    }
}

/// Decodes a small, display-sized image away from the main actor. Article rows remain cheap even
/// when their source files are high-resolution photos.
private struct PostThumbnail: View {
    let imageURL: URL?
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc.text.image")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.45 : 0), lineWidth: 1)
        }
        .accessibilityHidden(true)
        .task(id: imageURL) {
            guard let imageURL else {
                image = nil
                return
            }
            let thumbnail = await PostThumbnailCache.shared.image(for: imageURL)
            guard !Task.isCancelled else { return }
            image = thumbnail.image
        }
    }
}

/// `NSImage` is used immutably after its background construction. The actor serializes cache
/// mutation, while the box carries the AppKit object back to SwiftUI's main actor.
private final class PostThumbnailBox: @unchecked Sendable {
    let image: NSImage?

    init(image: NSImage?) {
        self.image = image
    }
}

private actor PostThumbnailCache {
    static let shared = PostThumbnailCache()

    private let maximumImageCount = 72
    private var images: [URL: PostThumbnailBox] = [:]
    private var recency: [URL] = []

    func image(for url: URL) -> PostThumbnailBox {
        if let cached = images[url] {
            recordUse(of: url)
            return cached
        }

        let thumbnail = PostThumbnailBox(image: Self.decode(url))
        images[url] = thumbnail
        recency.append(url)
        if recency.count > maximumImageCount {
            images.removeValue(forKey: recency.removeFirst())
        }
        return thumbnail
    }

    private func recordUse(of url: URL) {
        recency.removeAll { $0 == url }
        recency.append(url)
    }

    private static func decode(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 64, height: 44))
    }
}

private struct DraftBadge: View {
    let isDraft: Bool

    var body: some View {
        Text(isDraft ? "下書き" : "公開")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isDraft ? .orange : .green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isDraft ? Color.orange : Color.green).opacity(0.12), in: Capsule())
    }
}

private enum ChatProposalScrollTarget {
    static let id = "chat-proposal"
}

private struct ChatGuide: View {
    let mode: ChatMode
    let choosePrompt: (String) -> Void

    private var actions: [(title: String, detail: String, symbol: String, prompt: String)] {
        switch mode {
        case .consultation:
            [
                ("要約する", "この記事の内容を簡潔に要約します。", "doc.text", "この記事の内容を要点だけに要約してください。"),
                ("読みやすくする", "文章をより読みやすく、自然な表現に整えます。", "text.alignleft", "この記事を読みやすくするための改善点を提案してください。"),
                ("見出しを提案", "内容に基づいて、適切な見出し構成を提案します。", "list.bullet.rectangle", "この記事に合う見出し構成を提案してください。"),
                ("公開前の最終チェックを依頼", "誤字脱字や表現の改善点をチェックします。", "checkmark.seal", "公開前の最終チェックをしてください。誤字、表現、構成の改善点を教えてください。")
            ]
        case .edit:
            [
                ("文章を整える", "自然で読みやすい表現にします。", "text.badge.checkmark", "この記事を自然で読みやすい文章に整える更新案を作ってください。"),
                ("見出しを提案", "内容に合う構成へ整理します。", "list.bullet.rectangle", "この記事の見出し構成を改善する更新案を作ってください。"),
                ("導入文を改善", "読者が読み進めやすい導入にします。", "text.quote", "この記事の導入文を改善する更新案を作ってください。"),
                ("公開前に確認", "公開品質を最終チェックします。", "checkmark.seal", "この記事を公開前に最終チェックし、必要なら更新案を作ってください。")
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: mode == .consultation ? "sparkles" : "square.and.pencil")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .consultation ? "AIアシスト" : "記事を編集")
                        .font(.headline)
                    Text(mode == .consultation
                         ? "やりたいことを選ぶか、気軽に相談してください。"
                         : "更新案を作成し、確認してから記事へ反映できます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(actions, id: \.title) { action in
                Button {
                    choosePrompt(action.prompt)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(action.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(action.title)：\(action.detail)")
                .help("入力欄へ依頼文をセットします")
            }
        }
        .padding(.vertical, 6)
    }
}

private struct PersonaSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("チャットの人格設定")
                .font(.title2.bold())
            Text("文体、視点、語り口を指定できます。空で保存すると人格設定を使いません。")
                .foregroundStyle(.secondary)

            TextEditor(text: $model.personaDraft)
                .font(.body)
                .frame(minHeight: 220)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("チャット人格設定")

            HStack {
                Text("\(model.personaDraft.count) / \(PersonaStore.maximumLength)文字")
                    .foregroundStyle(model.personaDraft.count > PersonaStore.maximumLength ? .red : .secondary)
                Spacer()
                Text("秘密情報や認証情報は入力しないでください")
                    .foregroundStyle(.orange)
            }
            .font(.caption)

            Text("人格設定は文体と視点にだけ適用され、事実性や安全規則、出力形式を上書きしません。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("変更を取り消す") { model.beginEditingPersona() }
                    .help("保存済みの人格設定へ戻す")
                Spacer()
                Button("保存") {
                    do {
                        try model.savePersona()
                    } catch {
                        model.present(error)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.personaDraft.count > PersonaStore.maximumLength)
                .help("人格設定をこのMacに保存")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.beginEditingPersona() }
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("ワークスペース") {
                    SettingsSidebarItem(
                        title: "リポジトリ",
                        subtitle: "Hugoソースと公開先",
                        systemImage: "externaldrive",
                        isSelected: model.selectedSettingsSection == .repository
                    ) {
                        model.selectedSettingsSection = .repository
                    }
                    SettingsSidebarItem(
                        title: "エディタ",
                        subtitle: "Markdownの表示",
                        systemImage: "textformat.size",
                        isSelected: model.selectedSettingsSection == .editor
                    ) {
                        model.selectedSettingsSection = .editor
                    }
                    SettingsSidebarItem(
                        title: "記事の作成・編集",
                        subtitle: "本文テンプレートとAIの指示",
                        systemImage: "text.badge.plus",
                        isSelected: model.selectedSettingsSection == .articlePrompts
                    ) {
                        model.selectedSettingsSection = .articlePrompts
                    }
                }

                Section("AIアシスタント") {
                    SettingsSidebarItem(
                        title: "AIアシスタント",
                        subtitle: "OpenRouterと検索",
                        systemImage: "sparkles",
                        isSelected: model.selectedSettingsSection == .ai
                    ) {
                        model.selectedSettingsSection = .ai
                    }
                    SettingsSidebarItem(
                        title: "人格設定",
                        subtitle: "チャットの文体と視点",
                        systemImage: "person.text.rectangle",
                        isSelected: model.selectedSettingsSection == .persona
                    ) {
                        model.selectedSettingsSection = .persona
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("設定")
            .frame(minWidth: 210)
        } detail: {
            Group {
                switch model.selectedSettingsSection {
                case .repository:
                    RepositorySettingsView()
                case .editor:
                    MarkdownEditorSettingsView()
                case .articlePrompts:
                    ArticlePromptSettingsView()
                case .ai:
                    OpenRouterSettingsView()
                case .persona:
                    PersonaSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 800, height: 610)
    }
}

private struct ArticlePromptSettingsView: View {
    private enum Field: String, CaseIterable, Identifiable {
        case template = "新規記事の本文"
        case editing = "AIの記事編集"

        var id: Self { self }
        var keyPath: WritableKeyPath<ArticlePromptSettings, String> {
            switch self {
            case .template: \.newArticleTemplate
            case .editing: \.editingInstructions
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var selectedField: Field = .template
    @State private var message: String?
    @State private var saveError: String?

    private var text: Binding<String> {
        Binding(
            get: { model.articlePromptDraft[keyPath: selectedField.keyPath] },
            set: {
                model.articlePromptDraft[keyPath: selectedField.keyPath] = $0
                message = nil
            }
        )
    }

    private var exceedsLimit: Bool {
        model.articlePromptDraft.newArticleTemplate.count > ArticlePromptSettingsStore.maximumLength
            || model.articlePromptDraft.editingInstructions.count > ArticlePromptSettingsStore.maximumLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader(
                title: "記事の作成・編集",
                description: "新規記事の本文と、AIに渡す編集指示をこのMacに保存します。"
            )

            Picker("編集する設定", selection: $selectedField) {
                ForEach(Field.allCases) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .pickerStyle(.segmented)

            SettingsCard(
                title: selectedField.rawValue,
                systemImage: selectedField == .template ? "doc.badge.plus" : "square.and.pencil"
            ) {
                Text(selectedField == .template
                     ? "新規記事を作成するときだけ本文へ挿入します。タイトル・日付・下書き状態などは自動生成します。既存の記事は変更しません。"
                     : "次に「記事を編集」で送信するときから適用します。Markdown全文の出力、Front Matterの保護、事実性の共通ルールは維持されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220, maxHeight: .infinity)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    .accessibilityLabel(selectedField == .template ? "新規記事の本文テンプレート" : "AIの記事編集指示")

                HStack {
                    Text("\(text.wrappedValue.count) / \(ArticlePromptSettingsStore.maximumLength)文字")
                        .foregroundStyle(text.wrappedValue.count > ArticlePromptSettingsStore.maximumLength ? .red : .secondary)
                    Spacer()
                    Text("空欄で保存すると初期値を使います")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Text(exceedsLimit ? "各項目を\(ArticlePromptSettingsStore.maximumLength)文字以内にしてください。" : (message ?? "保存するまで変更は適用されません。秘密情報や認証情報は入力しないでください。"))
                .font(.caption)
                .foregroundStyle(exceedsLimit ? .red : .secondary)
                .accessibilityLabel(exceedsLimit ? "入力文字数が上限を超えています" : (message ?? "保存するまで変更は適用されません"))

            HStack {
                Button("変更を取り消す") {
                    model.beginEditingArticlePrompts()
                    message = "保存済みの設定に戻しました"
                }
                .disabled(model.articlePromptDraft == model.articlePromptSettings)
                Button("初期値に戻す") {
                    text.wrappedValue = ArticlePromptSettings.defaults[keyPath: selectedField.keyPath]
                }
                .help("表示中の項目を初期値へ戻します。適用するには保存してください")
                Spacer()
                Button("保存") {
                    do {
                        try model.saveArticlePrompts()
                        message = "保存しました。次の新規記事・AI編集から適用します"
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(exceedsLimit || model.articlePromptDraft == model.articlePromptSettings)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.beginEditingArticlePrompts() }
        .alert("記事の設定を保存できませんでした", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("閉じる", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "設定を確認してください。")
        }
    }
}

private struct SettingsSidebarItem: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .white : .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .primary)
        .listRowBackground(isSelected ? Color.accentColor : Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MarkdownEditorSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(
                title: "エディタ",
                description: "Markdownを書くときの表示を、このMac向けに調整します。"
            )

            SettingsCard(title: "文字サイズ", systemImage: "textformat.size") {
                Picker("文字サイズ", selection: Binding(
                    get: { model.markdownEditorFontSize },
                    set: { model.setMarkdownEditorFontSize($0) }
                )) {
                    ForEach(MarkdownEditorSettingsStore.availableFontSizes, id: \.self) { fontSize in
                        Text("\(Int(fontSize)) pt").tag(fontSize)
                    }
                }
                .accessibilityLabel("Markdownエディタの文字サイズ")
                .accessibilityHint("選択するとMarkdownエディタの文字サイズをすぐに変更します")

                Text("現在の文字サイズ: \(Int(model.markdownEditorFontSize)) pt。変更はこのMacに保存され、次回起動後も適用されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct OpenRouterSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKey = ""
    @State private var modelID = OpenRouterSettingsStore.defaultModelID
    @State private var showingDeleteConfirmation = false
    @State private var localErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(
                    title: "AIアシスタント",
                    description: "OpenRouterへの接続、使用するモデル、相談時の検索を管理します。"
                )

                SettingsCard(title: "接続", systemImage: "key.fill") {
                HStack {
                    Text("APIキー").font(.headline)
                    Spacer()
                    Label(
                        model.hasSavedOpenRouterAPIKey ? "保存済み" : "未設定",
                        systemImage: model.hasSavedOpenRouterAPIKey ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(model.hasSavedOpenRouterAPIKey ? .green : .orange)
                }
                SecureField(
                    model.hasSavedOpenRouterAPIKey ? "変更する場合だけ新しいAPIキーを入力" : "OpenRouter APIキー",
                    text: $apiKey
                )
                .textContentType(.password)
                .accessibilityLabel("OpenRouter APIキー")
                Text("保存済みのキーは表示しません。空欄のまま保存すると現在のキーを維持します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("APIキーはmacOS Keychainで暗号化して保存され、このMacのみで、Macのロック解除中に利用できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                SettingsCard(title: "モデル", systemImage: "cpu") {
                Text("モデルID").font(.subheadline.weight(.medium))
                TextField(OpenRouterSettingsStore.defaultModelID, text: $modelID)
                    .accessibilityLabel("OpenRouterモデルID")
                HStack {
                    Button("モデル一覧を取得") { model.fetchOpenRouterModels() }
                        .disabled(
                            !model.hasSavedOpenRouterAPIKey
                                || model.isFetchingOpenRouterModels
                                || model.isSavingAISettings
                        )
                        .help("OpenRouterから利用可能なモデル一覧を取得")
                    if model.isFetchingOpenRouterModels {
                        ProgressView().controlSize(.small)
                    }
                }
                if !model.openRouterModels.isEmpty {
                    Picker("取得したモデル", selection: $modelID) {
                        if !model.openRouterModels.contains(where: { $0.id == modelID }) {
                            Text("手入力: \(modelID)").tag(modelID)
                        }
                        ForEach(model.openRouterModels) { availableModel in
                            Text("\(availableModel.name) — \(availableModel.id)")
                                .tag(availableModel.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("取得したOpenRouterモデルから選択")
                }
                Text("空欄の場合は\(OpenRouterSettingsStore.defaultModelName)（\(OpenRouterSettingsStore.defaultModelID)）を使います。モデルIDは常に手入力できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.hasSavedOpenRouterAPIKey {
                    Text("モデル一覧の取得には、先にAPIキーを保存してください。未保存の入力中キーは一覧取得に使いません。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                }

                SettingsCard(title: "検索", systemImage: "globe") {
                Toggle("相談でネット検索を使う", isOn: Binding(
                    get: { model.webSearchEnabled },
                    set: { model.setWebSearchEnabled($0) }
                ))
                .accessibilityHint("送信時にOpenRouterのWeb検索ツールを使います")
                Text("有効にした相談だけがOpenRouterのWeb検索を使います。検索結果は出典リンクとしてチャットに表示され、検索回数・結果数に応じて追加料金が発生する場合があります。記事を編集モードでは検索しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard(title: "外部送信と料金", systemImage: "exclamationmark.shield") {
                    VStack(alignment: .leading, spacing: 5) {
                    Text("記事本文・直近の会話・人格設定がOpenRouterと、選択したモデルの提供者へ送信されます。")
                    Text("料金は選択モデルと利用量によって異なります。秘密情報や認証情報を送信しないでください。")
                    Text("生成を中止しても、リモート側の処理や料金が停止することは保証されません。")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let message = model.aiSettingsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("APIキーを削除", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .disabled(
                        !model.hasSavedOpenRouterAPIKey
                            || model.isSavingAISettings
                            || model.isFetchingOpenRouterModels
                    )
                    .help("Keychainに保存したOpenRouter APIキーを削除")
                    Spacer()
                    Button("保存") {
                        do {
                            try model.saveAISettings(apiKey: apiKey, modelID: modelID)
                            apiKey = ""
                            modelID = model.openRouterModelID
                            localErrorMessage = nil
                        } catch {
                            localErrorMessage = "設定を保存できませんでした。Keychainへのアクセスを確認して再試行してください。"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSavingAISettings || model.isFetchingOpenRouterModels)
                    .help("APIキーとモデルIDの設定を保存")
                }
            }
            .padding(24)
        }
        .onAppear {
            apiKey = ""
            modelID = model.openRouterModelID
            model.prepareAISettings()
        }
        .onDisappear { apiKey = "" }
        .confirmationDialog(
            "保存済みのOpenRouter APIキーを削除しますか？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("APIキーを削除", role: .destructive) {
                do {
                    try model.deleteOpenRouterAPIKey()
                    apiKey = ""
                    localErrorMessage = nil
                } catch {
                    localErrorMessage = "APIキーを削除できませんでした。Keychainへのアクセスを確認して再試行してください。"
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("KeychainからAPIキーを削除します。モデルIDは保持されます。")
        }
        .alert("OpenRouter設定を更新できませんでした", isPresented: Binding(
            get: { localErrorMessage != nil },
            set: { if !$0 { localErrorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { localErrorMessage = nil }
        } message: {
            Text(localErrorMessage ?? "")
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    @State private var didCopyResponse = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 30) }
            content
                .textSelection(.enabled)
                .padding(10)
                .background(background, in: RoundedRectangle(cornerRadius: 12))
            if message.role != .user { Spacer(minLength: 30) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.role == .assistant {
            VStack(alignment: .leading, spacing: 10) {
                ChatMarkdownRenderer(markdown: message.text)
                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        didCopyResponse = true

                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopyResponse = false
                        }
                    } label: {
                        Label(
                            didCopyResponse ? "コピーしました" : "コピー",
                            systemImage: didCopyResponse ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderless)
                    .help("回答をクリップボードへコピー")
                    .accessibilityLabel(didCopyResponse ? "回答をコピーしました" : "回答をコピー")
                    .accessibilityHint("回答のMarkdownをクリップボードへコピーします")
                }
                if !message.citations.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("検索した出典")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(message.citations) { citation in
                            Link(destination: citation.url) {
                                Text(citation.title)
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .help(citation.url.absoluteString)
                        }
                    }
                }
            }
        } else {
            Text(message.text)
        }
    }

    private var background: Color {
        switch message.role {
        case .user: return .accentColor.opacity(0.18)
        case .assistant: return Color(nsColor: .controlBackgroundColor)
        case .system: return .orange.opacity(0.14)
        }
    }
}

private struct ChatGeneratingBubble: View {
    static let scrollID = "chat-generating-bubble"
    private static let label = "GLM 5.3 Flashが応答を生成しています…"

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(Self.label)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 30)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label)
    }
}

private struct NewPostSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = "life"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新規記事").font(.title2.bold())
            TextField("タイトル", text: $title)
            TextField("カテゴリー", text: $category)
            Text("下書きとして .md ファイルを作成します。公開操作は別です。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("新規記事を作成せずに閉じる")
                Button("作成") {
                    model.createPost(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: category.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("下書きのMarkdown記事を作成")
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct RepositorySettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(
                title: "リポジトリ",
                description: "記事を読むHugoソースと、公開先として扱うサブモジュールを確認します。"
            )

            SettingsCard(title: "接続先", systemImage: "externaldrive") {
                repositoryField(
                    title: "Hugoソース",
                    path: model.sourcePath,
                    action: model.chooseSourceFolder
                )
            }

            SettingsCard(title: "公開された生成物", systemImage: "arrow.up.right.square") {
                Text("Hugoソース内の public サブモジュール")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(model.sourcePath.isEmpty ? "Hugoソースを選択してください" : URL(fileURLWithPath: model.sourcePath).appendingPathComponent("public").path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Text("投稿には .nkjblogposter.json の設定が必要です。公開先はHugoソース内のpublicサブモジュールとし、両方のoriginを検証します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func repositoryField(title: String, path: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                Text(path.isEmpty ? "Hugoソースを選択してください" : path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("選択…", action: action)
                    .help("Hugoソースリポジトリのフォルダを選択")
                    .accessibilityLabel("Hugoソースリポジトリを選択")
            }
        }
    }
}
