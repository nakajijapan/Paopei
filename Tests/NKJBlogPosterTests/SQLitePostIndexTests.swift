import Foundation
import XCTest
@testable import NKJBlogPoster

final class SQLitePostIndexTests: XCTestCase {
    func testSynchronizeIndexesAddedChangedAndDeletedPostsOutsideRepository() throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let index = SQLitePostIndex(root: fixture.root, cacheDirectory: fixture.cacheDirectory)

        XCTAssertEqual(try index.synchronize().map(\.title), ["記事B", "記事A"])
        XCTAssertFalse(index.cacheURL.path.hasPrefix(fixture.root.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.cacheURL.path))

        try fixture.writePost(named: "a.md", title: "更新された記事A", body: "本文を長くして更新を確実に検出する")
        try fixture.writePost(named: "c.md", title: "記事C", body: "追加本文")
        try FileManager.default.removeItem(at: fixture.postsDirectory.appendingPathComponent("b.md"))

        let posts = try index.synchronize()
        XCTAssertEqual(posts.map(\.title), ["記事C", "更新された記事A"])
        XCTAssertEqual(posts.map(\.slug), ["article-c", "article-a"])
    }

    func testUpdateMakesSavedMarkdownAvailableWithoutAFullRebuild() throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let index = SQLitePostIndex(root: fixture.root, cacheDirectory: fixture.cacheDirectory)
        let postURL = fixture.postsDirectory.appendingPathComponent("a.md")
        let markdown = fixture.markdown(title: "保存した記事A", slug: "article-a", body: "保存後本文")

        try markdown.write(to: postURL, atomically: true, encoding: .utf8)
        try index.update(url: postURL, markdown: markdown)

        XCTAssertEqual(try index.synchronize().first(where: { $0.slug == "article-a" })?.title, "保存した記事A")
    }

    func testSynchronizeRebuildsOnlyCorruptCache() throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let index = SQLitePostIndex(root: fixture.root, cacheDirectory: fixture.cacheDirectory)
        _ = try index.synchronize()

        let fileManager = FileManager.default
        for suffix in ["-shm", "-wal"] {
            let sidecar = URL(fileURLWithPath: index.cacheURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
        try Data("not a sqlite database".utf8).write(to: index.cacheURL, options: .atomic)

        XCTAssertEqual(try index.synchronize().map(\.title), ["記事B", "記事A"])
    }
}

private struct IndexFixture {
    let root: URL
    let cacheDirectory: URL

    var postsDirectory: URL {
        root.appendingPathComponent("content/posts/2026", isDirectory: true)
    }

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLitePostIndexTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("repository", isDirectory: true)
        cacheDirectory = base.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: postsDirectory, withIntermediateDirectories: true)
        try "baseURL = \"https://example.invalid\"".write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try writePost(named: "a.md", title: "記事A", body: "本文A")
        try writePost(named: "b.md", title: "記事B", body: "本文B")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func writePost(named name: String, title: String, body: String) throws {
        let slug = switch name {
        case "a.md": "article-a"
        case "b.md": "article-b"
        default: "article-c"
        }
        try markdown(title: title, slug: slug, body: body).write(
            to: postsDirectory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    func markdown(title: String, slug: String, body: String) -> String {
        """
        ---
        title: "\(title)"
        date: 2026-10-12T12:00:00+09:00
        draft: false
        categories: tech
        slug: \(slug)
        ---

        \(body)
        """
    }
}
