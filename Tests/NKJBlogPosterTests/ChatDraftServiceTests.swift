import XCTest
@testable import NKJBlogPoster

final class ChatDraftServiceTests: XCTestCase {
    private let base = """
    ---
    title: "元の記事"
    date: 2026-10-12T12:30:00+09:00
    draft: true
    slug: original
    ---

    本文
    """

    func testAcceptsValidMarkdownProposal() throws {
        let candidate = base.replacingOccurrences(of: "本文", with: "更新した本文")
        XCTAssertNoThrow(try ChatDraftService.validateProposal(candidate, baseMarkdown: base))
    }

    func testRejectsEmptyOrMissingFrontMatterFields() {
        XCTAssertThrowsError(try ChatDraftService.validateProposal("", baseMarkdown: base))
        XCTAssertThrowsError(try ChatDraftService.validateProposal("本文だけ", baseMarkdown: base))
        XCTAssertThrowsError(try ChatDraftService.validateProposal("""
        ---
        title: "タイトル"
        draft: true
        ---

        本文
        """, baseMarkdown: base))
    }

    func testRejectsDraftValueChange() {
        let candidate = base.replacingOccurrences(of: "draft: true", with: "draft: false")
        XCTAssertThrowsError(try ChatDraftService.validateProposal(candidate, baseMarkdown: base))
    }

    func testRejectsDateValueChangeOrRemoval() {
        let changedDate = base.replacingOccurrences(
            of: "date: 2026-10-12T12:30:00+09:00",
            with: "date: 2026-8-14T18:24:21+09:00"
        )
        let removedDate = base.replacingOccurrences(
            of: "date: 2026-10-12T12:30:00+09:00\n",
            with: ""
        )

        XCTAssertThrowsError(try ChatDraftService.validateProposal(changedDate, baseMarkdown: base))
        XCTAssertThrowsError(try ChatDraftService.validateProposal(removedDate, baseMarkdown: base))
    }

    func testRejectsQuotedWhitespaceTitleAndSlug() {
        let whitespaceTitle = base.replacingOccurrences(of: "title: \"元の記事\"", with: "title: \"   \"")
        let whitespaceSlug = base.replacingOccurrences(of: "slug: original", with: "slug: '   '")

        XCTAssertThrowsError(try ChatDraftService.validateProposal(whitespaceTitle, baseMarkdown: base))
        XCTAssertThrowsError(try ChatDraftService.validateProposal(whitespaceSlug, baseMarkdown: base))
    }

    func testRemovesMarkdownCodeFence() {
        XCTAssertEqual(
            ChatDraftService.cleanedMarkdown("```markdown\n# 本文\n```"),
            "# 本文\n"
        )
    }
}
