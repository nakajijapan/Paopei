import AppKit
import XCTest
@testable import NKJBlogPoster

@MainActor
final class MarkdownSyntaxHighlighterTests: XCTestCase {
    func testColorsCommonMarkdownSyntax() {
        let text = """
        ---
        title: 配色テスト
        ---
        # 見出し
        > 引用
        - 項目
        [OpenAI](https://example.com)
        `let value = 1`
        """
        let textView = NSTextView()
        textView.string = text

        MarkdownSyntaxHighlighter.apply(to: textView)

        XCTAssertEqual(color(for: "title", in: textView), .systemPurple)
        XCTAssertEqual(color(for: "#", in: textView), .systemOrange)
        XCTAssertEqual(color(for: "見出し", in: textView), .systemBlue)
        XCTAssertEqual(color(for: ">", in: textView), .systemTeal)
        XCTAssertEqual(color(for: "引用", in: textView), .secondaryLabelColor)
        XCTAssertEqual(color(for: "- 項目", in: textView), .systemOrange)
        XCTAssertEqual(color(for: "[OpenAI]", in: textView), .systemBlue)
        XCTAssertEqual(color(for: "https://example.com", in: textView), .systemTeal)
        XCTAssertEqual(color(for: "`let value = 1`", in: textView), .systemPurple)
    }

    func testColorsSingleAndMultiLineHTMLCommentsGray() {
        let text = """
        本文 <!-- 補足 --> 続き
        <!--
        複数行の補足
        -->
        本文
        """
        let textView = NSTextView()
        textView.string = text

        MarkdownSyntaxHighlighter.apply(to: textView)

        XCTAssertEqual(color(for: "<!-- 補足 -->", in: textView), .systemGray)
        XCTAssertEqual(color(for: "複数行の補足", in: textView), .systemGray)
        XCTAssertEqual(color(for: "本文", in: textView), .labelColor)
    }

    func testLeavesHTMLCommentTextInCodeFencePurple() {
        let text = """
        ```html
        <!-- template comment -->
        ```
        """
        let textView = NSTextView()
        textView.string = text

        MarkdownSyntaxHighlighter.apply(to: textView)

        XCTAssertEqual(color(for: "<!-- template comment -->", in: textView), .systemPurple)
    }

    func testHorizontalRuleInBodyDoesNotStartFrontMatter() {
        let text = "本文\n---\nkey: 本文のまま"
        let textView = NSTextView()
        textView.string = text

        MarkdownSyntaxHighlighter.apply(to: textView)

        XCTAssertEqual(color(for: "key", in: textView), .labelColor)
    }

    func testAppliesConfiguredMonospacedFontSizeToTextAndTypingAttributes() throws {
        let textView = NSTextView()
        textView.string = "本文"

        MarkdownSyntaxHighlighter.apply(to: textView, fontSize: 19)

        let textFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        let typingFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(textFont.pointSize, 19)
        XCTAssertEqual(typingFont.pointSize, 19)
    }

    private func color(for needle: String, in textView: NSTextView) -> NSColor? {
        let range = (textView.string as NSString).range(of: needle)
        return textView.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
}
