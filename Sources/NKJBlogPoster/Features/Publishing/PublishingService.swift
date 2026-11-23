import Foundation

enum PublishingService {
    private struct CommandResult {
        let status: Int32
        let output: String
    }

    static func publish(_ configuration: PublishConfiguration) throws -> PublishReport {
        let markdown = try String(contentsOf: configuration.postURL, encoding: .utf8)
        try preflight(configuration, markdown: markdown, requirePublished: true)

        let source = configuration.sourceRepository.standardizedFileURL
        let output = configuration.outputRepository.standardizedFileURL
        let hugo = try executable(named: "hugo")
        var log: [String] = []
        // Match deploy.sh: build directly into the existing public directory.
        // Hugo preserves legacy generated pages that no longer have source files.
        log.append(try run(hugo, ["--source", source.path, "--destination", output.path], at: source).output)

        _ = try run("/usr/bin/git", ["add", "-A"], at: output)
        let outputChanged = try hasStagedChanges(at: output)
        if outputChanged {
            log.append(try run("/usr/bin/git", ["commit", "-m", configuration.commitMessage], at: output).output)
        }

        let postRelativePath = relativePath(of: configuration.postURL, under: source)
        var sourcePaths = [postRelativePath]
        sourcePaths.append(contentsOf: FrontMatterParser.imagePaths(in: markdown).map {
            "static/" + ($0.hasPrefix("/") ? String($0.dropFirst()) : $0)
        })
        if output.standardizedFileURL == source.appendingPathComponent("public").standardizedFileURL {
            sourcePaths.append("public")
        }

        _ = try run("/usr/bin/git", ["add", "--"] + sourcePaths, at: source)
        let sourceChanged = try hasStagedChanges(at: source)
        guard sourceChanged || outputChanged else {
            return PublishReport(
                summary: "Hugoビルドは成功しました。公開差分はありません。",
                log: "Hugoビルドは成功しました。公開差分はありません。"
            )
        }
        if sourceChanged {
            log.append(try run("/usr/bin/git", ["commit", "-m", configuration.commitMessage], at: source).output)
        }
        log.append(try run("/usr/bin/git", ["push", "origin", "HEAD"], at: output).output)
        if sourceChanged {
            log.append(try run("/usr/bin/git", ["push", "origin", "HEAD"], at: source).output)
        }
        return PublishReport(
            summary: "投稿が完了しました。",
            log: log.filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    static func preflight(
        _ configuration: PublishConfiguration,
        markdown: String,
        requirePublished: Bool = false
    ) throws {
        let source = configuration.sourceRepository.standardizedFileURL
        let output = configuration.outputRepository.standardizedFileURL
        guard source != output else {
            throw AppError.invalidRepository("Hugoソースと公開生成物に同じフォルダは指定できません。")
        }

        try BlogRepository(root: source).validate()
        let profile = try PublishingProfile.load(from: source)
        try validateGitRepository(source, expectedName: profile.sourceRepository)
        _ = try executable(named: "hugo")
        try prepareOutputRepository(output, from: source, branch: profile.outputBranch)
        try validateGitRepository(output, expectedName: profile.outputRepository)

        // public is a generated-only repository. A previous publish can be interrupted
        // after Hugo generation but before commit, so its working tree must be resumable.
        _ = try run("/usr/bin/git", ["pull", "--ff-only", "origin", profile.outputBranch], at: output)

        let sourceStaged = try run("/usr/bin/git", ["diff", "--cached", "--name-only"], at: source)
        guard sourceStaged.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidRepository("Hugoソースに既にステージ済みの変更があります。意図しないcommitを避けるため投稿を中止しました。")
        }

        let validationErrors = FrontMatterParser.validationErrors(markdown: markdown, repository: source)
        guard validationErrors.isEmpty else { throw AppError.invalidPost(validationErrors) }
        if requirePublished && FrontMatterParser.parse(markdown).isDraft {
            throw AppError.invalidPost(["draft: true の記事は投稿できません。公開確認後に draft: false にしてください。"])
        }
    }

    static func prepareOutputRepository(_ output: URL, from source: URL, branch expectedBranch: String = "master") throws {
        guard ["main", "master"].contains(expectedBranch) else {
            throw AppError.invalidRepository("公開ブランチは main または master を指定してください。")
        }
        let expectedOutput = source.appendingPathComponent("public", isDirectory: true).standardizedFileURL
        guard output.standardizedFileURL == expectedOutput else {
            throw AppError.invalidRepository("公開先はHugoソース内のpublicサブモジュールである必要があります。")
        }
        if !FileManager.default.fileExists(atPath: output.appendingPathComponent(".git").path) {
            if try !repairOutputGitLinkIfPossible(output, from: source) {
                _ = try run("/usr/bin/git", ["submodule", "update", "--init", "--", "public"], at: source)
                guard try repairOutputGitLinkIfPossible(output, from: source) else {
                    throw AppError.invalidRepository("publicサブモジュールのGit管理情報が見つかりません。")
                }
            }
        }

        let topLevel = try run("/usr/bin/git", ["rev-parse", "--show-toplevel"], at: output)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: topLevel).standardizedFileURL == output.standardizedFileURL else {
            throw AppError.invalidRepository("publicサブモジュールのGit管理情報を確認できません。")
        }

        let branchResult = try runAllowingFailure("/usr/bin/git", ["branch", "--show-current"], at: output)
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if branchResult.status != 0 || branch.isEmpty {
            let head = try runAllowingFailure("/usr/bin/git", ["rev-parse", "HEAD"], at: output)
            let master = try runAllowingFailure("/usr/bin/git", ["rev-parse", "refs/heads/\(expectedBranch)"], at: output)
            let headRevision = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let masterRevision = master.output.trimmingCharacters(in: .whitespacesAndNewlines)

            if head.status == 0,
               master.status == 0,
               !headRevision.isEmpty,
               headRevision == masterRevision {
                // Attaching HEAD directly does not touch generated working-tree files.
                _ = try run("/usr/bin/git", ["symbolic-ref", "HEAD", "refs/heads/\(expectedBranch)"], at: output)
            } else {
                let switchResult = try runAllowingFailure("/usr/bin/git", ["switch", expectedBranch], at: output)
                if switchResult.status != 0 {
                    _ = try run("/usr/bin/git", ["fetch", "origin", expectedBranch], at: output)
                    _ = try run(
                        "/usr/bin/git",
                        ["switch", "-C", expectedBranch, "--track", "origin/\(expectedBranch)"],
                        at: output
                    )
                }
            }
        } else if branch != expectedBranch {
            throw AppError.invalidRepository("公開生成物リポジトリは\(expectedBranch)ブランチである必要があります。現在: \(branch)")
        }
    }

    private static func repairOutputGitLinkIfPossible(_ output: URL, from source: URL) throws -> Bool {
        let gitFile = output.appendingPathComponent(".git")
        guard !FileManager.default.fileExists(atPath: gitFile.path) else { return true }

        let modulePathResult = try run(
            "/usr/bin/git",
            ["rev-parse", "--path-format=absolute", "--git-path", "modules/public"],
            at: source
        )
        let modulePath = modulePathResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modulePath.isEmpty,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: modulePath).appendingPathComponent("HEAD").path) else {
            return false
        }

        let relativeGitDirectory = "../.git/modules/public"
        try "gitdir: \(relativeGitDirectory)\n".write(to: gitFile, atomically: true, encoding: .utf8)
        return true
    }

    private static func validateGitRepository(_ url: URL, expectedName: String) throws {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            throw AppError.invalidRepository("Gitリポジトリではありません: \(url.path)")
        }
        let remote = try run("/usr/bin/git", ["remote", "get-url", "origin"], at: url).output
        guard PublishingProfile.matches(remote: remote, repository: expectedName) else {
            throw AppError.invalidRepository("origin が想定リポジトリではありません。\n想定: \(expectedName)\n実際: \(remote)")
        }
    }

    private static func relativePath(of child: URL, under parent: URL) -> String {
        let childPath = child.standardizedFileURL.path
        let prefix = parent.standardizedFileURL.path + "/"
        return childPath.hasPrefix(prefix) ? String(childPath.dropFirst(prefix.count)) : child.lastPathComponent
    }

    private static func hasStagedChanges(at url: URL) throws -> Bool {
        let result = try runAllowingFailure("/usr/bin/git", ["diff", "--cached", "--quiet"], at: url)
        if result.status == 0 { return false }
        if result.status == 1 { return true }
        throw AppError.commandFailed(command: "git diff --cached --quiet", output: result.output)
    }

    private static func executable(named name: String) throws -> String {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        let result = try runAllowingFailure("/usr/bin/which", [name], at: nil)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !path.isEmpty else {
            throw AppError.invalidRepository("\(name) が見つかりません。Homebrew等でインストールしてください。")
        }
        return path
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], at directory: URL?) throws -> CommandResult {
        let result = try runAllowingFailure(executable, arguments, at: directory)
        guard result.status == 0 else {
            throw AppError.commandFailed(
                command: ([executable] + arguments).joined(separator: " "),
                output: result.output
            )
        }
        return result
    }

    private static func runAllowingFailure(_ executable: String, _ arguments: [String], at directory: URL?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
