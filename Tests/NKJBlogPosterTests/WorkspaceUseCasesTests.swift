import Foundation
import XCTest
@testable import NKJBlogPoster

@MainActor
final class WorkspaceUseCasesTests: XCTestCase {
    func testPostEditorFeatureFiltersBeforeGrouping() throws {
        let feature = PostEditorFeature()
        let calendar = Calendar(identifier: .gregorian)
        let dated = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 3)))
        feature.posts = [
            makePost(title: "公開 Swift", date: dated, isDraft: false),
            makePost(title: "下書き Swift", date: nil, isDraft: true),
            makePost(title: "公開 Rust", date: nil, isDraft: false)
        ]
        feature.filter = .published
        feature.searchQuery = "Swift"

        XCTAssertEqual(feature.postYearSections.map(\.year), [2026])
        XCTAssertEqual(feature.postYearSections.flatMap(\.posts).map(\.title), ["公開 Swift"])
    }

    func testSavePostUseCasePersistsOnlySelectedPost() throws {
        let fixture = try UseCaseFixture()
        defer { fixture.cleanup() }

        let useCase = SavePostUseCase(repository: BlogRepository(root: fixture.root))
        try useCase.execute(markdown: "updated", post: fixture.post)

        XCTAssertEqual(try String(contentsOf: fixture.post.url, encoding: .utf8), "updated")
        XCTAssertThrowsError(try useCase.execute(markdown: "ignored", post: nil)) { error in
            XCTAssertEqual(error.localizedDescription, AppError.noSelection.localizedDescription)
        }
    }

    func testApplyChatProposalRejectsChangedEditorWithoutWriting() throws {
        let fixture = try UseCaseFixture()
        defer { fixture.cleanup() }
        let original = try String(contentsOf: fixture.post.url, encoding: .utf8)
        let proposal = ChatProposal(
            postURL: fixture.post.url,
            baseMarkdown: original,
            markdown: original.replacingOccurrences(of: "本文", with: "更新本文")
        )

        let useCase = ApplyChatProposalUseCase(repository: BlogRepository(root: fixture.root))
        XCTAssertThrowsError(try useCase.execute(
            proposal: proposal,
            selectedPost: fixture.post,
            currentMarkdown: original + "手編集"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("本文が編集された"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.post.url, encoding: .utf8), original)
    }

    func testApplyChatProposalPersistsOnlyExplicitlyAcceptedMatchingProposal() throws {
        let fixture = try UseCaseFixture()
        defer { fixture.cleanup() }
        let original = try String(contentsOf: fixture.post.url, encoding: .utf8)
        let proposed = original.replacingOccurrences(of: "本文", with: "更新本文")
        let proposal = ChatProposal(postURL: fixture.post.url, baseMarkdown: original, markdown: proposed)

        let result = try ApplyChatProposalUseCase(repository: BlogRepository(root: fixture.root)).execute(
            proposal: proposal,
            selectedPost: fixture.post,
            currentMarkdown: original
        )

        XCTAssertEqual(result, proposed)
        XCTAssertEqual(try String(contentsOf: fixture.post.url, encoding: .utf8), proposed)
    }

    func testImageInsertionUseCaseRejectsOutOfRangeSelectionWithoutChangingMarkdown() throws {
        let markdown = "本文"
        XCTAssertThrowsError(try ImageInsertionUseCase.replacing(
            markdown: markdown,
            range: NSRange(location: 3, length: 0),
            replacement: "![](/images/posts/2026/01-001.jpg)"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("挿入位置"))
        }
        XCTAssertEqual(markdown, "本文")
    }

    func testImageInsertionUseCaseAppendsWithStableMarkdownSpacing() {
        XCTAssertEqual(
            ImageInsertionUseCase.appending("![](/images/a.jpg)", to: "本文"),
            "本文\n\n![](/images/a.jpg)\n"
        )
    }

    func testPublishPostUseCaseBuildsFixedPublicSubmoduleConfiguration() {
        let source = URL(fileURLWithPath: "/tmp/source", isDirectory: true)
        let post = makePost(url: source.appendingPathComponent("content/posts/2026/post.md"), title: "記事")
        let configuration = PublishPostUseCase(sourceRepository: source).configuration(for: post, markdown: "---\ntitle: \"公開名\"\n---\n")

        XCTAssertEqual(configuration.sourceRepository, source)
        XCTAssertEqual(configuration.outputRepository, source.appendingPathComponent("public", isDirectory: true))
        XCTAssertEqual(configuration.postURL, post.url)
        XCTAssertEqual(configuration.commitMessage, "Publish: 公開名")
    }

    private func makePost(
        url: URL = URL(fileURLWithPath: "/tmp/post.md"),
        title: String,
        date: Date? = nil,
        isDraft: Bool = false
    ) -> BlogPost {
        BlogPost(url: url, title: title, date: date, isDraft: isDraft, category: "", slug: title, previewImages: [])
    }
}

private struct UseCaseFixture {
    let root: URL
    let post: BlogPost

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let posts = root.appendingPathComponent("content/posts/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        try "baseURL = \"https://example.invalid/\"\n".write(
            to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        let url = posts.appendingPathComponent("post.md")
        let markdown = "---\ntitle: \"記事\"\ndate: 2026-10-14T12:00:00+09:00\ndraft: true\nslug: post\n---\n\n本文\n"
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        post = BlogPost(url: url, title: "記事", date: nil, isDraft: true, category: "", slug: "post", previewImages: [])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
