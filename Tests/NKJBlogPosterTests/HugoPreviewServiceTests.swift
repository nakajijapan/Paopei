import Foundation
import XCTest
@testable import NKJBlogPoster

final class HugoPreviewServiceTests: XCTestCase {
    func testRelativeContentPathRejectsPostOutsideRepositoryContent() throws {
        let root = URL(fileURLWithPath: "/tmp/blog", isDirectory: true)

        XCTAssertEqual(
            try HugoPreviewPaths.relativeContentPath(
                postURL: root.appendingPathComponent("content/posts/2026/article.md"),
                sourceRepository: root
            ),
            "posts/2026/article.md"
        )
        XCTAssertThrowsError(try HugoPreviewPaths.relativeContentPath(
            postURL: root.appendingPathComponent("../outside.md"),
            sourceRepository: root
        ))
    }

    func testPermalinkUsesHugoOutputAndRequiresExpectedLoopbackOrigin() throws {
        let content = URL(fileURLWithPath: "/tmp/preview/content", isDirectory: true)
        let output = """
        path,slug,title,date,expiryDate,publishDate,draft,permalink,kind,section
        /tmp/preview/content/posts/2018/nin.md,life,"Nin, note",2026-10-11T00:00:00Z,,,true,http://127.0.0.1:54321/posts/2018/life/,page,posts
        """
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:54321/"))

        XCTAssertEqual(
            try HugoPreviewPaths.permalink(
                fromHugoList: output,
                workspaceContent: content,
                relativePath: "posts/2018/nin.md",
                expectedOrigin: origin
            ).absoluteString,
            "http://127.0.0.1:54321/posts/2018/life/"
        )
    }

    func testWorkspaceWritesUnsavedMarkdownWithoutChangingSourcePost() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("HugoPreviewServiceTests-\(UUID().uuidString)", isDirectory: true)
        let post = source.appendingPathComponent("content/posts/2026/article.md")
        try FileManager.default.createDirectory(at: post.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "saved".write(to: post, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let request = HugoPreviewRequest(
            sourceRepository: source,
            postURL: post,
            markdown: "unsaved",
            isSaved: false
        )
        let workspace = try HugoPreviewWorkspace.create(sourceRepository: source, request: request)
        defer { workspace.remove() }

        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "saved")
        XCTAssertEqual(
            try String(contentsOf: workspace.content.appendingPathComponent("posts/2026/article.md"), encoding: .utf8),
            "unsaved"
        )
    }

    func testDateIssuesValidateEveryContentFileAndNameOriginalPath() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("HugoPreviewServiceDateIssuesTests-\(UUID().uuidString)", isDirectory: true)
        let valid = source.appendingPathComponent("content/posts/2026/valid.md")
        let invalid = source.appendingPathComponent("content/pages/about.md")
        try FileManager.default.createDirectory(at: valid.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalid.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\ndate: 2026-10-13T02:31:49+09:00\n---\n".write(to: valid, atomically: true, encoding: .utf8)
        try "---\ntitle: about\ndate: 2026-8-4T18:24:21+09:00\n---\n".write(to: invalid, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let issues = try HugoPreviewWorkspace.dateIssues(inSourceRepository: source)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.relativePath, "content/pages/about.md")
        XCTAssertEqual(issues.first?.dateIssue.lineNumber, 3)
        XCTAssertEqual(issues.first?.dateIssue.normalizedValue, "2026-08-04T18:24:21+09:00")
    }

    func testRepairDateChangesOnlySafeUnpaddedValueInOriginalSource() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("HugoPreviewServiceDateRepairTests-\(UUID().uuidString)", isDirectory: true)
        let post = source.appendingPathComponent("content/posts/2026/article.md")
        let original = "---\ntitle: unchanged\ndate: 2026-8-4T18:24:21+09:00\n---\nbody\n"
        try FileManager.default.createDirectory(at: post.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: post, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let issue = try XCTUnwrap(HugoPreviewWorkspace.dateIssues(inSourceRepository: source).first)
        try HugoPreviewWorkspace.repairDate(issue)

        XCTAssertEqual(
            try String(contentsOf: post, encoding: .utf8),
            "---\ntitle: unchanged\ndate: 2026-08-04T18:24:21+09:00\n---\nbody\n"
        )
        XCTAssertTrue(try HugoPreviewWorkspace.dateIssues(inSourceRepository: source).isEmpty)
    }
}
