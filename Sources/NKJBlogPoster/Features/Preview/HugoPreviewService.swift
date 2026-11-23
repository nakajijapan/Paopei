import Combine
import Darwin
import Foundation

private final class HugoListProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false

    func register(_ process: Process) -> Bool {
        lock.withLock {
            guard !cancelRequested else { return false }
            self.process = process
            return true
        }
    }

    func clear() {
        lock.withLock { process = nil }
    }

    var isCancellationRequested: Bool {
        lock.withLock { cancelRequested }
    }

    func cancel() {
        let runningProcess = lock.withLock { () -> Process? in
            cancelRequested = true
            return process
        }
        guard let runningProcess else { return }
        Self.stop(runningProcess)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

enum HugoPreviewState: Equatable {
    case idle
    case preparing
    case ready(URL)
    case failed(HugoPreviewFailure)
}

struct HugoPreviewFailure: Equatable {
    let message: String
    let canRepairDate: Bool
}

struct HugoContentDateIssue: Equatable, Sendable {
    let fileURL: URL
    let relativePath: String
    let dateIssue: FrontMatterDateIssue

    var message: String {
        "\(relativePath): \(dateIssue.lineNumber)行目の `date: \(dateIssue.value)`\n修正: \(dateIssue.message)"
    }
}

struct HugoContentDateValidationError: LocalizedError {
    let issues: [HugoContentDateIssue]

    var errorDescription: String? {
        let details = issues.map(\.message).joined(separator: "\n\n")
        return "プレビューに含まれる記事の日付が不正です。Hugoは実行していません。\n\n\(details)"
    }
}

struct HugoPreviewRequest: Sendable, Equatable {
    let sourceRepository: URL
    let postURL: URL
    let markdown: String
    let isSaved: Bool
}

struct HugoPreviewWorkspace: Sendable {
    let root: URL
    let content: URL
    let cache: URL

    static func create(sourceRepository: URL, request: HugoPreviewRequest) throws -> Self {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("NKJBlogPosterPreview-\(UUID().uuidString)", isDirectory: true)
        let content = root.appendingPathComponent("content", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(
                at: sourceRepository.appendingPathComponent("content", isDirectory: true),
                to: content
            )
            try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
            let workspace = Self(root: root, content: content, cache: cache)
            try workspace.write(request)
            return workspace
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    /// Every content file is copied into the preview workspace. Validate those source files
    /// before invoking Hugo so an unrelated article cannot produce an opaque `hugo list all`
    /// failure for the article currently being edited.
    static func dateIssues(inSourceRepository sourceRepository: URL) throws -> [HugoContentDateIssue] {
        let content = sourceRepository
            .appendingPathComponent("content", isDirectory: true)
            .standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: content,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var issues: [HugoContentDateIssue] = []
        for case let url as URL in enumerator {
            guard ["md", "markdown", "html"].contains(url.pathExtension.lowercased()) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let markdown = try BlogRepository.readText(at: url)
            guard let dateIssue = FrontMatterParser.dateIssue(in: markdown) else { continue }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(content.path.count + 1))
            issues.append(HugoContentDateIssue(
                fileURL: url,
                relativePath: "content/\(relativePath)",
                dateIssue: dateIssue
            ))
        }
        return issues.sorted { $0.relativePath < $1.relativePath }
    }

    static func repairDate(_ issue: HugoContentDateIssue) throws {
        let markdown = try BlogRepository.readText(at: issue.fileURL)
        guard let repaired = FrontMatterParser.repairingUnpaddedDate(in: markdown) else {
            throw AppError.invalidPost([
                "\(issue.relativePath) の date は安全に自動修正できません。\(issue.dateIssue.message)"
            ])
        }
        try repaired.write(to: issue.fileURL, atomically: true, encoding: .utf8)
    }

    func write(_ request: HugoPreviewRequest, restoring previousRelativePath: String? = nil) throws {
        let fileManager = FileManager.default
        let relativePath = try HugoPreviewPaths.relativeContentPath(
            postURL: request.postURL,
            sourceRepository: request.sourceRepository
        )

        if let previousRelativePath, previousRelativePath != relativePath {
            let source = request.sourceRepository
                .appendingPathComponent("content", isDirectory: true)
                .appendingPathComponent(previousRelativePath)
            let destination = content.appendingPathComponent(previousRelativePath)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            } else {
                try? fileManager.removeItem(at: destination)
            }
        }

        let destination = content.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try request.markdown.write(to: destination, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum HugoPreviewPaths {
    static func relativeContentPath(postURL: URL, sourceRepository: URL) throws -> String {
        let contentRoot = sourceRepository
            .appendingPathComponent("content", isDirectory: true)
            .standardizedFileURL.path
        let postPath = postURL.standardizedFileURL.path
        let prefix = contentRoot.hasSuffix("/") ? contentRoot : contentRoot + "/"
        guard postPath.hasPrefix(prefix) else {
            throw AppError.invalidRepository("選択した記事はHugoリポジトリのcontent内にありません。")
        }
        return String(postPath.dropFirst(prefix.count))
    }

    static func permalink(
        fromHugoList output: String,
        workspaceContent: URL,
        relativePath: String,
        expectedOrigin: URL
    ) throws -> URL {
        let expectedPath = workspaceContent.appendingPathComponent(relativePath).standardizedFileURL.path
        guard let row = output.split(whereSeparator: \.isNewline).first(where: { line in
            line.hasPrefix(expectedPath + ",")
        }) else {
            throw AppError.invalidRepository("Hugoが選択中の記事のURLを生成できませんでした。Front Matterを確認してください。")
        }
        let columns = row.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 4,
              let url = URL(string: String(columns[columns.count - 3])),
              url.scheme == expectedOrigin.scheme,
              url.host == expectedOrigin.host,
              url.port == expectedOrigin.port else {
            throw AppError.invalidRepository("Hugoが生成したプレビューURLを安全に確認できませんでした。")
        }
        return url
    }
}

@MainActor
final class HugoPreviewController: ObservableObject {
    @Published private(set) var state: HugoPreviewState = .idle
    @Published private(set) var revision = 0
    @Published private(set) var isShowingUnsavedContent = false

    private var process: Process?
    private var outputPipe: Pipe?
    private var output = ""
    private var workspace: HugoPreviewWorkspace?
    private var sourceRepository: URL?
    private var serverOrigin: URL?
    private var currentRelativePath: String?
    private var pendingRequest: HugoPreviewRequest?
    private var updateTask: Task<Void, Never>?
    private var generation = 0
    private var repairableDateIssue: HugoContentDateIssue?

    func update(_ request: HugoPreviewRequest, immediately: Bool = false) {
        pendingRequest = request
        generation += 1
        let requestGeneration = generation
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            if !immediately {
                try? await Task.sleep(for: .milliseconds(650))
            }
            guard !Task.isCancelled, requestGeneration == self.generation else { return }
            await self.render(request, generation: requestGeneration)
        }
    }

    func retry() {
        guard let pendingRequest else { return }
        update(pendingRequest, immediately: true)
    }

    /// This is invoked only from the explicit error-screen action. It changes exactly one
    /// unpadded month/day value in the original Hugo source; the preview workspace is never
    /// silently repaired independently of the user's file.
    func repairDateAndRetry() {
        guard let issue = repairableDateIssue else { return }
        do {
            try HugoPreviewWorkspace.repairDate(issue)
            repairableDateIssue = nil
            retry()
        } catch {
            state = .failed(HugoPreviewFailure(
                message: error.localizedDescription,
                canRepairDate: false
            ))
        }
    }

    func reload() {
        guard case .ready = state else {
            retry()
            return
        }
        revision += 1
    }

    func stop() {
        generation += 1
        updateTask?.cancel()
        updateTask = nil
        stopProcess()
        workspace?.remove()
        workspace = nil
        sourceRepository = nil
        serverOrigin = nil
        currentRelativePath = nil
        repairableDateIssue = nil
        state = .idle
    }

    private func render(_ request: HugoPreviewRequest, generation requestGeneration: Int) async {
        do {
            if let dateError = FrontMatterParser.dateValidationError(in: request.markdown) {
                throw AppError.invalidPost([dateError])
            }
            let normalizedSource = request.sourceRepository.standardizedFileURL
            let relativePath = try HugoPreviewPaths.relativeContentPath(
                postURL: request.postURL,
                sourceRepository: normalizedSource
            )

            // Keep the local server and the WKWebView alive while the user edits.
            // Hugo watches the workspace content directory, so replacing the article is
            // enough; restarting the server would briefly replace the web view with the
            // loading UI and lose its in-page position.
            if sourceRepository == normalizedSource,
               let workspace,
               let origin = serverOrigin,
               process?.isRunning == true,
               case .ready = state {
                let previousRelativePath = currentRelativePath
                try await Task.detached(priority: .userInitiated) {
                    try workspace.write(request, restoring: previousRelativePath)
                }.value
                guard requestGeneration == generation, !Task.isCancelled else { return }

                currentRelativePath = relativePath
                let permalink: URL
                if previousRelativePath == relativePath, case .ready(let currentURL) = state {
                    permalink = currentURL
                } else {
                    permalink = try await Self.resolvePermalink(
                        sourceRepository: normalizedSource,
                        workspace: workspace,
                        relativePath: relativePath,
                        origin: origin
                    )
                }
                // Give Hugo's file watcher one short turn to rebuild before the web view
                // requests the updated page. The web view itself remains visible.
                try await Task.sleep(for: .milliseconds(120))
                try await waitForSuccessfulResponse(at: permalink, generation: requestGeneration)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                state = .ready(permalink)
                isShowingUnsavedContent = !request.isSaved
                revision += 1
                return
            }

            let needsWorkspace = sourceRepository != normalizedSource || workspace == nil
            if needsWorkspace {
                state = .preparing
                stopProcess()
                workspace?.remove()
                workspace = nil
                currentRelativePath = nil

                let dateIssues = try await Task.detached(priority: .userInitiated) {
                    try HugoPreviewWorkspace.dateIssues(inSourceRepository: normalizedSource)
                }.value
                guard dateIssues.isEmpty else {
                    throw HugoContentDateValidationError(issues: dateIssues)
                }

                let created = try await Task.detached(priority: .userInitiated) {
                    try HugoPreviewWorkspace.create(sourceRepository: normalizedSource, request: request)
                }.value
                guard requestGeneration == generation, !Task.isCancelled else {
                    created.remove()
                    return
                }
                workspace = created
                sourceRepository = normalizedSource
            } else if let workspace {
                state = .preparing
                stopProcess()
                output = ""
                let previousRelativePath = currentRelativePath
                try await Task.detached(priority: .userInitiated) {
                    try workspace.write(request, restoring: previousRelativePath)
                }.value
            }

            guard requestGeneration == generation, !Task.isCancelled, let workspace else { return }
            currentRelativePath = relativePath

            let port = try Self.availableLoopbackPort()
            let origin = URL(string: "http://127.0.0.1:\(port)/")!
            let permalink = try await Self.resolvePermalink(
                sourceRepository: normalizedSource,
                workspace: workspace,
                relativePath: relativePath,
                origin: origin
            )
            try startServer(sourceRepository: normalizedSource, workspace: workspace, port: port)
            serverOrigin = origin
            try await waitUntilReady(origin: origin, generation: requestGeneration)
            try await waitForSuccessfulResponse(at: permalink, generation: requestGeneration)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            state = .ready(permalink)

            isShowingUnsavedContent = !request.isSaved
            revision += 1
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            stopProcess()
            if let dateError = error as? HugoContentDateValidationError {
                repairableDateIssue = dateError.issues.first(where: { $0.dateIssue.normalizedValue != nil })
                state = .failed(HugoPreviewFailure(
                    message: dateError.localizedDescription,
                    canRepairDate: repairableDateIssue != nil
                ))
            } else {
                repairableDateIssue = nil
                state = .failed(HugoPreviewFailure(message: error.localizedDescription, canRepairDate: false))
            }
        }
    }

    private func startServer(sourceRepository: URL, workspace: HugoPreviewWorkspace, port: UInt16) throws {
        let hugo = try Self.hugoExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hugo)
        process.currentDirectoryURL = sourceRepository
        process.arguments = [
            "server",
            "--source", sourceRepository.path,
            "--contentDir", workspace.content.path,
            "--cacheDir", workspace.cache.path,
            "--renderToMemory",
            "--buildDrafts",
            "--buildFuture",
            "--bind", "127.0.0.1",
            "--port", String(port),
            "--baseURL", "http://127.0.0.1:\(port)/",
            "--appendPort=false",
            "--disableLiveReload",
            "--noHTTPCache",
            "--noBuildLock"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HUGO_CONTENTDIR"] = workspace.content.path
        process.environment = environment

        let pipe = Pipe()
        output = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.output = String((self.output + chunk).suffix(16_000))
            }
        }
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor [weak self] in
                guard let self, self.process === finishedProcess else { return }
                if finishedProcess.terminationStatus != 0, case .ready = self.state {
                    self.state = .failed(HugoPreviewFailure(
                        message: self.serverFailureMessage(),
                        canRepairDate: false
                    ))
                }
            }
        }
        try process.run()
        self.process = process
        outputPipe = pipe
    }

    private func waitUntilReady(origin: URL, generation requestGeneration: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.4
        configuration.timeoutIntervalForResource = 0.4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for _ in 0..<80 {
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            guard process?.isRunning == true else {
                throw AppError.commandFailed(command: "hugo server", output: serverFailureMessage())
            }
            do {
                var request = URLRequest(url: origin)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (_, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                    return
                }
                if let response = response as? HTTPURLResponse, response.statusCode >= 500 {
                    throw AppError.commandFailed(command: "hugo server", output: serverFailureMessage())
                }
            } catch {
                if error is AppError { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw AppError.commandFailed(command: "hugo server", output: serverFailureMessage())
    }

    private func waitForSuccessfulResponse(at url: URL, generation requestGeneration: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for _ in 0..<30 {
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            guard process?.isRunning == true else {
                throw AppError.commandFailed(command: "hugo server", output: serverFailureMessage())
            }
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (_, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                    if output.range(of: "ERROR", options: .caseInsensitive) == nil {
                        return
                    }
                    throw AppError.commandFailed(command: "hugo server", output: serverFailureMessage())
                }
                if let response = response as? HTTPURLResponse, response.statusCode >= 500 {
                    throw AppError.commandFailed(command: "hugo server", output: serverFailureMessage())
                }
            } catch {
                if error is AppError { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw AppError.commandFailed(command: "hugo server", output: serverFailureMessage())
    }

    private func stopProcess() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.4)
            while process.isRunning, Date() < deadline {
                usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
    }

    private func serverFailureMessage() -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Hugo Previewサーバーを起動できませんでした。" : trimmed
    }

    private static func resolvePermalink(
        sourceRepository: URL,
        workspace: HugoPreviewWorkspace,
        relativePath: String,
        origin: URL
    ) async throws -> URL {
        let processBox = HugoListProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
            let hugo = try hugoExecutable()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hugo)
            process.currentDirectoryURL = sourceRepository
            process.arguments = [
                "list", "all",
                "--source", sourceRepository.path,
                "--noBuildLock"
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HUGO_CONTENTDIR"] = workspace.content.path
            environment["HUGO_BASEURL"] = origin.absoluteString
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard processBox.register(process), !processBox.isCancellationRequested else {
                throw CancellationError()
            }
            defer { processBox.clear() }
            try process.run()
            if processBox.isCancellationRequested {
                processBox.cancel()
                throw CancellationError()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw AppError.commandFailed(command: "hugo list all", output: output)
            }
            return try HugoPreviewPaths.permalink(
                fromHugoList: output,
                workspaceContent: workspace.content,
                relativePath: relativePath,
                expectedOrigin: origin
            )
            }.value
        } onCancel: {
            processBox.cancel()
        }
    }

    nonisolated private static func hugoExecutable() throws -> String {
        let candidates = ["/opt/homebrew/bin/hugo", "/usr/local/bin/hugo", "/usr/bin/hugo"]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return path
        }
        throw AppError.invalidRepository("Hugoが見つかりません。Homebrew等でインストールしてください。")
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppError.invalidRepository("プレビュー用ポートを確保できませんでした。")
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw AppError.invalidRepository("プレビュー用ポートを確保できませんでした。")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw AppError.invalidRepository("プレビュー用ポートを確認できませんでした。")
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
