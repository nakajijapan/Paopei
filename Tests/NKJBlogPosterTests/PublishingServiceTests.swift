import Foundation
import XCTest
@testable import NKJBlogPoster

final class PublishingServiceTests: XCTestCase {
    func testCustomMainBranchAttachesDetachedHeadWithoutChangingGeneratedFiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source")
        let output = source.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: output)
        try git(["config", "user.name", "NKJBlogPoster Tests"], at: output)
        try git(["config", "user.email", "tests@example.com"], at: output)
        let page = output.appendingPathComponent("index.html")
        try "original".write(to: page, atomically: true, encoding: .utf8)
        try git(["add", "index.html"], at: output)
        try git(["commit", "-m", "Initial"], at: output)
        try git(["switch", "--detach"], at: output)
        try "interrupted output".write(to: page, atomically: true, encoding: .utf8)

        try PublishingService.prepareOutputRepository(output, from: source, branch: "main")

        XCTAssertEqual(try gitOutput(["branch", "--show-current"], at: output), "main")
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "interrupted output")
        XCTAssertEqual(try gitOutput(["status", "--porcelain"], at: output), "M index.html")
    }

    func testPrepareOutputRepositoryRepairsDeletedSubmoduleGitFile() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source")
        let output = source.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try git(["init", "-b", "master"], at: source)
        try git(["init", "-b", "master"], at: output)
        try git(["config", "user.name", "NKJBlogPoster Tests"], at: output)
        try git(["config", "user.email", "tests@example.com"], at: output)
        try "generated".write(
            to: output.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "index.html"], at: output)
        try git(["commit", "-m", "Initial"], at: output)

        let moduleGitDirectory = source.appendingPathComponent(".git/modules/public")
        try FileManager.default.createDirectory(
            at: moduleGitDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: output.appendingPathComponent(".git"),
            to: moduleGitDirectory
        )

        try PublishingService.prepareOutputRepository(output, from: source)

        XCTAssertEqual(
            try String(contentsOf: output.appendingPathComponent(".git"), encoding: .utf8),
            "gitdir: ../.git/modules/public\n"
        )
        let actualTopLevel = URL(
            fileURLWithPath: try gitOutput(["rev-parse", "--show-toplevel"], at: output)
        ).resolvingSymlinksInPath()
        XCTAssertEqual(actualTopLevel, output.resolvingSymlinksInPath())
    }

    func testPrepareOutputRepositorySwitchesDetachedHeadToMaster() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source")
        let output = source.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try git(["init", "-b", "master"], at: output)
        try git(["config", "user.name", "NKJBlogPoster Tests"], at: output)
        try git(["config", "user.email", "tests@example.com"], at: output)
        try "generated".write(
            to: output.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "index.html"], at: output)
        try git(["commit", "-m", "Initial"], at: output)
        try git(["switch", "--detach"], at: output)

        try PublishingService.prepareOutputRepository(output, from: source)

        XCTAssertEqual(try gitOutput(["branch", "--show-current"], at: output), "master")
    }

    func testPrepareOutputRepositoryPreservesInterruptedGeneratedChanges() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source")
        let output = source.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try git(["init", "-b", "master"], at: output)
        try git(["config", "user.name", "NKJBlogPoster Tests"], at: output)
        try git(["config", "user.email", "tests@example.com"], at: output)
        let generatedFile = output.appendingPathComponent("index.html")
        try "before".write(to: generatedFile, atomically: true, encoding: .utf8)
        try git(["add", "index.html"], at: output)
        try git(["commit", "-m", "Initial"], at: output)
        try git(["switch", "--detach"], at: output)
        try "after Hugo build".write(to: generatedFile, atomically: true, encoding: .utf8)

        try PublishingService.prepareOutputRepository(output, from: source)

        XCTAssertEqual(try gitOutput(["branch", "--show-current"], at: output), "master")
        XCTAssertEqual(try String(contentsOf: generatedFile, encoding: .utf8), "after Hugo build")
        XCTAssertEqual(try gitOutput(["status", "--porcelain"], at: output), "M index.html")
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        _ = try gitOutput(arguments, at: directory)
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(output)")
            throw AppError.commandFailed(command: "git", output: output)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
