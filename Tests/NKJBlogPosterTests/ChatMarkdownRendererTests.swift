import Foundation
import XCTest
@testable import NKJBlogPoster

final class ChatMarkdownRendererTests: XCTestCase {
    func testParsesParagraphHeadingsListsAndQuotesWithoutRawMarkers() {
        let markdown = """
        # 見出し
        ###### 小見出し

        一行目
        二行目

        - 箇条書きA
        + 箇条書きB
        * 箇条書きC
        3. 番号A
        8) 番号B
        > 引用
        > 続き
        >>>> 深い引用
        """

        XCTAssertEqual(ChatMarkdownParser.parse(markdown), [
            .heading(level: 1, text: "見出し"),
            .heading(level: 6, text: "小見出し"),
            .paragraph("一行目\n二行目"),
            .unorderedList([
                .init(marker: "-", text: "箇条書きA"),
                .init(marker: "+", text: "箇条書きB"),
                .init(marker: "*", text: "箇条書きC")
            ]),
            .orderedList([
                .init(marker: "3.", text: "番号A"),
                .init(marker: "8)", text: "番号B")
            ]),
            .quote(depth: 1, text: "引用\n続き"),
            .quote(depth: ChatMarkdownParser.maximumQuoteDepth, text: "深い引用")
        ])
    }

    func testRendersNewsAnswerStructureWithoutRawMarkdownMarkers() {
        let markdown = """
        申し訳ありませんが、最新ニュースをお答えすることはできません。

        理由は2つあります:

        1. **私はウェブを参照できません** — 知識には期限があり、リアルタイムのニュースを取得する手段がないため、聞かれたまま答えると古い情報や不正確な内容を混ぜてしまいます。
        2. **このチャットの役割はブログ執筆の補助** — あなたが提示した事実だけを使って記事づくりを手伝う立場なので、私の側から情報を「事実」として持ち込むのはルール外です。

        ## 代わりにできること

        - **あなたが気になったAIニュースを教えてもらえれば**、それを記事にまとめる構成を一緒に考えられます（例: どのニュースに注目したか、なぜ気になったか、自分の仕事や生活にどう関係しそうか）
        - 記事の切り口の相談（例: 「試してみた」視点で書くか、複数ニュースの雑感にするか）
        - タイトル「Nin」は仮置きに見えますが、書きたいテーマが決まればタイトル案も検討できます

        まず、最近どんなAIニュースが気になっていますか？リンクやメモがあれば、それを元に進められます。
        """

        XCTAssertEqual(ChatMarkdownParser.parse(markdown), [
            .paragraph("申し訳ありませんが、最新ニュースをお答えすることはできません。"),
            .paragraph("理由は2つあります:"),
            .orderedList([
                .init(marker: "1.", text: "**私はウェブを参照できません** — 知識には期限があり、リアルタイムのニュースを取得する手段がないため、聞かれたまま答えると古い情報や不正確な内容を混ぜてしまいます。"),
                .init(marker: "2.", text: "**このチャットの役割はブログ執筆の補助** — あなたが提示した事実だけを使って記事づくりを手伝う立場なので、私の側から情報を「事実」として持ち込むのはルール外です。")
            ]),
            .heading(level: 2, text: "代わりにできること"),
            .unorderedList([
                .init(marker: "-", text: "**あなたが気になったAIニュースを教えてもらえれば**、それを記事にまとめる構成を一緒に考えられます（例: どのニュースに注目したか、なぜ気になったか、自分の仕事や生活にどう関係しそうか）"),
                .init(marker: "-", text: "記事の切り口の相談（例: 「試してみた」視点で書くか、複数ニュースの雑感にするか）"),
                .init(marker: "-", text: "タイトル「Nin」は仮置きに見えますが、書きたいテーマが決まればタイトル案も検討できます")
            ]),
            .paragraph("まず、最近どんなAIニュースが気になっていますか？リンクやメモがあれば、それを元に進められます。")
        ])
    }

    func testCodeFencePreservesCodeAndDropsFenceMarkers() {
        let markdown = """
        ```swift
        let value = "# > - 1. **raw**"
        print(`value`)
        ```
        """

        XCTAssertEqual(ChatMarkdownParser.parse(markdown), [
            .code(
                language: "swift",
                content: "let value = \"# > - 1. **raw**\"\nprint(`value`)"
            )
        ])
    }

    func testUnclosedCodeFenceIsSafeAtEndOfFile() {
        XCTAssertEqual(
            ChatMarkdownParser.parse("```\nline 1\n# still code"),
            [.code(language: "", content: "line 1\n# still code")]
        )
    }

    func testCRLFAndBlankLinesCreateParagraphBoundaries() {
        XCTAssertEqual(
            ChatMarkdownParser.parse("最初\r\n続き\r\n\r\n最後"),
            [.paragraph("最初\n続き"), .paragraph("最後")]
        )
    }

    func testInlineMarkdownPreservesOnlyHTTPAndHTTPSLinks() {
        let attributed = ChatInlineMarkdown.attributedString(
            "[HTTPS](https://example.com) [HTTP](http://example.com) [file](file:///tmp/a) [custom](app://x) [relative](page)"
        )
        let links = attributed.runs.compactMap(\.link)

        XCTAssertEqual(String(attributed.characters), "HTTPS HTTP file custom relative")
        XCTAssertEqual(links.map { $0.scheme?.lowercased() }, ["https", "http"])
    }

    func testInlineMarkdownStylesAndMalformedInputFallsBackSafely() {
        let styled = ChatInlineMarkdown.attributedString("**太字** *斜体* `code`")
        XCTAssertEqual(String(styled.characters), "太字 斜体 code")
        XCTAssertTrue(hasIntent(.stronglyEmphasized, for: "太字", in: styled))
        XCTAssertTrue(hasIntent(.emphasized, for: "斜体", in: styled))
        XCTAssertTrue(hasIntent(.code, for: "code", in: styled))

        let malformed = ChatInlineMarkdown.attributedString("[未完了 **text")
        XCTAssertFalse(String(malformed.characters).isEmpty)
    }

    func testEmptyAndNonBlockMarkersArePlainParagraphs() {
        XCTAssertEqual(ChatMarkdownParser.parse(""), [])
        XCTAssertEqual(
            ChatMarkdownParser.parse("#見出しではない\n-空白なし\n1)空白なし"),
            [.paragraph("#見出しではない\n-空白なし\n1)空白なし")]
        )
    }

    private func hasIntent(
        _ intent: InlinePresentationIntent,
        for expectedText: String,
        in attributed: AttributedString
    ) -> Bool {
        attributed.runs.contains { run in
            String(attributed[run.range].characters) == expectedText
                && run.inlinePresentationIntent?.contains(intent) == true
        }
    }
}
