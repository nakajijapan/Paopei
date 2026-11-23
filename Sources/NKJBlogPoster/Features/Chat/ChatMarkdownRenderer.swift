import Foundation
import SwiftUI

struct ChatMarkdownListItem: Equatable {
    let marker: String
    let text: String
}

indirect enum ChatMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([ChatMarkdownListItem])
    case orderedList([ChatMarkdownListItem])
    case quote(depth: Int, text: String)
    case code(language: String?, content: String)
}

enum ChatMarkdownParser {
    static let maximumQuoteDepth = 3

    static func parse(_ markdown: String) -> [ChatMarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [] }

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let language = openingFenceLanguage(line) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !isClosingFence(lines[index]) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language, content: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(in: line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let parsedQuote = quote(in: line) {
                var texts = [parsedQuote.text]
                index += 1
                while index < lines.count,
                      let next = quote(in: lines[index]),
                      next.depth == parsedQuote.depth {
                    texts.append(next.text)
                    index += 1
                }
                blocks.append(.quote(depth: parsedQuote.depth, text: texts.joined(separator: "\n")))
                continue
            }

            if let item = unorderedItem(in: line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = unorderedItem(in: lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(in: line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = orderedItem(in: lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(lines[index]) {
                paragraphLines.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func startsBlock(_ line: String) -> Bool {
        openingFenceLanguage(line) != nil
            || heading(in: line) != nil
            || quote(in: line) != nil
            || unorderedItem(in: line) != nil
            || orderedItem(in: line) != nil
    }

    private static func openingFenceLanguage(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return language.isEmpty ? "" : language
    }

    private static func isClosingFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "```"
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard separatorIndex < trimmed.endIndex, trimmed[separatorIndex].isWhitespace else { return nil }
        let text = trimmed[separatorIndex...].drop(while: \Character.isWhitespace)
        return (level, String(text))
    }

    private static func unorderedItem(in line: String) -> ChatMarkdownListItem? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = trimmed.first, "-+*".contains(marker) else { return nil }
        let separatorIndex = trimmed.index(after: trimmed.startIndex)
        guard separatorIndex < trimmed.endIndex, trimmed[separatorIndex].isWhitespace else { return nil }
        let text = trimmed[separatorIndex...].drop(while: \Character.isWhitespace)
        return ChatMarkdownListItem(marker: String(marker), text: String(text))
    }

    private static func orderedItem(in line: String) -> ChatMarkdownListItem? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let digits = trimmed.prefix(while: \Character.isNumber)
        guard !digits.isEmpty else { return nil }
        let punctuationIndex = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard punctuationIndex < trimmed.endIndex,
              trimmed[punctuationIndex] == "." || trimmed[punctuationIndex] == ")" else { return nil }
        let separatorIndex = trimmed.index(after: punctuationIndex)
        guard separatorIndex < trimmed.endIndex, trimmed[separatorIndex].isWhitespace else { return nil }
        let text = trimmed[separatorIndex...].drop(while: \Character.isWhitespace)
        return ChatMarkdownListItem(
            marker: String(trimmed[...punctuationIndex]),
            text: String(text)
        )
    }

    private static func quote(in line: String) -> (depth: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == ">" else { return nil }

        var index = trimmed.startIndex
        var rawDepth = 0
        while index < trimmed.endIndex, trimmed[index] == ">" {
            rawDepth += 1
            index = trimmed.index(after: index)
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
        }
        return (
            min(rawDepth, maximumQuoteDepth),
            String(trimmed[index...])
        )
    }
}

enum ChatInlineMarkdown {
    static func attributedString(_ markdown: String) -> AttributedString {
        do {
            var attributed = try AttributedString(
                markdown: markdown,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
            let unsafeLinkRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
                guard let link = run.link else { return nil }
                let scheme = link.scheme?.lowercased()
                return scheme == "http" || scheme == "https" ? nil : run.range
            }
            for range in unsafeLinkRanges {
                attributed[range].link = nil
            }
            return attributed
        } catch {
            return AttributedString(markdown)
        }
    }
}

struct ChatMarkdownRenderer: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdownParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inlineText(text)
        case let .heading(level, text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(level <= 2 ? .bold : .semibold)
        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").accessibilityHidden(true)
                        inlineText(item.text)
                    }
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker)
                        inlineText(item.text)
                    }
                }
            }
        case let .quote(depth, text):
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(0..<depth, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.secondary.opacity(0.45))
                            .frame(width: 3)
                            .accessibilityHidden(true)
                    }
                }
                inlineText(text)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case let .code(language, content):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(content)
                        .font(.caption.monospaced())
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func inlineText(_ text: String) -> Text {
        Text(ChatInlineMarkdown.attributedString(text))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        case 4: return .subheadline
        default: return .body
        }
    }
}
