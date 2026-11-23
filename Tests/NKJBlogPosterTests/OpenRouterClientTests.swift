import Foundation
import XCTest
@testable import NKJBlogPoster

final class OpenRouterClientTests: XCTestCase {
    private let apiKey = "fake-openrouter-key"
    private var settingsSuiteName = ""
    private var settingsDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        settingsSuiteName = "OpenRouterClientTests.\(UUID().uuidString)"
        settingsDefaults = UserDefaults(suiteName: settingsSuiteName)!
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
        settingsDefaults = nil
        super.tearDown()
    }

    func testPOSTUsesExpectedURLHeadersDefaultModelAndMessageOrder() async throws {
        let service = makeService()
        let history = (0..<14).flatMap { index in
            [
                ChatMessage(role: .system, text: "system-\(index)"),
                ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "message-\(index)")
            ]
        }
        URLProtocolStub.handler = { [apiKey] request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.test/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(Self.requestBody(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, OpenRouterSettingsStore.defaultModelID)
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages.count, 14)
            XCTAssertEqual(messages.first?["role"], "system")
            XCTAssertTrue(messages.first?["content"]?.contains("人格") == true)
            XCTAssertFalse(messages.dropFirst().dropLast().contains(where: { $0["role"] == "system" }))
            XCTAssertEqual(messages.dropFirst().first?["content"], "message-2")
            XCTAssertEqual(messages.last?["role"], "user")
            XCTAssertTrue(messages.last?["content"]?.contains("依頼文") == true)
            XCTAssertTrue(messages.last?["content"]?.contains("記事本文") == true)
            return Self.response(request: request, json: """
            {"choices":[{"message":{"content":"回答です"},"finish_reason":"stop"}]}
            """)
        }

        let response = try await service.generate(ChatDraftRequest(
            markdown: "記事本文",
            message: "依頼文",
            persona: "人格",
            mode: .consultation,
            history: history
        ))

        XCTAssertEqual(response.content, "回答です")
    }

    func testCustomEditingInstructionsOnlyAffectEditModeAndKeepCommonRules() async throws {
        let custom = "固有の見出しは変えず、段落を短くしてください。"
        for mode in [ChatMode.consultation, .edit] {
            let service = makeService()
            URLProtocolStub.handler = { request in
                let data = try XCTUnwrap(Self.requestBody(request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
                let system = try XCTUnwrap(messages.first?["content"])
                XCTAssertEqual(system.contains(custom), mode == .edit)
                XCTAssertTrue(system.contains("推測で作ってはいけません"))
                if mode == .edit {
                    XCTAssertTrue(system.contains("draftの値を変更してはいけません"))
                    XCTAssertTrue(system.contains("表記を含めて変更してはいけません"))
                    XCTAssertTrue(system.contains("Markdown全文だけ"))
                }
                return Self.response(request: request, json: """
                {"choices":[{"message":{"content":"応答"},"finish_reason":"stop"}]}
                """)
            }
            _ = try await service.generate(ChatDraftRequest(
                markdown: "記事本文", message: "依頼", persona: "人格", mode: mode, history: [], editingInstructions: custom
            ))
        }
    }

    func testUsesSavedCustomModel() async throws {
        let context = try TestSettingsContext()
        defer { context.cleanup() }
        context.store.saveModelID("provider/custom-model")
        let service = makeService(settingsStore: context.store)
        URLProtocolStub.handler = { request in
            let data = try XCTUnwrap(Self.requestBody(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "provider/custom-model")
            return Self.response(request: request, json: """
            {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
            """)
        }
        _ = try await service.generate(sampleRequest())
    }

    func testWebSearchUsesExplicitOpenRouterToolAndDecodesCitations() async throws {
        let service = makeService()
        URLProtocolStub.handler = { request in
            let data = try XCTUnwrap(Self.requestBody(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["max_tool_calls"] as? Int, 2)
            let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 1)
            XCTAssertEqual(tools.first?["type"] as? String, "openrouter:web_search")
            let parameters = try XCTUnwrap(tools.first?["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["engine"] as? String, "auto")
            XCTAssertEqual(parameters["max_uses"] as? Int, 2)
            XCTAssertEqual(parameters["max_total_results"] as? Int, 10)
            return Self.response(request: request, json: """
            {"choices":[{"message":{"content":"検索結果です","annotations":[
              {"type":"url_citation","url_citation":{"url":"https://example.com/source","title":"Source title"}},
              {"type":"url_citation","url_citation":{"url":"https://example.com/source","title":"Duplicate"}}
            ]},"finish_reason":"stop"}]}
            """)
        }

        var request = sampleRequest()
        request = ChatDraftRequest(
            markdown: request.markdown,
            message: request.message,
            persona: request.persona,
            mode: .consultation,
            history: request.history,
            webSearchEnabled: true
        )
        let response = try await service.generate(request)

        XCTAssertEqual(response.content, "検索結果です")
        XCTAssertEqual(response.citations, [
            WebCitation(url: URL(string: "https://example.com/source")!, title: "Source title")
        ])
    }

    @MainActor
    func testConsultationStreamsSSEContentAndCitations() async throws {
        let service = makeService()
        URLProtocolStub.handler = { request in
            let data = try XCTUnwrap(Self.requestBody(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            return Self.response(
                request: request,
                contentType: "text/event-stream",
                json: """
                data: {"choices":[{"delta":{"content":"最初の"}}]}

                data: {"choices":[{"delta":{"content":"回答","annotations":[{"url_citation":{"url":"https://example.com/source","title":"Source title"}}]}}]}

                data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

                data: [DONE]

                """
            )
        }

        var deltas: [ChatDraftStreamDelta] = []
        let response = try await service.stream(sampleRequest()) { delta in
            deltas.append(delta)
        }

        XCTAssertEqual(response.content, "最初の回答")
        XCTAssertEqual(response.citations, [
            WebCitation(url: URL(string: "https://example.com/source")!, title: "Source title")
        ])
        XCTAssertEqual(deltas.map(\.content), ["最初の", "回答"])
        XCTAssertEqual(deltas.last?.citations, response.citations)
    }

    func testConsultationStreamRejectsMissingCompletionTerminal() async {
        let service = makeService()
        URLProtocolStub.handler = { request in
            Self.response(
                request: request,
                contentType: "text/event-stream",
                json: """
                data: {"choices":[{"delta":{"content":"途中"}}]}

                """
            )
        }

        do {
            _ = try await service.stream(sampleRequest()) { _ in }
            XCTFail("Expected incomplete response")
        } catch let OpenRouterError.incompleteResponse(reason) {
            XCTAssertNil(reason)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConsultationStreamRejectsNonStopFinishReason() async {
        let service = makeService()
        URLProtocolStub.handler = { request in
            Self.response(
                request: request,
                contentType: "text/event-stream",
                json: """
                data: {"choices":[{"delta":{"content":"途中"}}]}

                data: {"choices":[{"delta":{},"finish_reason":"length"}]}

                data: [DONE]

                """
            )
        }

        do {
            _ = try await service.stream(sampleRequest()) { _ in }
            XCTFail("Expected incomplete response")
        } catch let OpenRouterError.incompleteResponse(reason) {
            XCTAssertEqual(reason, "length")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTPErrorKeepsStatusAndSanitizedMessage() async {
        let service = makeService()
        URLProtocolStub.handler = { [apiKey] request in
            Self.response(
                request: request,
                status: 401,
                json: "{\"error\":{\"message\":\"invalid \(apiKey)\"}}"
            )
        }

        do {
            _ = try await service.generate(sampleRequest())
            XCTFail("Expected an HTTP error")
        } catch let OpenRouterError.httpStatus(status, message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "invalid [APIキー]")
            XCTAssertFalse((message ?? "").contains(apiKey))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDecodeAndEmptyResponseErrors() async {
        let service = makeService()
        URLProtocolStub.handler = { request in Self.response(request: request, json: "{}") }
        await XCTAssertThrowsOpenRouterError(.decode) { try await service.generate(self.sampleRequest()) }

        URLProtocolStub.handler = { request in
            Self.response(request: request, json: "{\"choices\":[]}")
        }
        await XCTAssertThrowsOpenRouterError(.emptyResponse) { try await service.generate(self.sampleRequest()) }
    }

    func testNetworkTimeoutAndCancellationErrors() async {
        let service = makeService()
        URLProtocolStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        await XCTAssertThrowsOpenRouterError(.network) { try await service.generate(self.sampleRequest()) }

        URLProtocolStub.handler = { _ in throw URLError(.timedOut) }
        await XCTAssertThrowsOpenRouterError(.timeout) { try await service.generate(self.sampleRequest()) }

        URLProtocolStub.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await service.generate(sampleRequest())
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultSessionAllowsSlowProviderResponses() {
        let session = ChatDraftService.makeSession()

        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 180)
    }

    func testFetchModelsUsesGETAndDecodesModels() async throws {
        let service = makeService()
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.test/api/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.apiKey)")
            return Self.response(request: request, json: """
            {"data":[
              {"id":"z/model","name":"Zulu"},
              {"id":"a/model","name":"Alpha"}
            ]}
            """)
        }

        let models = try await service.fetchModels()

        XCTAssertEqual(models.map(\.id), ["a/model", "z/model"])
    }

    func testProductionSessionDisablesCacheAndCookies() {
        let configuration = ChatDraftService.makeSession().configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRelevantHTTPStatusesArePreserved() async {
        let service = makeService()
        for status in [401, 402, 429, 500, 503] {
            URLProtocolStub.handler = { request in
                Self.response(request: request, status: status, json: "{\"error\":{}}")
            }
            do {
                _ = try await service.generate(sampleRequest())
                XCTFail("Expected HTTP \(status)")
            } catch let OpenRouterError.httpStatus(actual, _) {
                XCTAssertEqual(actual, status)
            } catch {
                XCTFail("Unexpected error for HTTP \(status): \(error)")
            }
        }
    }

    func testMissingKeyAndKeychainFailureAreDistinct() async {
        let missing = makeService(keyStore: FixedAPIKeyStore(value: nil))
        await XCTAssertThrowsOpenRouterError(.missingAPIKey) { try await missing.generate(self.sampleRequest()) }

        let failing = makeService(keyStore: FixedAPIKeyStore(shouldFail: true))
        await XCTAssertThrowsOpenRouterError(.keychain) { try await failing.generate(self.sampleRequest()) }

        await XCTAssertThrowsOpenRouterError(.missingAPIKey) { try await missing.fetchModels() }
        await XCTAssertThrowsOpenRouterError(.keychain) { try await failing.fetchModels() }
    }

    func testNonStopFinishReasonIsRejectedForConsultationAndEdit() async {
        let service = makeService()
        URLProtocolStub.handler = { request in
            Self.response(request: request, json: """
            {"choices":[{"message":{"content":"途中の内容"},"finish_reason":"length"}]}
            """)
        }

        for mode in [ChatMode.consultation, .edit] {
            var request = sampleRequest()
            request = ChatDraftRequest(
                markdown: request.markdown,
                message: request.message,
                persona: request.persona,
                mode: mode,
                history: request.history
            )
            do {
                _ = try await service.generate(request)
                XCTFail("Expected incomplete response for \(mode)")
            } catch let OpenRouterError.incompleteResponse(reason) {
                XCTAssertEqual(reason, "length")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeService(
        keyStore: any APIKeyStoring = FixedAPIKeyStore(value: "fake-openrouter-key"),
        settingsStore: OpenRouterSettingsStore? = nil
    ) -> ChatDraftService {
        let context = settingsStore ?? OpenRouterSettingsStore(defaults: settingsDefaults)
        return ChatDraftService(
            apiKeyStore: keyStore,
            settingsStore: context,
            session: URLSession(configuration: Self.sessionConfiguration()),
            baseURL: URL(string: "https://openrouter.test/api/v1")!
        )
    }

    private func sampleRequest() -> ChatDraftRequest {
        ChatDraftRequest(
            markdown: "---\ntitle: T\ndraft: true\nslug: t\n---\n本文",
            message: "依頼",
            persona: "人格",
            mode: .consultation,
            history: []
        )
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }

    private static func response(
        request: URLRequest,
        status: Int = 200,
        contentType: String = "application/json",
        json: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )!,
            Data(json.utf8)
        )
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FixedAPIKeyStore: APIKeyStoring {
    var value: String?
    var shouldFail: Bool

    init(value: String? = nil, shouldFail: Bool = false) {
        self.value = value
        self.shouldFail = shouldFail
    }

    func load() throws -> String? {
        if shouldFail { throw TestKeyStoreError.failed }
        return value
    }
    func save(_ apiKey: String) throws {}
    func delete() throws {}
}

private enum TestKeyStoreError: Error { case failed }

private struct TestSettingsContext {
    let suiteName: String
    let defaults: UserDefaults
    let store: OpenRouterSettingsStore

    init() throws {
        suiteName = "OpenRouterClientTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = OpenRouterSettingsStore(defaults: defaults)
    }

    func cleanup() { defaults.removePersistentDomain(forName: suiteName) }
}

private func XCTAssertThrowsOpenRouterError<T>(
    _ expected: OpenRouterError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected OpenRouterError", file: file, line: line)
    } catch let actual as OpenRouterError {
        switch (expected, actual) {
        case (.missingAPIKey, .missingAPIKey), (.keychain, .keychain), (.encode, .encode),
             (.network, .network), (.timeout, .timeout), (.decode, .decode),
             (.emptyResponse, .emptyResponse):
            break
        default:
            XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
