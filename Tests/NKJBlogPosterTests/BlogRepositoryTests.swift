import Foundation
import XCTest
@testable import NKJBlogPoster

final class BlogRepositoryTests: XCTestCase {
    func testCreatesMarkdownDraftInYearDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("content/posts"),
            withIntermediateDirectories: true
        )
        try "baseURL = \"https://example.com\"".write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let date = ISO8601DateFormatter().date(from: "2026-08-14T09:24:21Z")!
        let repository = BlogRepository(root: root)

        let post = try repository.createDraft(title: "Mac Blog App", category: "tech", now: date)
        let markdown = try repository.read(post)

        XCTAssertEqual(post.url.pathExtension, "md")
        XCTAssertTrue(post.url.path.contains("/content/posts/2026/"))
        XCTAssertTrue(markdown.contains("title: \"Mac Blog App\""))
        XCTAssertTrue(markdown.contains("date: 2026-08-14T18:24:21+09:00"))
        XCTAssertTrue(markdown.contains("draft: true"))
        XCTAssertTrue(markdown.contains("slug: mac-blog-app"))
        XCTAssertTrue(post.previewImages.isEmpty)
    }

    func testLoadPostsBuildsPreviewImagesFromExistingLocalReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let postsDirectory = root.appendingPathComponent("content/posts/2026")
        let imagesDirectory = root.appendingPathComponent("static/images/posts/2026")
        try FileManager.default.createDirectory(at: postsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try "baseURL = \"https://example.com\"".write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try Data([1]).write(to: imagesDirectory.appendingPathComponent("10-001.png"))
        let markdown = """
        ---
        title: "画像つき記事"
        date: 2026-10-12T12:00:00+09:00
        draft: false
        categories: tech
        slug: image-post
        ---

        ![](/images/posts/2026/10-001.png)
        ![](/images/posts/2026/missing.png)
        """
        try markdown.write(
            to: postsDirectory.appendingPathComponent("image-post.md"),
            atomically: true,
            encoding: .utf8
        )

        let post = try XCTUnwrap(BlogRepository(root: root).loadPosts().first)

        XCTAssertEqual(post.previewImages.map(\.publicPath), ["/images/posts/2026/10-001.png"])
    }

    func testMoveToTrashMovesOnlyPostMarkdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let postsDirectory = root.appendingPathComponent("content/posts/2026")
        let imageURL = root.appendingPathComponent("static/images/posts/2026/10-001.png")
        try FileManager.default.createDirectory(at: postsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "baseURL = \"https://example.com\"".write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let postURL = postsDirectory.appendingPathComponent("delete-me.md")
        try "---\ntitle: delete me\n---".write(to: postURL, atomically: true, encoding: .utf8)
        try Data([1]).write(to: imageURL)
        let post = BlogPost(
            url: postURL,
            title: "delete me",
            date: nil,
            isDraft: true,
            category: "",
            slug: "delete-me",
            previewImages: []
        )

        let trashedURL = try BlogRepository(root: root).moveToTrash(post)
        defer {
            if let trashedURL {
                try? FileManager.default.removeItem(at: trashedURL)
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: postURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(trashedURL).path))
    }
}
