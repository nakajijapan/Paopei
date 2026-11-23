import Combine
import Foundation
import XCTest
@testable import NKJBlogPoster

@MainActor
final class AppModelTests: XCTestCase {
    func testUnconfiguredSourceDoesNotLoadOrCreatePosts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(defaults: fixture.defaults, apiKeyStore: fixture.apiKeyStore)

        XCTAssertEqual(model.sourcePath, "")
        model.loadInBackground()
        XCTAssertFalse(model.isLoadingPosts)
        XCTAssertTrue(model.posts.isEmpty)
        XCTAssertTrue(model.statusMessage.contains("Hugoソース"))
        model.createPost(title: "新規記事", category: "")
        XCTAssertTrue((model.errorMessage ?? "").contains("Hugoソース"))
    }

    func testFeatureStateChangesPropagateToWorkspaceObjectWillChange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        func assertWorkspaceNotification(
            _ feature: String,
            action: @escaping @MainActor () -> Void
        ) async {
            let change = expectation(description: "\(feature) reaches the workspace")
            change.assertForOverFulfill = true
            let observation = model.objectWillChange.sink { change.fulfill() }
            Task { @MainActor in action() }
            await fulfillment(of: [change], timeout: 1)
            observation.cancel()
        }

        await assertWorkspaceNotification("PostEditorFeature") {
            model.searchQuery = "SwiftUI"
        }
        await assertWorkspaceNotification("ChatFeature") {
            model.chatInput = "記事を確認して"
        }
        await assertWorkspaceNotification("ImageFeature") {
            model.pendingRemoteImage = RemoteImageCandidate(
                imageURL: URL(string: "https://example.com/image.png")!,
                sourcePageURL: nil,
                insertion: .append
            )
        }
        await assertWorkspaceNotification("PublishFeature") {
            model.isPublishing = true
        }
    }

    func testPostYearSectionsSortYearsPreservePostOrderAndPlaceUndatedPostsLast() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        let calendar = Calendar.current
        let year2026 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let year2025 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        model.posts = [
            post(title: "2025年の記事", date: year2025, isDraft: false),
            post(title: "日付なしの記事", date: nil, isDraft: false),
            post(title: "2026年の先頭", date: year2026, isDraft: true),
            post(title: "2026年の次", date: year2026, isDraft: false)
        ]

        let sections = model.postYearSections

        XCTAssertEqual(sections.map(\.year), [2026, 2025, nil])
        XCTAssertEqual(sections.map(\.title), ["2026年", "2025年", "日付未設定"])
        XCTAssertEqual(sections[0].posts.map(\.title), ["2026年の先頭", "2026年の次"])
        XCTAssertEqual(sections[1].posts.map(\.title), ["2025年の記事"])
        XCTAssertEqual(sections[2].posts.map(\.title), ["日付なしの記事"])
    }

    func testPostYearSectionsApplyFilterAndSearchBeforeGrouping() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        let calendar = Calendar.current
        let year2026 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let year2024 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        model.posts = [
            post(title: "公開済みSwift", date: year2026, isDraft: false, slug: "swift-public"),
            post(title: "下書きSwift", date: year2024, isDraft: true, slug: "swift-draft"),
            post(title: "公開済みRust", date: nil, isDraft: false, slug: "rust-public")
        ]
        model.filter = .published
        model.searchQuery = "swift"

        let sections = model.postYearSections

        XCTAssertEqual(sections.map(\.year), [2026])
        XCTAssertEqual(sections.flatMap(\.posts).map(\.title), ["公開済みSwift"])
    }

    func testPostYearSectionsApplyDraftFilterToDatedAndUndatedPosts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        let draftDate = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1))
        )
        model.posts = [
            post(title: "公開済みの記事", date: draftDate, isDraft: false),
            post(title: "日付ありの下書き", date: draftDate, isDraft: true),
            post(title: "日付なしの下書き", date: nil, isDraft: true),
            post(title: "日付なしの公開済み記事", date: nil, isDraft: false)
        ]
        model.filter = .drafts

        let sections = model.postYearSections

        XCTAssertEqual(sections.map(\.year), [2026, nil])
        XCTAssertEqual(sections[0].posts.map(\.title), ["日付ありの下書き"])
        XCTAssertEqual(sections[1].title, "日付未設定")
        XCTAssertEqual(sections[1].posts.map(\.title), ["日付なしの下書き"])
    }

    func testBackgroundLoadSelectsFirstPostAndReturnsToIdle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )

        model.loadInBackground()
        XCTAssertTrue(model.isLoadingPosts)
        await waitForPostsLoading(model)

        XCTAssertFalse(model.isLoadingPosts)
        XCTAssertEqual(model.posts.count, 2)
        XCTAssertNotNil(model.selectedPost)
        XCTAssertEqual(model.statusMessage, model.selectedPost?.relativePath)
    }

    func testRepeatedBackgroundLoadsLeaveTheNewestLoadApplied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )

        model.loadInBackground()
        model.loadInBackground()
        await waitForPostsLoading(model)

        XCTAssertFalse(model.isLoadingPosts)
        XCTAssertEqual(model.posts.count, 2)
        XCTAssertNotNil(model.selectedPost)
    }

    func testCreatePostLoadsAndSelectsNewDraftInBackground() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()

        model.createPost(title: "非同期の新規下書き", category: "tech")
        await waitForPostsLoading(model)

        XCTAssertEqual(model.posts.count, 3)
        XCTAssertEqual(model.selectedPost?.title, "非同期の新規下書き")
        XCTAssertFalse(model.isDirty)
    }

    func testSavedTemplateSurvivesRelaunchAndOnlyChangesNewArticles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(defaults: fixture.defaults, apiKeyStore: fixture.apiKeyStore, sourcePath: fixture.root.path)
        model.articlePromptDraft.newArticleTemplate = "# 独自の見出し\n\n本文のひな形"
        XCTAssertEqual(model.articlePromptSettings, .defaults)
        model.beginEditingArticlePrompts()
        XCTAssertEqual(model.articlePromptDraft, .defaults)

        model.articlePromptDraft.newArticleTemplate = "# 独自の見出し\n\n本文のひな形"
        try model.saveArticlePrompts()
        let restored = AppModel(defaults: fixture.defaults, apiKeyStore: fixture.apiKeyStore, sourcePath: fixture.root.path)
        restored.createPost(title: "テンプレートの確認", category: "tech")
        await waitForPostsLoading(restored)

        let posts = try BlogRepository(root: fixture.root).loadPosts()
        let created = try XCTUnwrap(posts.first(where: { $0.title == "テンプレートの確認" }))
        let markdown = try BlogRepository(root: fixture.root).read(created)
        XCTAssertTrue(markdown.hasSuffix("# 独自の見出し\n\n本文のひな形\n"))
        XCTAssertTrue(markdown.contains("draft: true"))
        XCTAssertFalse(markdown.contains("# きっかけ"))
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("content/posts/2026/a.md"), encoding: .utf8), fixture.markdown)
    }

    func testAIEditUsesSavedInstructionsRatherThanUnsavedSettingsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = MockChatState(responses: [fixture.markdown])
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: state),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        let post = try XCTUnwrap(model.posts.first(where: { $0.title == "記事A" }))
        try model.select(post)
        model.articlePromptDraft.editingInstructions = "見出しを保って文章を短くしてください。"
        try model.saveArticlePrompts()
        model.articlePromptDraft.editingInstructions = "まだ保存しない指示"
        model.chatMode = .edit
        model.chatInput = "本文を整えて"
        model.sendChat()
        await waitForGeneration(model)

        let requests = await state.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.editingInstructions, "見出しを保って文章を短くしてください。")
        XCTAssertNotNil(model.chatProposal)
    }

    func testConsultationUsesHistoryAndSavedPersona() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = MockChatState(responses: ["最初の回答", "次の回答"])
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: state),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.personaDraft = "端的な一人称"
        try model.savePersona()

        model.chatInput = "最初の相談"
        model.sendChat()
        await waitForGeneration(model)
        model.chatInput = "続きの相談"
        model.sendChat()
        await waitForGeneration(model)

        let requests = await state.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].mode, .consultation)
        XCTAssertEqual(requests[0].persona, "端的な一人称")
        XCTAssertTrue(requests[1].history.contains(where: { $0.text == "最初の回答" }))
        XCTAssertEqual(model.chatMessages.last?.text, "次の回答")

        let restored = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        XCTAssertEqual(restored.personaText, "端的な一人称")
    }

    func testArticleKeepsMultipleIndependentChatSessions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = MockChatState(responses: ["最初の回答", "次の回答"])
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: state),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()

        model.chatInput = "最初の相談"
        model.sendChat()
        await waitForGeneration(model)
        let firstSessionID = try XCTUnwrap(model.selectedChatSessionID)
        XCTAssertEqual(model.chatSessions.count, 1)
        XCTAssertEqual(model.chatSessions[0].title, "最初の相談")

        model.createChatSession()
        let secondSessionID = try XCTUnwrap(model.selectedChatSessionID)
        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertTrue(model.chatMessages.isEmpty)

        model.chatInput = "別テーマの相談"
        model.sendChat()
        await waitForGeneration(model)
        XCTAssertEqual(model.chatSessions.count, 2)
        XCTAssertEqual(model.chatMessages.last?.text, "次の回答")

        model.selectChatSession(firstSessionID)
        XCTAssertEqual(model.chatMessages.last?.text, "最初の回答")

        let requests = await state.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests[1].history.contains(where: { $0.text == "最初の回答" }))

        model.deleteSelectedChatSession()
        XCTAssertEqual(model.chatSessions.count, 1)
        XCTAssertEqual(model.selectedChatSessionID, secondSessionID)
        XCTAssertEqual(model.chatMessages.last?.text, "次の回答")
    }

    func testEmptyPersonaDoesNotReadRepositoryFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )

        XCTAssertEqual(model.personaText, "")
        model.personaDraft = ""
        try model.savePersona()
        XCTAssertEqual(model.personaText, "")
    }

    func testEditProposalRejectsManualChangesAndIsNotSilentlyReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = fixture.markdown.replacingOccurrences(of: "本文A", with: "更新本文")
        let state = MockChatState(responses: [candidate])
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: state),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatMode = .edit
        model.chatInput = "本文を更新して"
        model.sendChat()
        await waitForGeneration(model)
        let proposal = try XCTUnwrap(model.chatProposal)

        model.chatInput = "別の編集"
        model.sendChat()
        XCTAssertEqual(model.chatProposal, proposal)
        XCTAssertTrue(model.chatMessages.contains(where: { $0.text.contains("未反映の更新案") }))

        model.editorText += "手編集"
        model.applyProposal()
        XCTAssertNotNil(model.chatProposal)
        XCTAssertTrue(model.errorMessage?.contains("本文が編集された") == true)
    }

    func testApplyingEditProposalSavesMarkdownAndRefreshesPostMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = fixture.markdown
            .replacingOccurrences(of: "記事A", with: "保存済みの記事A")
            .replacingOccurrences(of: "本文A", with: "保存済みの本文")
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [candidate])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        try model.select(try XCTUnwrap(model.posts.first(where: { $0.title == "記事A" })))
        let selectedURL = try XCTUnwrap(model.selectedPost?.url)
        model.chatMode = .edit
        model.chatInput = "本文を更新して"
        model.sendChat()
        await waitForGeneration(model)

        model.applyProposal()

        XCTAssertEqual(try String(contentsOf: selectedURL, encoding: .utf8), candidate)
        XCTAssertEqual(model.editorText, candidate)
        XCTAssertEqual(model.savedText, candidate)
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.chatProposal)
        XCTAssertEqual(model.selectedPost?.title, "保存済みの記事A")
        XCTAssertEqual(
            model.posts.first(where: { $0.url == selectedURL })?.title,
            "保存済みの記事A"
        )
    }

    func testReloadRefreshesCleanEditorAndSidebarAfterExternalMarkdownWrite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        let selectedURL = try XCTUnwrap(model.selectedPost?.url)
        let originalTitle = try XCTUnwrap(model.selectedPost?.title)
        let externallyUpdated = model.editorText
            .replacingOccurrences(of: originalTitle, with: "外部更新された記事")
            .replacingOccurrences(of: "本文A", with: "外部更新された本文。十分に長くしてファイルサイズも変えます。")
        try externallyUpdated.write(to: selectedURL, atomically: true, encoding: .utf8)

        model.load()

        XCTAssertEqual(model.editorText, externallyUpdated)
        XCTAssertEqual(model.savedText, externallyUpdated)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.selectedPost?.title, "外部更新された記事")
        XCTAssertEqual(
            model.posts.first(where: { $0.url == selectedURL })?.title,
            "外部更新された記事"
        )
    }

    func testSwitchingPostRestoresChatForEachPostAndDiscardsProposal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = fixture.markdown.replacingOccurrences(of: "本文A", with: "更新本文")
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [candidate])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatMode = .edit
        model.chatInput = "更新"
        model.sendChat()
        await waitForGeneration(model)
        XCTAssertNotNil(model.chatProposal)
        let initialHistory = model.chatMessages

        let other = try XCTUnwrap(model.posts.first(where: { $0.url != model.selectedPost?.url }))
        try model.select(other)

        XCTAssertNil(model.chatProposal)
        XCTAssertTrue(model.chatMessages.isEmpty)
        XCTAssertEqual(model.selectedPost?.url, other.url)

        model.chatInput = "別の記事の相談"
        model.sendChat()
        await waitForGeneration(model)
        let otherHistory = model.chatMessages

        let initial = try XCTUnwrap(model.posts.first(where: { $0.url != other.url }))
        try model.select(initial)

        XCTAssertEqual(model.selectedPost?.url, initial.url)
        XCTAssertEqual(model.chatMessages, initialHistory)
        XCTAssertNil(model.chatProposal)

        try model.select(other)
        XCTAssertEqual(model.chatMessages, otherHistory)
    }

    func testUnavailableServiceCannotSend() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: UnavailableChatService(),
            apiKeyStore: InMemoryAPIKeyStore(),
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "相談"

        XCTAssertFalse(model.canSendChat)
        model.sendChat()
        XCTAssertEqual(model.openRouterAPIKeyStatus, .missing)
        XCTAssertEqual(model.chatMessages.last?.text, "OpenRouter APIキーをAI設定で保存してください")
    }

    func testKeychainFailureStatusDisablesChatWithoutExposingSecret() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: FailingAPIKeyStore(),
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "相談"

        XCTAssertEqual(model.openRouterAPIKeyStatus, .keychainError)
        XCTAssertFalse(model.canSendChat)
        model.sendChat()
        XCTAssertEqual(model.chatMessages.last?.text, "KeychainからOpenRouter APIキーを読み取れませんでした。")
    }

    func testAvailabilityReadsKeyStoreOnlyDuringExplicitRefresh() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let keyStore = CountingAPIKeyStore(value: "fake-key")
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: keyStore,
            sourcePath: fixture.root.path
        )
        XCTAssertEqual(keyStore.loadCount, 1)

        for _ in 0..<20 {
            _ = model.chatAvailability
            _ = model.isChatAvailable
            _ = model.canSendChat
        }
        XCTAssertEqual(keyStore.loadCount, 1)

        model.prepareAISettings()
        XCTAssertEqual(keyStore.loadCount, 2)
    }

    func testGenerationCanBeCancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: DelayedChatService(response: "遅い回答", delay: .seconds(1)),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "相談"
        model.sendChat()
        XCTAssertTrue(model.isGenerating)

        model.cancelChatGeneration()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(model.isGenerating)
        XCTAssertFalse(model.chatMessages.contains(where: { $0.text == "遅い回答" }))
        XCTAssertFalse(model.chatMessages.contains(where: { $0.text == "相談" }))
    }

    func testCancellingConsultationKeepsGeneratedStreamText() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: PartialThenWaitChatService(),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "途中で止める相談"
        model.sendChat()
        for _ in 0..<100 where !model.chatMessages.contains(where: { $0.text == "途中までの回答" }) {
            await Task.yield()
        }

        model.cancelChatGeneration()

        XCTAssertFalse(model.isGenerating)
        XCTAssertTrue(model.chatMessages.contains(where: { $0.role == .user && $0.text == "途中で止める相談" }))
        XCTAssertTrue(model.chatMessages.contains(where: { $0.role == .assistant && $0.text == "途中までの回答" }))
    }

    func testConsultationStreamErrorKeepsGeneratedTextAndShowsError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: PartialThenThrowChatService(),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "失敗するストリーム"
        model.sendChat()
        await waitForGeneration(model)

        XCTAssertFalse(model.isGenerating)
        XCTAssertTrue(model.chatMessages.contains(where: { $0.role == .assistant && $0.text == "途中までの回答" }))
        XCTAssertEqual(model.chatMessages.last?.role, .system)
        XCTAssertTrue(model.chatMessages.last?.text.contains("ストリーム失敗") == true)
    }

    func testGenerationStateChangesFromTrueToFalseAfterSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: ["成功した回答"])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "相談"

        model.sendChat()
        XCTAssertTrue(model.isGenerating)
        await waitForGeneration(model)

        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.chatMessages.last?.role, .assistant)
        XCTAssertEqual(model.chatMessages.last?.text, "成功した回答")
    }

    func testThrownGenerationEndsWithSystemError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: ThrowingChatService(),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "失敗する相談"

        model.sendChat()
        XCTAssertTrue(model.isGenerating)
        await waitForGeneration(model)

        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.chatMessages.last?.role, .system)
        XCTAssertTrue(model.chatMessages.last?.text.contains("テスト生成失敗") == true)
    }

    func testEmptyConsultationEndsWithSystemError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: EmptyChatService(),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "空になる相談"

        model.sendChat()
        await waitForGeneration(model)

        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.chatMessages.last?.role, .system)
        XCTAssertTrue(model.chatMessages.last?.text.contains("回答が空") == true)
    }

    func testInvalidEditResponseEndsWithSystemError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: ["Front Matterのない本文"])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatMode = .edit
        model.chatInput = "編集"

        model.sendChat()
        await waitForGeneration(model)

        XCTAssertFalse(model.isGenerating)
        XCTAssertNil(model.chatProposal)
        XCTAssertEqual(model.chatMessages.last?.role, .system)
        XCTAssertTrue(model.chatMessages.last?.text.contains("Front Matter") == true)
    }

    func testCancelledUserMessageIsNotIncludedInNextRequestHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = CancelThenRecordState()
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: CancelThenRecordService(state: state),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "取り消す相談"
        model.sendChat()
        for _ in 0..<100 {
            if await state.requestCount() == 1 { break }
            await Task.yield()
        }

        model.cancelChatGeneration()
        model.chatInput = "次の相談"
        model.sendChat()
        await waitForGeneration(model)

        let requests = await state.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests[1].history.contains(where: { $0.text == "取り消す相談" }))
        XCTAssertEqual(model.chatMessages.last?.text, "次の回答")
    }

    func testGenerationResultIsDiscardedWhenBodyChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: DelayedChatService(response: "回答", delay: .milliseconds(20)),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "相談"
        model.sendChat()
        model.editorText += "手編集"
        try await Task.sleep(for: .milliseconds(40))
        await waitForGeneration(model)

        XCTAssertFalse(model.chatMessages.contains(where: { $0.text == "回答" }))
        XCTAssertTrue(model.chatMessages.contains(where: { $0.text.contains("本文が変更された") }))
    }

    func testSaveRefreshesSelectedPostPreviewImages() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let imageURL = fixture.root.appendingPathComponent("static/images/posts/2026/10-001.png")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: imageURL)
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        XCTAssertTrue(model.selectedPost?.previewImages.isEmpty == true)

        model.editorText += "\n![](/images/posts/2026/10-001.png)\n"
        try model.save()

        XCTAssertEqual(
            model.selectedPost?.previewImages.map(\.publicPath),
            ["/images/posts/2026/10-001.png"]
        )
        XCTAssertEqual(
            model.posts.first(where: { $0.url == model.selectedPost?.url })?.previewImages.map(\.publicPath),
            ["/images/posts/2026/10-001.png"]
        )
    }

    func testFinderImageDeletionAutomaticallyRefreshesReferencedImageState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let imageURL = fixture.root.appendingPathComponent("static/images/posts/2026/10-001.png")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: imageURL)
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.editorText += "\n![](/images/posts/2026/10-001.png)\n"
        try model.save()

        try FileManager.default.removeItem(at: imageURL)
        for _ in 0..<100 where model.statusMessage != "Finderでの画像変更を反映しました" {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.referencedImages.map(\.publicPath), ["/images/posts/2026/10-001.png"])
        XCTAssertFalse(model.referencedImages[0].exists)
        XCTAssertTrue(model.selectedPost?.previewImages.isEmpty == true)
        XCTAssertTrue(model.posts.first(where: { $0.url == model.selectedPost?.url })?.previewImages.isEmpty == true)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.editorText.contains("![](/images/posts/2026/10-001.png)"))
        XCTAssertEqual(model.statusMessage, "Finderでの画像変更を反映しました")
    }

    func testImportImagesRefreshesSelectedPostPreviewImages() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sourceImage = fixture.root.appendingPathComponent("incoming.png")
        try Data([1, 2, 3]).write(to: sourceImage)
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()

        model.importImages([sourceImage])
        for _ in 0..<100 where model.isImportingImages {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isImportingImages)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedPost?.previewImages.count, 1)
        XCTAssertEqual(
            model.posts.first(where: { $0.url == model.selectedPost?.url })?.previewImages.count,
            1
        )
        XCTAssertTrue(model.editorText.contains("![](/images/posts/"))
    }

    func testImportDroppedImageDataAppendsMarkdownAndRefreshesImageList() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.editorText = FrontMatterParser.replacingField(
            "date",
            with: "2025-11-12T12:00:00+09:00",
            in: model.editorText
        )

        model.importImages([.data(Data([1, 2, 3]), fileExtension: "png")])
        for _ in 0..<100 where model.isImportingImages {
            try await Task.sleep(for: .milliseconds(10))
        }

        let markdown = "![](/images/posts/2025/11-001.png)"
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.editorText.contains(markdown))
        XCTAssertEqual(model.referencedImages.map(\.publicPath), ["/images/posts/2025/11-001.png"])
        XCTAssertEqual(model.selectedPost?.previewImages.map(\.publicPath), ["/images/posts/2025/11-001.png"])
        XCTAssertEqual(try String(contentsOf: model.selectedPost!.url, encoding: .utf8), model.editorText)
    }

    func testReferencedImageListPublishesNewImageAfterDroppedDataImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.editorText = FrontMatterParser.replacingField(
            "date",
            with: "2025-11-12T12:00:00+09:00",
            in: model.editorText
        )

        let listUpdated = expectation(description: "referenced image list is published")
        listUpdated.assertForOverFulfill = false
        var observation: AnyCancellable?
        observation = model.objectWillChange
            .sink { _ in
                DispatchQueue.main.async {
                    if model.referencedImages.contains(where: { $0.publicPath == "/images/posts/2025/11-001.png" }) {
                        listUpdated.fulfill()
                    }
                }
            }

        model.importImages([.data(Data([1, 2, 3]), fileExtension: "png")])
        await fulfillment(of: [listUpdated], timeout: 1)
        for _ in 0..<100 where model.isImportingImages {
            try await Task.sleep(for: .milliseconds(10))
        }
        observation?.cancel()

        XCTAssertFalse(model.isImportingImages)
        XCTAssertEqual(model.referencedImages.map(\.publicPath), ["/images/posts/2025/11-001.png"])
    }

    func testPastedImageIsSavedAndMarkdownReplacesEditorSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.editorText = FrontMatterParser.replacingField(
            "date",
            with: "2025-11-12T12:00:00+09:00",
            in: model.editorText
        )
        let selection = (model.editorText as NSString).range(of: "本文A")

        XCTAssertTrue(model.importPastedImages(
            [.data(Data([1, 2, 3]), fileExtension: "png")],
            replacing: selection
        ))
        for _ in 0..<100 where model.isImportingImages {
            try await Task.sleep(for: .milliseconds(10))
        }

        let markdown = "![](/images/posts/2025/11-001.png)"
        XCTAssertFalse(model.editorText.contains("本文A"))
        XCTAssertTrue(model.editorText.contains(markdown))
        XCTAssertEqual(model.savedText, model.editorText)
        XCTAssertEqual(
            model.editorSelectionRequest?.range,
            NSRange(location: selection.location + (markdown as NSString).length, length: 0)
        )
        XCTAssertEqual(try String(contentsOf: model.selectedPost!.url, encoding: .utf8), model.editorText)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("static/images/posts/2025/11-001.png").path
        ))
    }

    func testOpenRouterSettingsUseDedicatedDefaultsAndInMemoryKeyStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let keyStore = InMemoryAPIKeyStore()
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: SettingsChatService(models: nil),
            apiKeyStore: keyStore,
            sourcePath: fixture.root.path
        )
        model.prepareAISettings()
        XCTAssertFalse(model.hasSavedOpenRouterAPIKey)
        XCTAssertEqual(model.openRouterModelID, OpenRouterSettingsStore.defaultModelID)

        try model.saveAISettings(apiKey: "fake-secret-key", modelID: " provider/custom ")

        XCTAssertEqual(try keyStore.load(), "fake-secret-key")
        XCTAssertEqual(model.openRouterModelID, "provider/custom")
        XCTAssertTrue(model.hasSavedOpenRouterAPIKey)
        let persisted = fixture.defaults.persistentDomain(forName: fixture.suiteName) ?? [:]
        XCTAssertFalse(String(describing: persisted).contains("fake-secret-key"))

        model.fetchOpenRouterModels()
        for _ in 0..<100 where model.isFetchingOpenRouterModels { await Task.yield() }
        XCTAssertEqual(model.openRouterModelID, "provider/custom")
        XCTAssertTrue(model.aiSettingsMessage?.contains("接続") == true)

        let restored = AppModel(
            defaults: fixture.defaults,
            chatService: SettingsChatService(models: []),
            apiKeyStore: keyStore,
            sourcePath: fixture.root.path
        )
        restored.prepareAISettings()
        XCTAssertEqual(restored.openRouterModelID, "provider/custom")
        XCTAssertTrue(restored.hasSavedOpenRouterAPIKey)

        try restored.deleteOpenRouterAPIKey()
        try restored.deleteOpenRouterAPIKey()
        XCTAssertNil(try keyStore.load())
        XCTAssertFalse(restored.hasSavedOpenRouterAPIKey)
    }

    func testMarkdownEditorFontSizeUpdatesAndRestoresFromSettings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )

        model.setMarkdownEditorFontSize(19)

        XCTAssertEqual(model.markdownEditorFontSize, 19)
        let restored = AppModel(
            defaults: fixture.defaults,
            chatService: MockChatService(state: MockChatState(responses: [])),
            apiKeyStore: fixture.apiKeyStore,
            sourcePath: fixture.root.path
        )
        XCTAssertEqual(restored.markdownEditorFontSize, 19)
    }

    func testSavingAISettingsCancelsGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let keyStore = InMemoryAPIKeyStore(value: "existing-fake-key")
        let model = AppModel(
            defaults: fixture.defaults,
            chatService: DelayedChatService(response: "遅い回答", delay: .seconds(1)),
            apiKeyStore: keyStore,
            sourcePath: fixture.root.path
        )
        model.load()
        model.chatInput = "取り消される相談"
        model.sendChat()
        XCTAssertTrue(model.isGenerating)

        try model.saveAISettings(apiKey: "fake-secret-key", modelID: "")

        XCTAssertFalse(model.isGenerating)
        XCTAssertFalse(model.chatMessages.contains(where: { $0.text == "取り消される相談" }))
        XCTAssertEqual(model.openRouterModelID, OpenRouterSettingsStore.defaultModelID)
    }

    private func waitForGeneration(_ model: AppModel) async {
        for _ in 0..<100 where model.isGenerating {
            await Task.yield()
        }
    }

    private func waitForPostsLoading(_ model: AppModel) async {
        for _ in 0..<100 where model.isLoadingPosts {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func post(
        title: String,
        date: Date?,
        isDraft: Bool,
        slug: String? = nil
    ) -> BlogPost {
        BlogPost(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).md"),
            title: title,
            date: date,
            isDraft: isDraft,
            category: "tech",
            slug: slug ?? title,
            previewImages: []
        )
    }
}

private actor MockChatState {
    private var responses: [String]
    private var requests: [ChatDraftRequest] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func next(for request: ChatDraftRequest) throws -> ChatDraftResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw AppError.modelUnavailable("テスト応答がありません")
        }
        return ChatDraftResponse(content: responses.removeFirst())
    }

    func recordedRequests() -> [ChatDraftRequest] { requests }
}

private struct MockChatService: ChatDraftServing {
    let state: MockChatState

    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        try await state.next(for: request)
    }
}

private struct UnavailableChatService: ChatDraftServing {
    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        throw AppError.modelUnavailable("利用不可")
    }
}

private struct DelayedChatService: ChatDraftServing {
    let response: String
    let delay: Duration

    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        try await Task.sleep(for: delay)
        return ChatDraftResponse(content: response)
    }
}

private struct PartialThenWaitChatService: ChatDraftServing {
    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        throw AppError.modelUnavailable("このテストではstreamだけを使います")
    }

    func stream(
        _ request: ChatDraftRequest,
        onDelta: @escaping @MainActor @Sendable (ChatDraftStreamDelta) -> Void
    ) async throws -> ChatDraftResponse {
        await onDelta(ChatDraftStreamDelta(content: "途中までの回答"))
        try await Task.sleep(for: .seconds(1))
        return ChatDraftResponse(content: "完了した回答")
    }
}

private struct PartialThenThrowChatService: ChatDraftServing {
    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        throw AppError.modelUnavailable("このテストではstreamだけを使います")
    }

    func stream(
        _ request: ChatDraftRequest,
        onDelta: @escaping @MainActor @Sendable (ChatDraftStreamDelta) -> Void
    ) async throws -> ChatDraftResponse {
        await onDelta(ChatDraftStreamDelta(content: "途中までの回答"))
        throw AppError.modelUnavailable("ストリーム失敗")
    }
}

private struct ThrowingChatService: ChatDraftServing {
    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        throw AppError.modelUnavailable("テスト生成失敗")
    }
}

private struct EmptyChatService: ChatDraftServing {
    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        ChatDraftResponse(content: "")
    }
}

private actor CancelThenRecordState {
    private var requests: [ChatDraftRequest] = []

    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        requests.append(request)
        if requests.count == 1 {
            try await Task.sleep(for: .seconds(1))
            return ChatDraftResponse(content: "取り消される回答")
        }
        return ChatDraftResponse(content: "次の回答")
    }

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [ChatDraftRequest] { requests }
}

private struct CancelThenRecordService: ChatDraftServing {
    let state: CancelThenRecordState

    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        try await state.generate(request)
    }
}

private final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func load() throws -> String? {
        lock.withLock { value }
    }

    func save(_ apiKey: String) throws {
        lock.withLock { value = apiKey }
    }

    func delete() throws {
        lock.withLock { value = nil }
    }
}

private struct FailingAPIKeyStore: APIKeyStoring {
    func load() throws -> String? { throw TestAPIKeyStoreError.failed }
    func save(_ apiKey: String) throws { throw TestAPIKeyStoreError.failed }
    func delete() throws { throw TestAPIKeyStoreError.failed }
}

private enum TestAPIKeyStoreError: Error { case failed }

private final class CountingAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String?
    private var count = 0

    init(value: String?) { self.value = value }

    var loadCount: Int { lock.withLock { count } }
    func load() throws -> String? {
        lock.withLock { count += 1 }
        return value
    }
    func save(_ apiKey: String) throws {}
    func delete() throws {}
}

private struct SettingsChatService: ChatDraftServing {
    let models: [OpenRouterModel]?

    func generate(_ request: ChatDraftRequest) async throws -> ChatDraftResponse {
        ChatDraftResponse(content: "回答")
    }
    func fetchModels() async throws -> [OpenRouterModel] {
        guard let models else { throw OpenRouterError.network }
        return models
    }
}

private struct Fixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let apiKeyStore = InMemoryAPIKeyStore(value: "fake-test-key")
    let markdown = """
    ---
    title: "記事A"
    draft: true
    slug: article-a
    ---

    本文A
    """

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "AppModelTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("content/posts/2026", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("data/author-metadata/personas", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "baseURL = \"https://example.invalid\"".write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try markdown.write(
            to: root.appendingPathComponent("content/posts/2026/a.md"),
            atomically: true,
            encoding: .utf8
        )
        try markdown.replacingOccurrences(of: "記事A", with: "記事B")
            .replacingOccurrences(of: "article-a", with: "article-b")
            .write(
                to: root.appendingPathComponent("content/posts/2026/b.md"),
                atomically: true,
                encoding: .utf8
            )
        try "fixture persona".write(
            to: root.appendingPathComponent("data/author-metadata/personas/v3.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
