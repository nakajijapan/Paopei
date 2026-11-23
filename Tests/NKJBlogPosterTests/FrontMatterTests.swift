import XCTest
@testable import NKJBlogPoster

final class FrontMatterTests: XCTestCase {
    func testParsesExistingHugoFrontMatter() {
        let markdown = """
        ---
        title: "テスト記事"
        date: 2026-10-12T12:30:00+09:00
        draft: true
        categories: tech
        slug: test-post
        ---

        # 本文
        """

        let result = FrontMatterParser.parse(markdown)

        XCTAssertEqual(result.title, "テスト記事")
        XCTAssertEqual(result.slug, "test-post")
        XCTAssertEqual(result.category, "tech")
        XCTAssertTrue(result.isDraft)
        XCTAssertNotNil(result.date)
        XCTAssertEqual(result.body, "\n# 本文")
    }

    func testReplacesDraftWithoutChangingOtherFields() {
        let markdown = """
        ---
        title: "タイトル"
        draft: true
        slug: sample
        ---

        本文
        """

        let replaced = FrontMatterParser.replacingField("draft", with: "false", in: markdown)

        XCTAssertTrue(replaced.contains("title: \"タイトル\""))
        XCTAssertTrue(replaced.contains("draft: false"))
        XCTAssertTrue(replaced.contains("本文"))
        XCTAssertFalse(FrontMatterParser.parse(replaced).isDraft)
    }

    func testFindsMarkdownAndHTMLImages() {
        let markdown = """
        ---
        image: images/posts/2026/10-003.gif
        ---
        ![写真](/images/posts/2026/10-001.jpg)
        <img src="/images/posts/2026/10-002.png" />
        """

        XCTAssertEqual(
            FrontMatterParser.imagePaths(in: markdown),
            [
                "/images/posts/2026/10-001.jpg",
                "/images/posts/2026/10-002.png",
                "/images/posts/2026/10-003.gif"
            ]
        )
    }

    func testRejectsUnpaddedDateBeforeHugoRuns() {
        let markdown = """
        ---
        title: "テスト記事"
        date: 2026-8-14T18:24:21+09:00
        draft: true
        slug: test-post
        ---

        """

        XCTAssertEqual(
            FrontMatterParser.dateValidationError(in: markdown),
            "date は Hugo が受け取れるISO 8601形式にしてください（例: 2026-08-14T18:24:21+09:00）。現在: 2026-8-14T18:24:21+09:00"
        )
    }

    func testRejectsNonexistentCalendarDateBeforeHugoRuns() {
        let markdown = "---\ndate: 2026-02-30T18:24:21+09:00\n---\n"

        XCTAssertNotNil(FrontMatterParser.dateValidationError(in: markdown))
    }

    func testRejectsMalformedTimeAndTimeZoneBeforeHugoRuns() {
        let invalidTime = "---\ndate: 2026-08-14T18:24:21+99:99\n---\n"
        let invalidSuffix = "---\ndate: 2026-08-14broken\n---\n"

        XCTAssertNotNil(FrontMatterParser.dateValidationError(in: invalidTime))
        XCTAssertNotNil(FrontMatterParser.dateValidationError(in: invalidSuffix))
    }

    func testAcceptsZeroPaddedDateAndDateOnly() {
        let timestamp = "---\ndate: 2026-08-14T18:24:21+09:00\n---\n"
        let dateOnly = "---\ndate: 2026-08-14\n---\n"

        XCTAssertNil(FrontMatterParser.dateValidationError(in: timestamp))
        XCTAssertNil(FrontMatterParser.dateValidationError(in: dateOnly))
    }

    func testIdentifiesLineAndSafelyNormalizesUnpaddedTimestamp() {
        let markdown = """
        ---
        title: "テスト記事"
        date: 2026-8-4T18:24:21+09:00
        draft: true
        ---
        """

        let issue = FrontMatterParser.dateIssue(in: markdown)

        XCTAssertEqual(issue?.lineNumber, 3)
        XCTAssertEqual(issue?.value, "2026-8-4T18:24:21+09:00")
        XCTAssertEqual(issue?.normalizedValue, "2026-08-04T18:24:21+09:00")
        XCTAssertEqual(
            FrontMatterParser.repairingUnpaddedDate(in: markdown),
            """
            ---
            title: "テスト記事"
            date: 2026-08-04T18:24:21+09:00
            draft: true
            ---
            """
        )
    }

    func testDoesNotGuessInvalidCalendarDateDuringRepair() {
        let markdown = "---\ndate: 2026-2-30T18:24:21+09:00\n---\n"

        XCTAssertNil(FrontMatterParser.repairingUnpaddedDate(in: markdown))
    }
}
