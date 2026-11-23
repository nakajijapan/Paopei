import AppKit
import Combine
import Foundation

enum AppSettingsSection: Hashable {
    case repository
    case editor
    case articlePrompts
    case ai
    case persona
}

@MainActor
final class AppModel: ObservableObject {
    // `AppModel` is the workspace coordinator. Feature-local state lives in the
    // four observable feature models below; this compatibility surface keeps the
    // existing SwiftUI bindings stable while features are adopted incrementally.
    private let postEditor = PostEditorFeature()
    private let chat = ChatFeature()
    private let images = ImageFeature()
    private let publishing = PublishFeature()

    var posts: [BlogPost] { get { postEditor.posts } set { postEditor.posts = newValue } }
    var selectedPost: BlogPost? { get { postEditor.selectedPost } set { postEditor.selectedPost = newValue } }
    var editorText: String {
        get { postEditor.editorText }
        set {
            postEditor.editorText = newValue
            refreshReferencedImages()
        }
    }
    var savedText: String { get { postEditor.savedText } set { postEditor.savedText = newValue } }
    var searchQuery: String { get { postEditor.searchQuery } set { postEditor.searchQuery = newValue } }
    var filter: PostFilter { get { postEditor.filter } set { postEditor.filter = newValue } }
    var sourcePath: String { get { postEditor.sourcePath } set { postEditor.sourcePath = newValue } }
    @Published var errorMessage: String?
    @Published var statusMessage = ""
    var chatInput: String { get { chat.input } set { chat.input = newValue } }
    var chatMessages: [ChatMessage] { get { chat.messages } set { chat.messages = newValue } }
    private(set) var chatSessions: [ChatSession] { get { chat.sessions } set { chat.sessions = newValue } }
    private(set) var selectedChatSessionID: UUID? { get { chat.selectedSessionID } set { chat.selectedSessionID = newValue } }
    var chatMode: ChatMode { get { chat.mode } set { chat.mode = newValue } }
    var webSearchEnabled: Bool { get { chat.webSearchEnabled } set { chat.webSearchEnabled = newValue } }
    var chatProposal: ChatProposal? { get { chat.proposal } set { chat.proposal = newValue } }
    var personaText: String { get { chat.personaText } set { chat.personaText = newValue } }
    var personaDraft: String { get { chat.personaDraft } set { chat.personaDraft = newValue } }
    private(set) var openRouterModelID: String { get { chat.openRouterModelID } set { chat.openRouterModelID = newValue } }
    private(set) var openRouterModels: [OpenRouterModel] { get { chat.openRouterModels } set { chat.openRouterModels = newValue } }
    private(set) var openRouterAPIKeyStatus: OpenRouterAPIKeyStatus { get { chat.apiKeyStatus } set { chat.apiKeyStatus = newValue } }
    private(set) var isFetchingOpenRouterModels: Bool { get { chat.isFetchingModels } set { chat.isFetchingModels = newValue } }
    private(set) var isSavingAISettings: Bool { get { chat.isSavingSettings } set { chat.isSavingSettings = newValue } }
    var aiSettingsMessage: String? { get { chat.settingsMessage } set { chat.settingsMessage = newValue } }
    var isGenerating: Bool { get { chat.isGenerating } set { chat.isGenerating = newValue } }
    var isPublishing: Bool { get { publishing.isPublishing } set { publishing.isPublishing = newValue } }
    var isImportingImages: Bool { get { images.isImporting } set { images.isImporting = newValue } }
    private(set) var referencedImages: [BlogImage] { get { images.referencedImages } set { images.referencedImages = newValue } }
    private(set) var isLoadingPosts: Bool { get { postEditor.isLoadingPosts } set { postEditor.isLoadingPosts = newValue } }
    var pendingRemoteImage: RemoteImageCandidate? { get { images.pendingRemoteImage } set { images.pendingRemoteImage = newValue } }
    var editorSelectionRequest: EditorSelectionRequest? { get { postEditor.editorSelectionRequest } set { postEditor.editorSelectionRequest = newValue } }
    @Published private(set) var markdownEditorFontSize: CGFloat
    @Published private(set) var articlePromptSettings: ArticlePromptSettings = .defaults
    @Published var articlePromptDraft: ArticlePromptSettings = .defaults
    @Published var showingNewPost = false
    @Published var selectedSettingsSection: AppSettingsSection = .repository

    private let defaults: UserDefaults
    private let chatService: any ChatDraftServing
    private let personaStore: PersonaStore
    private let markdownEditorSettingsStore: MarkdownEditorSettingsStore
    private let articlePromptSettingsStore: ArticlePromptSettingsStore
    private let apiKeyStore: any APIKeyStoring
    private let openRouterSettingsStore: OpenRouterSettingsStore
    private let postLoader = PostLoader()
    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?
    private var pendingUserMessageID: UUID?
    private var pendingAssistantMessageID: UUID?
    private var postsLoadingTask: Task<Void, Never>?
    private var postsLoadingID: UUID?
    private var chatSessionsByPostURL: [URL: [ChatSession]] = [:]
    private var selectedChatSessionIDByPostURL: [URL: UUID] = [:]
    private var featureCancellables = Set<AnyCancellable>()
    private let imageDirectoryObserver = ImageDirectoryObserver()

    init(
        defaults: UserDefaults = .standard,
        chatService: (any ChatDraftServing)? = nil,
        apiKeyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        sourcePath: String? = nil,
        deferAPIKeyStatusRefresh: Bool = false
    ) {
        self.defaults = defaults
        self.apiKeyStore = apiKeyStore
        let openRouterSettingsStore = OpenRouterSettingsStore(defaults: defaults)
        self.openRouterSettingsStore = openRouterSettingsStore
        self.chatService = chatService ?? ChatDraftService(
            apiKeyStore: apiKeyStore,
            settingsStore: openRouterSettingsStore
        )
        personaStore = PersonaStore(defaults: defaults)
        let markdownEditorSettingsStore = MarkdownEditorSettingsStore(defaults: defaults)
        self.markdownEditorSettingsStore = markdownEditorSettingsStore
        let articlePromptSettingsStore = ArticlePromptSettingsStore(defaults: defaults)
        self.articlePromptSettingsStore = articlePromptSettingsStore
        let storedArticlePrompts = articlePromptSettingsStore.load()
        articlePromptSettings = storedArticlePrompts
        articlePromptDraft = storedArticlePrompts
        markdownEditorFontSize = markdownEditorSettingsStore.fontSize()
        openRouterModelID = openRouterSettingsStore.modelID()
        self.sourcePath = sourcePath ?? defaults.string(forKey: "sourceRepositoryPath") ?? ""
        webSearchEnabled = defaults.bool(forKey: "openRouterWebSearchEnabled")
        personaText = personaStore.load() ?? ""
        personaDraft = personaText
        observeFeatureState()
        imageDirectoryObserver.onChange = { [weak self] in
            self?.refreshImagesAfterExternalFileChange()
        }
        if !deferAPIKeyStatusRefresh {
            refreshOpenRouterAPIKeyStatus()
        }
    }

    var isDirty: Bool { postEditor.isDirty }
    var chatAvailability: String {
        switch openRouterAPIKeyStatus {
        case .configured:
            return "OpenRouter: \(openRouterModelID)"
        case .missing:
            return "OpenRouter APIキーをAI設定で保存してください"
        case .keychainError:
            return OpenRouterError.keychain.localizedDescription
        }
    }
    var isChatAvailable: Bool { openRouterAPIKeyStatus == .configured }
    var hasSavedOpenRouterAPIKey: Bool { openRouterAPIKeyStatus == .configured }
    var proposedMarkdown: String? { chatProposal?.markdown }
    var canSendChat: Bool {
        selectedPost != nil
            && isChatAvailable
            && !isGenerating
            && !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (chatMode != .edit || chatProposal == nil)
    }
    var filteredPosts: [BlogPost] { postEditor.filteredPosts }
    var postYearSections: [PostYearSection] { postEditor.postYearSections }

    func load() {
        cancelPostsLoading()
        guard !sourcePath.isEmpty else {
            statusMessage = "設定からHugoソースを選択してください"
            return
        }
        do {
            applyLoadedPosts(try repository().loadPosts())
        } catch {
            present(error)
        }
    }

    /// Reads the article index off the main actor so a large Hugo repository keeps the window responsive.
    func loadInBackground(selecting postURL: URL? = nil) {
        cancelPostsLoading()
        guard !sourcePath.isEmpty else {
            statusMessage = "設定からHugoソースを選択してください"
            return
        }

        let id = UUID()
        let root = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let loader = postLoader
        postsLoadingID = id
        isLoadingPosts = true
        statusMessage = "記事一覧を読み込んでいます…"

        postsLoadingTask = Task { [weak self] in
            do {
                let loadedPosts = try await loader.load(root: root)
                guard !Task.isCancelled, self?.postsLoadingID == id else { return }
                self?.applyLoadedPosts(loadedPosts)
                if let postURL,
                   let post = loadedPosts.first(where: { $0.url == postURL }) {
                    try self?.select(post)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self?.postsLoadingID == id else { return }
                self?.present(error)
            }

            guard self?.postsLoadingID == id else { return }
            self?.isLoadingPosts = false
            self?.postsLoadingID = nil
            self?.postsLoadingTask = nil
        }
    }

    func select(_ post: BlogPost) throws {
        guard !isImportingImages else {
            throw AppError.imageImport("画像の取り込みが完了してから記事を切り替えてください。")
        }
        if isDirty { try save() }
        cancelChatGeneration()
        // 更新案は作成元の記事を開いている間だけ有効。会話は残し、記事切替前に更新案だけを破棄する。
        if selectedPost?.url != post.url {
            chatProposal = nil
        }
        storeChatHistoryForSelectedPost()
        selectedPost = post
        restoreChatSessions(for: post.url)
        chatInput = ""
        editorText = try repository().read(post)
        savedText = editorText
        editorSelectionRequest = EditorSelectionRequest(range: NSRange(location: 0, length: 0))
        statusMessage = post.relativePath
    }

    func save() throws {
        try SavePostUseCase(repository: repository()).execute(markdown: editorText, post: selectedPost)
        savedText = editorText
        refreshSelectedMetadata()
        statusMessage = "保存しました"
    }

    func createChatSession() {
        guard selectedPost != nil, !isGenerating else { return }
        storeChatHistoryForSelectedPost()
        let session = ChatSession()
        chatSessions.append(session)
        selectedChatSessionID = session.id
        chatMessages = []
        chatProposal = nil
        chatInput = ""
        storeChatHistoryForSelectedPost()
        statusMessage = "新しいチャットを作成しました"
    }

    func selectChatSession(_ id: UUID) {
        guard !isGenerating, let session = chatSessions.first(where: { $0.id == id }) else { return }
        selectedChatSessionID = session.id
        chatMessages = session.messages
        chatProposal = session.proposal
        chatInput = ""
        storeChatHistoryForSelectedPost()
    }

    func deleteSelectedChatSession() {
        guard !isGenerating, let selectedChatSessionID,
              let index = chatSessions.firstIndex(where: { $0.id == selectedChatSessionID }) else { return }

        chatSessions.remove(at: index)
        if chatSessions.isEmpty {
            let replacement = ChatSession()
            chatSessions = [replacement]
            self.selectedChatSessionID = replacement.id
            chatMessages = []
            chatProposal = nil
        } else {
            let replacement = chatSessions[min(index, chatSessions.count - 1)]
            self.selectedChatSessionID = replacement.id
            chatMessages = replacement.messages
            chatProposal = replacement.proposal
        }
        chatInput = ""
        storeChatHistoryForSelectedPost()
        statusMessage = "チャットを削除しました"
    }

    func createPost(title: String, category: String) {
        guard !sourcePath.isEmpty else {
            present(AppError.invalidRepository("設定からHugoソースを選択してください。"))
            return
        }
        guard !isImportingImages else {
            present(AppError.imageImport("画像の取り込みが完了してから新規記事を作成してください。"))
            return
        }
        do {
            if isDirty { try save() }
            let post = try repository().createDraft(
                title: title,
                category: category,
                bodyTemplate: articlePromptSettings.newArticleTemplate
            )
            loadInBackground(selecting: post.url)
            showingNewPost = false
        } catch {
            present(error)
        }
    }

    /// Moves a post to Trash after the view has obtained explicit confirmation.
    /// Associated images remain in the Hugo repository so a shared asset is not
    /// unexpectedly removed with one article.
    func movePostToTrash(_ post: BlogPost) {
        guard !isImportingImages, !isPublishing, !isGenerating else {
            present(AppError.invalidRepository("処理中のため記事を削除できません。処理が完了してからもう一度お試しください。"))
            return
        }

        do {
            try repository().moveToTrash(post)
            let wasSelected = selectedPost?.url == post.url
            posts.removeAll { $0.url == post.url }
            chatSessionsByPostURL.removeValue(forKey: post.url)
            selectedChatSessionIDByPostURL.removeValue(forKey: post.url)

            if wasSelected {
                selectedPost = nil
                editorText = ""
                savedText = ""
                editorSelectionRequest = nil
                resetChat()
                if let replacement = posts.first {
                    try select(replacement)
                }
            }
            statusMessage = "記事をゴミ箱に移動しました"
        } catch {
            present(error)
        }
    }

    func chooseSourceFolder() {
        guard !isImportingImages else {
            present(AppError.imageImport("画像の取り込みが完了してからリポジトリを変更してください。"))
            return
        }
        guard let path = chooseFolder(prompt: "Hugoソースを選択") else { return }
        sourcePath = path
        defaults.set(path, forKey: "sourceRepositoryPath")
        cancelChatGeneration()
        chatSessionsByPostURL.removeAll()
        selectedChatSessionIDByPostURL.removeAll()
        resetChat()
        selectedPost = nil
        editorText = ""
        savedText = ""
        loadInBackground()
    }

    func sendChat() {
        let message = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let selectedPost, !isGenerating else { return }
        guard isChatAvailable else {
            appendChatMessage(ChatMessage(role: .system, text: chatAvailability))
            return
        }
        guard chatMode != .edit || chatProposal == nil else {
            appendChatMessage(ChatMessage(
                role: .system,
                text: "未反映の更新案があります。反映または破棄してから次の編集を送信してください。"
            ))
            return
        }

        let history = Array(chatMessages.suffix(12))
        let mode = chatMode
        let targetPostURL = selectedPost.url
        let baseMarkdown = editorText
        chatInput = ""
        let userMessage = ChatMessage(role: .user, text: message)
        appendChatMessage(userMessage)
        updateSelectedChatSessionTitle(with: message)
        pendingUserMessageID = userMessage.id
        let streamingAssistantMessage: ChatMessage?
        if mode == .consultation {
            let assistantMessage = ChatMessage(role: .assistant, text: "")
            appendChatMessage(assistantMessage)
            pendingAssistantMessageID = assistantMessage.id
            streamingAssistantMessage = assistantMessage
        } else {
            pendingAssistantMessageID = nil
            streamingAssistantMessage = nil
        }
        isGenerating = true
        let request = ChatDraftRequest(
            markdown: baseMarkdown,
            message: message,
            persona: personaText,
            mode: mode,
            history: history,
            webSearchEnabled: webSearchEnabled && mode == .consultation,
            editingInstructions: articlePromptSettings.editingInstructions
        )
        let id = UUID()
        generationID = id

        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generationID == id {
                    self.isGenerating = false
                    self.generationID = nil
                    self.pendingUserMessageID = nil
                    self.pendingAssistantMessageID = nil
                    self.generationTask = nil
                }
            }
            do {
                let response: ChatDraftResponse
                switch mode {
                case .consultation:
                    guard let streamingAssistantMessage else { return }
                    response = try await self.chatService.stream(request) { [weak self] delta in
                        guard let self, self.generationID == id else { return }
                        self.appendStreamingDelta(delta, to: streamingAssistantMessage.id)
                    }
                case .edit:
                    response = try await self.chatService.generate(request)
                }
                try Task.checkCancellation()
                guard self.generationID == id else { return }
                guard self.selectedPost?.url == targetPostURL,
                      self.editorText == baseMarkdown else {
                    if let streamingAssistantMessage {
                        self.removeChatMessage(id: streamingAssistantMessage.id)
                    }
                    self.appendChatMessage(ChatMessage(
                        role: .system,
                        text: "生成中に記事または本文が変更されたため、結果を破棄しました。"
                    ))
                    return
                }

                switch mode {
                case .consultation:
                    guard !response.content.isEmpty else {
                        throw AppError.invalidChatProposal("回答が空でした。もう一度お試しください。")
                    }
                    if let streamingAssistantMessage {
                        self.replaceChatMessage(
                            id: streamingAssistantMessage.id,
                            with: ChatMessage(
                                id: streamingAssistantMessage.id,
                                role: .assistant,
                                text: response.content,
                                citations: response.citations
                            )
                        )
                    }
                case .edit:
                    try ChatDraftService.validateProposal(response.content, baseMarkdown: baseMarkdown)
                    self.chatProposal = ChatProposal(
                        postURL: targetPostURL,
                        baseMarkdown: baseMarkdown,
                        markdown: response.content
                    )
                    self.storeChatHistoryForSelectedPost()
                    self.appendChatMessage(ChatMessage(
                        role: .assistant,
                        text: "記事の更新案を作りました。内容を確認して「記事に反映」を押してください。"
                    ))
                }
            } catch is CancellationError {
                return
            } catch {
                if let streamingAssistantMessage,
                   self.chatMessages.first(where: { $0.id == streamingAssistantMessage.id })?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    self.removeChatMessage(id: streamingAssistantMessage.id)
                }
                self.appendChatMessage(ChatMessage(role: .system, text: error.localizedDescription))
            }
        }
    }

    func applyProposal() {
        guard let proposal = chatProposal else { return }
        do {
            let appliedMarkdown = try ApplyChatProposalUseCase(repository: repository()).execute(
                proposal: proposal,
                selectedPost: selectedPost,
                currentMarkdown: editorText
            )
            editorText = appliedMarkdown
            savedText = appliedMarkdown
            refreshSelectedMetadata()
            chatProposal = nil
            storeChatHistoryForSelectedPost()
            statusMessage = "チャットの更新案を保存して反映しました"
        } catch {
            present(error)
        }
    }

    func discardProposal() {
        chatProposal = nil
        storeChatHistoryForSelectedPost()
        statusMessage = "チャットの更新案を破棄しました"
    }

    func cancelChatGeneration() {
        guard generationID != nil else { return }
        generationTask?.cancel()
        let hasGeneratedText = pendingAssistantMessageID.flatMap { id in
            chatMessages.first(where: { $0.id == id })?.text
        }?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !hasGeneratedText, let pendingUserMessageID {
            chatMessages.removeAll { $0.id == pendingUserMessageID }
            if let pendingAssistantMessageID {
                chatMessages.removeAll { $0.id == pendingAssistantMessageID }
            }
            storeChatHistoryForSelectedPost()
        }
        generationTask = nil
        generationID = nil
        pendingUserMessageID = nil
        pendingAssistantMessageID = nil
        isGenerating = false
    }

    func setWebSearchEnabled(_ enabled: Bool) {
        webSearchEnabled = enabled
        defaults.set(enabled, forKey: "openRouterWebSearchEnabled")
    }

    func setMarkdownEditorFontSize(_ fontSize: CGFloat) {
        markdownEditorSettingsStore.saveFontSize(fontSize)
        markdownEditorFontSize = markdownEditorSettingsStore.fontSize()
    }

    func beginEditingPersona() {
        personaDraft = personaText
    }

    func beginEditingArticlePrompts() {
        articlePromptSettings = articlePromptSettingsStore.load()
        articlePromptDraft = articlePromptSettings
    }

    func saveArticlePrompts() throws {
        try articlePromptSettingsStore.save(articlePromptDraft)
        articlePromptSettings = articlePromptSettingsStore.load()
        articlePromptDraft = articlePromptSettings
        statusMessage = "記事の作成・編集設定を保存しました"
    }

    func savePersona() throws {
        try personaStore.save(personaDraft)
        personaText = personaStore.load() ?? ""
        personaDraft = personaText
        statusMessage = personaStore.load() == nil
            ? "人格設定を既存のv3.mdへ戻しました"
            : "人格設定を保存しました"
    }

    func prepareAISettings() {
        aiSettingsMessage = nil
        refreshOpenRouterAPIKeyStatus()
        if openRouterAPIKeyStatus == .keychainError {
            aiSettingsMessage = OpenRouterError.keychain.localizedDescription
        }
        openRouterModelID = openRouterSettingsStore.modelID()
    }

    func saveAISettings(apiKey: String, modelID: String) throws {
        cancelChatGeneration()
        isSavingAISettings = true
        defer { isSavingAISettings = false }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmedKey.isEmpty {
                try apiKeyStore.save(trimmedKey)
            }
        } catch {
            throw OpenRouterError.keychain
        }
        openRouterSettingsStore.saveModelID(modelID)
        openRouterModelID = openRouterSettingsStore.modelID()
        prepareAISettings()
        statusMessage = "OpenRouterのAI設定を保存しました"
    }

    func deleteOpenRouterAPIKey() throws {
        cancelChatGeneration()
        isSavingAISettings = true
        defer { isSavingAISettings = false }
        do {
            try apiKeyStore.delete()
        } catch {
            throw OpenRouterError.keychain
        }
        refreshOpenRouterAPIKeyStatus()
        aiSettingsMessage = openRouterAPIKeyStatus == .keychainError
            ? OpenRouterError.keychain.localizedDescription
            : nil
        statusMessage = "OpenRouter APIキーを削除しました"
    }

    func fetchOpenRouterModels() {
        guard !isFetchingOpenRouterModels else { return }
        guard hasSavedOpenRouterAPIKey else {
            aiSettingsMessage = OpenRouterError.missingAPIKey.localizedDescription
            return
        }
        isFetchingOpenRouterModels = true
        aiSettingsMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isFetchingOpenRouterModels = false }
            do {
                self.openRouterModels = try await self.chatService.fetchModels()
                if self.openRouterModels.isEmpty {
                    self.aiSettingsMessage = "OpenRouterから利用可能なモデルを取得できませんでした。モデルIDは手入力できます。"
                }
            } catch is CancellationError {
                return
            } catch {
                self.aiSettingsMessage = error.localizedDescription
            }
        }
    }

    /// Reads the Keychain after the first window exists. A protected Keychain can
    /// display a system prompt; doing that from `App` initialization prevents
    /// macOS from creating the window at all.
    func refreshOpenRouterAPIKeyStatus() {
        do {
            let value = try apiKeyStore.load()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            openRouterAPIKeyStatus = value?.isEmpty == false ? .configured : .missing
        } catch {
            openRouterAPIKeyStatus = .keychainError
        }
    }

    func importImages(_ urls: [URL]) {
        importImages(urls.map(BlogImageInput.file))
    }

    func importImages(_ inputs: [BlogImageInput]) {
        guard let targetPostURL = selectedPost?.url, !inputs.isEmpty, !isImportingImages else { return }
        let repositoryRoot = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let articleDate = FrontMatterParser.parse(editorText).date ?? Date()
        isImportingImages = true
        statusMessage = "画像を取り込んでいます…"

        Task {
            defer { isImportingImages = false }
            var importedImages: [BlogImage] = []
            do {
                importedImages = try await Task.detached(priority: .userInitiated) {
                    try BlogImageRepository(root: repositoryRoot)
                        .importImages(inputs, articleDate: articleDate)
                }.value
                guard selectedPost?.url == targetPostURL else {
                    throw AppError.imageImport("記事が切り替わったため画像の取り込みを中止しました。")
                }
                guard !importedImages.isEmpty else { return }
                let markdown = importedImages.map(\.markdown).joined(separator: "\n")
                editorText = ImageInsertionUseCase.appending(markdown, to: editorText)
                try save()
                statusMessage = "\(importedImages.count)枚の画像を保存し、記事末尾へ追加しました"
            } catch {
                for image in importedImages {
                    try? FileManager.default.removeItem(at: image.fileURL)
                }
                present(error)
            }
        }
    }

    /// Stages a remote image for explicit user confirmation. No network call occurs here.
    func requestRemoteImageImport(
        _ imageURL: URL,
        sourcePageURL: URL? = nil,
        insertion: ImageInsertion = .append
    ) {
        guard selectedPost != nil else {
            present(AppError.imageImport("画像を追加する記事を選択してください。"))
            return
        }
        guard !isImportingImages else {
            present(AppError.imageImport("画像の取り込みが完了してからもう一度お試しください。"))
            return
        }
        do {
            try RemoteImageDownloadService.validatePublicHTTPSURL(imageURL)
            pendingRemoteImage = RemoteImageCandidate(
                imageURL: imageURL,
                sourcePageURL: sourcePageURL,
                insertion: insertion
            )
        } catch {
            present(error)
        }
    }

    func cancelRemoteImageImport() {
        pendingRemoteImage = nil
    }

    func confirmRemoteImageImport() {
        guard let candidate = pendingRemoteImage,
              let targetPostURL = selectedPost?.url,
              !isImportingImages else { return }
        pendingRemoteImage = nil

        let baseMarkdown = editorText
        let insertionRange: NSRange
        switch candidate.insertion {
        case .append:
            insertionRange = NSRange(location: (baseMarkdown as NSString).length, length: 0)
        case .replace(let range):
            insertionRange = range
        }
        let markdownLength = (baseMarkdown as NSString).length
        guard insertionRange.location <= markdownLength,
              insertionRange.length <= markdownLength - insertionRange.location else {
            present(AppError.imageImport("画像の挿入位置を取得できませんでした。"))
            return
        }

        let repositoryRoot = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let articleDate = FrontMatterParser.parse(baseMarkdown).date ?? selectedPost?.date ?? Date()
        isImportingImages = true
        statusMessage = "Web画像を取り込んでいます…"

        Task { [weak self] in
            guard let self else { return }
            var importedImages: [BlogImage] = []
            var updatedMarkdown: String?
            defer { self.isImportingImages = false }
            do {
                let downloaded = try await RemoteImageDownloadService().download(candidate.imageURL)
                try Task.checkCancellation()
                importedImages = try await Task.detached(priority: .userInitiated) {
                    try BlogImageRepository(root: repositoryRoot).importImages(
                        [.data(downloaded.data, fileExtension: downloaded.fileExtension)],
                        articleDate: articleDate
                    )
                }.value
                guard self.selectedPost?.url == targetPostURL, self.editorText == baseMarkdown else {
                    throw AppError.imageImport("画像の取り込み中に記事または本文が変更されたため、中止しました。")
                }
                guard let image = importedImages.first else { return }
                let attributionURL = candidate.sourcePageURL ?? downloaded.sourceURL
                let markdown = image.markdown + "\n\n画像の出典: <\(attributionURL.absoluteString)>"
                let replacement = try ImageInsertionUseCase.replacing(
                    markdown: baseMarkdown,
                    range: insertionRange,
                    replacement: markdown
                )
                updatedMarkdown = replacement
                self.editorText = replacement
                self.editorSelectionRequest = EditorSelectionRequest(range: NSRange(
                    location: insertionRange.location + (markdown as NSString).length,
                    length: 0
                ))
                try self.save()
                self.statusMessage = "Web画像を保存し、出典URL付きでMarkdownへ挿入しました"
            } catch is CancellationError {
                // The user cancelled before any article change was made.
            } catch {
                if let updatedMarkdown, self.editorText == updatedMarkdown {
                    self.editorText = baseMarkdown
                    self.editorSelectionRequest = EditorSelectionRequest(range: insertionRange)
                }
                for image in importedImages { try? FileManager.default.removeItem(at: image.fileURL) }
                self.present(error)
            }
        }
    }

    @discardableResult
    func importPastedImages(_ inputs: [BlogImageInput], replacing selection: NSRange) -> Bool {
        guard let targetPostURL = selectedPost?.url, !inputs.isEmpty else { return false }
        guard !isImportingImages else {
            statusMessage = "画像の取り込みが完了してからもう一度ペーストしてください"
            NSSound.beep()
            return true
        }

        let baseMarkdown = editorText
        let markdownLength = (baseMarkdown as NSString).length
        guard selection.location <= markdownLength,
              selection.length <= markdownLength - selection.location else {
            present(AppError.imageImport("画像の挿入位置を取得できませんでした。もう一度ペーストしてください。"))
            return true
        }

        let repositoryRoot = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let articleDate = FrontMatterParser.parse(baseMarkdown).date ?? selectedPost?.date ?? Date()
        isImportingImages = true
        statusMessage = "クリップボードの画像を取り込んでいます…"

        Task {
            defer { isImportingImages = false }
            var importedImages: [BlogImage] = []
            var updatedMarkdown: String?
            do {
                importedImages = try await Task.detached(priority: .userInitiated) {
                    try BlogImageRepository(root: repositoryRoot)
                        .importImages(inputs, articleDate: articleDate)
                }.value
                guard selectedPost?.url == targetPostURL, editorText == baseMarkdown else {
                    throw AppError.imageImport("画像の取り込み中に記事または本文が変更されたため、ペーストを中止しました。")
                }
                guard !importedImages.isEmpty else { return }

                let markdown = importedImages.map(\.markdown).joined(separator: "\n")
                let replacement = try ImageInsertionUseCase.replacing(
                    markdown: baseMarkdown,
                    range: selection,
                    replacement: markdown
                )
                updatedMarkdown = replacement
                editorText = replacement
                editorSelectionRequest = EditorSelectionRequest(range: NSRange(
                    location: selection.location + (markdown as NSString).length,
                    length: 0
                ))
                try save()
                statusMessage = "\(importedImages.count)枚の画像を保存し、選択位置へMarkdownを挿入しました"
            } catch {
                if let updatedMarkdown, editorText == updatedMarkdown {
                    editorText = baseMarkdown
                    editorSelectionRequest = EditorSelectionRequest(range: selection)
                }
                for image in importedImages {
                    try? FileManager.default.removeItem(at: image.fileURL)
                }
                present(error)
            }
        }
        return true
    }

    func publish() {
        guard let selectedPost, !isPublishing else { return }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let useCase = PublishPostUseCase(sourceRepository: source)
        let configuration = useCase.configuration(for: selectedPost, markdown: editorText)
        let candidateMarkdown = editorText
        isPublishing = true
        statusMessage = "投稿前の環境を確認しています…"

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try useCase.preflight(configuration, markdown: candidateMarkdown)
                }.value
                editorText = FrontMatterParser.replacingField("draft", with: "false", in: editorText)
                try save()
                statusMessage = "Hugoでビルドして投稿しています…"
                let report = try await Task.detached(priority: .userInitiated) {
                    try useCase.publish(configuration)
                }.value
                statusMessage = "投稿が完了しました"
                appendChatMessage(ChatMessage(role: .system, text: report.summary))
                loadInBackground()
            } catch {
                present(error)
            }
            isPublishing = false
        }
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "エラー"
    }

    /// SwiftUI observes the workspace coordinator, while each feature owns its
    /// own state. Forwarding feature changes preserves existing bindings during
    /// the incremental migration and prevents a child feature from silently
    /// updating without invalidating the workspace view.
    private func observeFeatureState() {
        [postEditor.objectWillChange, chat.objectWillChange, images.objectWillChange, publishing.objectWillChange]
            .forEach { publisher in
                publisher
                    .sink { [weak self] _ in self?.objectWillChange.send() }
                    .store(in: &featureCancellables)
            }
    }

    private func repository() -> BlogRepository {
        BlogRepository(root: URL(fileURLWithPath: sourcePath, isDirectory: true))
    }

    private func applyLoadedPosts(_ loadedPosts: [BlogPost]) {
        posts = loadedPosts
        statusMessage = "\(posts.count)件の記事"
        if let selectedPost,
           let refreshed = posts.first(where: { $0.url == selectedPost.url }) {
            self.selectedPost = refreshed
            reloadSelectedEditorIfUnchanged(refreshed)
        } else if self.selectedPost == nil, let first = posts.first {
            do {
                try select(first)
            } catch {
                present(error)
            }
        }
    }

    /// Refreshes a clean editor after a Markdown file was changed outside this view.
    /// Unsaved local edits always take precedence, so a manual reload cannot discard them.
    private func reloadSelectedEditorIfUnchanged(_ post: BlogPost) {
        guard !isDirty else { return }
        do {
            let markdown = try repository().read(post)
            guard markdown != editorText else { return }
            editorText = markdown
            savedText = markdown
            editorSelectionRequest = nil
            chatProposal = nil
            storeChatHistoryForSelectedPost()
            refreshSelectedMetadata()
            statusMessage = "Markdownファイルの更新を反映しました"
        } catch {
            present(error)
        }
    }

    private func cancelPostsLoading() {
        postsLoadingTask?.cancel()
        postsLoadingTask = nil
        postsLoadingID = nil
        isLoadingPosts = false
    }

    private func resetChat() {
        chatMessages = []
        chatSessions = []
        selectedChatSessionID = nil
        chatProposal = nil
        chatInput = ""
    }

    private func storeChatHistoryForSelectedPost() {
        guard let selectedPost else { return }
        syncVisibleChatToSelectedSession()
        chatSessionsByPostURL[selectedPost.url] = chatSessions
        selectedChatSessionIDByPostURL[selectedPost.url] = selectedChatSessionID
    }

    private func restoreChatSessions(for postURL: URL) {
        let sessions = chatSessionsByPostURL[postURL] ?? [ChatSession()]
        let selectedID = selectedChatSessionIDByPostURL[postURL]
        let session = sessions.first(where: { $0.id == selectedID }) ?? sessions[0]
        chatSessions = sessions
        selectedChatSessionID = session.id
        chatMessages = session.messages
        chatProposal = session.proposal
    }

    private func appendChatMessage(_ message: ChatMessage) {
        chatMessages.append(message)
        syncVisibleChatToSelectedSession()
    }

    private func appendStreamingDelta(_ delta: ChatDraftStreamDelta, to messageID: UUID) {
        guard let index = chatMessages.firstIndex(where: { $0.id == messageID }) else { return }
        let message = chatMessages[index]
        var seenCitationIDs = Set(message.citations.map(\.id))
        let citations = message.citations + delta.citations.filter { seenCitationIDs.insert($0.id).inserted }
        chatMessages[index] = ChatMessage(
            id: message.id,
            role: message.role,
            text: message.text + delta.content,
            citations: citations
        )
        syncVisibleChatToSelectedSession()
    }

    private func replaceChatMessage(id: UUID, with message: ChatMessage) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[index] = message
        syncVisibleChatToSelectedSession()
    }

    private func removeChatMessage(id: UUID) {
        chatMessages.removeAll { $0.id == id }
        syncVisibleChatToSelectedSession()
    }

    private func updateSelectedChatSessionTitle(with message: String) {
        guard let index = chatSessions.firstIndex(where: { $0.id == selectedChatSessionID }),
              chatSessions[index].title == "新しいチャット" else { return }
        let title = String(message.prefix(36)).trimmingCharacters(in: .whitespacesAndNewlines)
        chatSessions[index].title = title.isEmpty ? "新しいチャット" : title
        storeChatHistoryForSelectedPost()
    }

    private func syncVisibleChatToSelectedSession() {
        guard let index = chatSessions.firstIndex(where: { $0.id == selectedChatSessionID }) else { return }
        chatSessions[index].messages = chatMessages
        chatSessions[index].proposal = chatProposal
    }

    private func refreshSelectedMetadata() {
        refreshReferencedImages()
        refreshSelectedMetadataUsingCurrentImages()
    }

    private func refreshSelectedMetadataUsingCurrentImages() {
        guard let selectedPost else { return }
        let frontMatter = FrontMatterParser.parse(editorText)
        let previewImages = Array(referencedImages.filter(\.exists).prefix(3))
        let refreshed = BlogPost(
            url: selectedPost.url,
            title: frontMatter.title,
            date: frontMatter.date ?? selectedPost.date,
            isDraft: frontMatter.isDraft,
            category: frontMatter.category,
            slug: frontMatter.slug,
            previewImages: previewImages
        )
        self.selectedPost = refreshed
        if let index = posts.firstIndex(where: { $0.url == refreshed.url }) {
            posts[index] = refreshed
        }
    }

    /// Keeps the image-management list in sync with editor and asynchronous drop imports.
    private func refreshReferencedImages() {
        referencedImages = BlogImageRepository(
            root: URL(fileURLWithPath: sourcePath, isDirectory: true)
        ).referencedImages(in: editorText)
        imageDirectoryObserver.observe(
            directories: referencedImages.map { $0.fileURL.deletingLastPathComponent() }
        )
    }

    /// Reconciles the image UI after Finder changes a referenced image. Markdown
    /// remains untouched: a missing reference is shown as such so the author can
    /// decide whether to restore the file or remove the Markdown themselves.
    func refreshImagesAfterExternalFileChange() {
        guard selectedPost != nil else { return }
        refreshReferencedImages()
        refreshSelectedMetadataUsingCurrentImages()
        statusMessage = "Finderでの画像変更を反映しました"
    }

    private func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
