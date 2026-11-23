import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// Kept in SwiftUI state so a sibling view update (for example, the Hugo preview)
    /// cannot reset AppKit's insertion point when the representable is refreshed.
    @Binding var selection: NSRange
    /// Stored outside the AppKit coordinator because a representable can be recreated
    /// while a preview reloads. A stale request must not reposition a later edit.
    @Binding var appliedSelectionRequestID: UUID?
    let selectionRequest: EditorSelectionRequest?
    let onPasteImages: ([BlogImageInput], NSRange) -> Bool
    let onScrollOffsetChange: @MainActor (CGFloat) -> Void
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, fontSize: fontSize)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let container = EditorContainerView(frame: .zero)
        let scrollView = container.scrollView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = ImagePasteTextView()
        textView.registerForDraggedTypes(ImageDragPasteboardReader.readableDraggedTypes)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.frame = scrollView.contentView.bounds
        textView.string = text
        MarkdownSyntaxHighlighter.apply(to: textView, fontSize: fontSize)
        textView.setSelectedRange(Self.validSelection(selection, in: text))
        textView.onPasteImages = onPasteImages
        scrollView.documentView = textView
        container.configureToolbar(for: textView)
        container.configureScrollTracking(onChange: onScrollOffsetChange)
        container.updateStatus(text: text, selection: selection)
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        context.coordinator.fontSize = fontSize
        let scrollView = container.scrollView
        container.configureScrollTracking(onChange: onScrollOffsetChange)
        guard let textView = scrollView.documentView as? ImagePasteTextView else { return }
        textView.onPasteImages = onPasteImages
        let hasUnappliedSelectionRequest = selectionRequest.map {
            appliedSelectionRequestID != $0.id
        } ?? false
        let hasChangedFontSize = textView.font?.pointSize != fontSize
        if textView.string != text {
            // NSTextView is the source of truth while the user is actively typing.
            // A preview state update can arrive in the same SwiftUI transaction as a
            // keystroke; assigning the older binding value here would discard text
            // and move the insertion point. Explicit insertion/selection requests
            // are the sole exception because they intentionally replace the text.
            if context.coordinator.isActivelyEditing(textView), !hasUnappliedSelectionRequest {
                context.coordinator.publishText(from: textView)
                return
            }
            // A programmatic Markdown change must not turn into a delegate-originated
            // edit. Use the most recently observed selection rather than the transient
            // selection of a view being recreated by SwiftUI.
            let restoredSelection = Self.validSelection(selection, in: text)
            context.coordinator.isSynchronizingText = true
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            MarkdownSyntaxHighlighter.apply(to: textView, fontSize: fontSize)
            context.coordinator.isSynchronizingText = false
            textView.setSelectedRange(restoredSelection)
            context.coordinator.recordSelection(restoredSelection)
        } else if hasChangedFontSize {
            context.coordinator.isSynchronizingText = true
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            MarkdownSyntaxHighlighter.apply(to: textView, fontSize: fontSize)
            context.coordinator.isSynchronizingText = false
        }

        if let selectionRequest,
           appliedSelectionRequestID != selectionRequest.id {
            textView.setSelectedRange(Self.validSelection(selectionRequest.range, in: text))
            appliedSelectionRequestID = selectionRequest.id
            context.coordinator.recordSelection(textView.selectedRange())
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        container.updateStatus(text: textView.string, selection: textView.selectedRange())
    }

    private static func validSelection(_ selection: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(selection.location, length)
        return NSRange(location: location, length: min(selection.length, length - location))
    }

    final class EditorContainerView: NSView {
        let scrollView = NSScrollView()
        private let toolbar = NSVisualEffectView()
        private let toolbarStack = NSStackView()
        private let statusBar = NSVisualEffectView()
        private let statusLabel = NSTextField(labelWithString: "")
        private var scrollBoundsObserver: NSObjectProtocol?
        private var onScrollOffsetChange: (@MainActor (CGFloat) -> Void)?
        private weak var textView: NSTextView?
        private let toolbarHeight: CGFloat = 56
        private let statusHeight: CGFloat = 25

        override var isOpaque: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            toolbar.material = .headerView
            toolbar.blendingMode = .withinWindow
            toolbar.state = .active
            toolbarStack.orientation = .horizontal
            toolbarStack.spacing = 0
            toolbarStack.alignment = .centerY
            toolbar.addSubview(toolbarStack)
            statusBar.material = .headerView
            statusBar.blendingMode = .withinWindow
            statusBar.state = .active
            statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.lineBreakMode = .byTruncatingTail
            statusBar.addSubview(statusLabel)
            addSubview(toolbar)
            addSubview(scrollView)
            addSubview(statusBar)
        }

        func configureToolbar(for textView: NSTextView) {
            self.textView = textView
            toolbarStack.arrangedSubviews.forEach { view in
                toolbarStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }

            MarkdownControl.allCases
                .filter { $0 != .horizontalRule }
                .forEach { control in
                let button: NSButton
                if control == .heading {
                    button = NSButton(title: "H", target: self, action: #selector(applyMarkdownControl(_:)))
                    button.font = .systemFont(ofSize: 16, weight: .medium)
                } else {
                    button = NSButton(
                        image: NSImage(systemSymbolName: control.symbolName, accessibilityDescription: control.label) ?? NSImage(),
                        target: self,
                        action: #selector(applyMarkdownControl(_:))
                    )
                }
                button.tag = control.rawValue
                button.bezelStyle = .inline
                button.isBordered = false
                button.contentTintColor = .labelColor
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = control.label
                button.setAccessibilityLabel(control.label)
                button.setFrameSize(NSSize(width: 36, height: 36))
                button.widthAnchor.constraint(equalToConstant: 36).isActive = true
                button.heightAnchor.constraint(equalToConstant: 36).isActive = true
                toolbarStack.addArrangedSubview(button)

                if control.endsToolbarGroup {
                    let separator = NSBox()
                    separator.boxType = .separator
                    separator.setFrameSize(NSSize(width: 1, height: 28))
                    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
                    separator.heightAnchor.constraint(equalToConstant: 28).isActive = true
                    toolbarStack.addArrangedSubview(separator)
                }
            }

            let overflow = NSButton(
                image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "その他の装飾") ?? NSImage(),
                target: self,
                action: #selector(showToolbarOverflow(_:))
            )
            overflow.bezelStyle = .inline
            overflow.isBordered = false
            overflow.contentTintColor = .labelColor
            overflow.imageScaling = .scaleProportionallyDown
            overflow.toolTip = "その他の装飾"
            overflow.setAccessibilityLabel("その他の装飾")
            overflow.setFrameSize(NSSize(width: 36, height: 36))
            overflow.widthAnchor.constraint(equalToConstant: 36).isActive = true
            overflow.heightAnchor.constraint(equalToConstant: 36).isActive = true
            toolbarStack.addArrangedSubview(overflow)
        }

        func configureScrollTracking(onChange: @escaping @MainActor (CGFloat) -> Void) {
            onScrollOffsetChange = onChange
            guard scrollBoundsObserver == nil else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            scrollBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak clipView] _ in
                guard let clipView else { return }
                Task { @MainActor [weak self] in
                    self?.onScrollOffsetChange?(clipView.bounds.origin.y)
                }
            }
            onChange(clipView.bounds.origin.y)
        }

        func updateStatus(text: String, selection: NSRange) {
            let location = min(selection.location, (text as NSString).length)
            let prefix = (text as NSString).substring(to: location)
            let line = prefix.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            let column: Int
            if let lineBreak = prefix.lastIndex(of: "\n") {
                column = prefix.distance(from: lineBreak, to: prefix.endIndex)
            } else {
                column = prefix.count + 1
            }
            statusLabel.stringValue = "行 \(line)、列 \(column)     Markdown     UTF-8     \(text.count) 文字"
            textView?.needsDisplay = true
        }

        override func layout() {
            super.layout()
            let editorFrame = NSRect(
                x: 0,
                y: statusHeight,
                width: bounds.width,
                height: max(0, bounds.height - toolbarHeight - statusHeight)
            )
            if scrollView.frame != editorFrame { scrollView.frame = editorFrame }
            toolbar.frame = NSRect(x: 0, y: editorFrame.maxY, width: bounds.width, height: toolbarHeight)
            toolbarStack.frame = toolbar.bounds.insetBy(dx: 16, dy: 10)
            statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: statusHeight)
            statusLabel.frame = statusBar.bounds.insetBy(dx: 12, dy: 4)
        }

        required init?(coder: NSCoder) { nil }


        @objc private func applyMarkdownControl(_ sender: NSButton) {
            applyMarkdownControl(tag: sender.tag)
        }

        @objc private func applyOverflowMarkdownControl(_ sender: NSMenuItem) {
            applyMarkdownControl(tag: sender.tag)
        }

        @objc private func showToolbarOverflow(_ sender: NSButton) {
            let menu = NSMenu()
            let horizontalRule = NSMenuItem(
                title: MarkdownControl.horizontalRule.label,
                action: #selector(applyOverflowMarkdownControl(_:)),
                keyEquivalent: ""
            )
            horizontalRule.target = self
            horizontalRule.tag = MarkdownControl.horizontalRule.rawValue
            menu.addItem(horizontalRule)
            menu.popUp(positioning: horizontalRule, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        }

        private func applyMarkdownControl(tag: Int) {
            guard let control = MarkdownControl(rawValue: tag), let textView else { return }
            textView.window?.makeFirstResponder(textView)
            let selectedRange = textView.selectedRange()
            let source = textView.string as NSString
            guard selectedRange.location != NSNotFound, selectedRange.location <= source.length else { return }

            let clampedLength = min(selectedRange.length, source.length - selectedRange.location)
            let range = NSRange(location: selectedRange.location, length: clampedLength)
            let selectedText = source.substring(with: range)
            let edit = control.edit(for: selectedText)
            textView.insertText(edit.replacement, replacementRange: range)
            textView.setSelectedRange(NSRange(
                location: range.location + edit.selectionOffset,
                length: edit.selectionLength
            ))
        }
    }

    private enum MarkdownControl: Int, CaseIterable {
        case heading
        case bold
        case italic
        case strikethrough
        case code
        case link
        case image
        case bulletList
        case numberedList
        case quote
        case horizontalRule

        struct Edit {
            let replacement: String
            let selectionOffset: Int
            let selectionLength: Int
        }

        var symbolName: String {
            switch self {
            case .heading: "textformat.size"
            case .bold: "bold"
            case .italic: "italic"
            case .strikethrough: "strikethrough"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .link: "link"
            case .image: "photo"
            case .bulletList: "list.bullet"
            case .numberedList: "list.number"
            case .quote: "text.quote"
            case .horizontalRule: "minus"
            }
        }

        var label: String {
            switch self {
            case .heading: "見出し"
            case .bold: "太字"
            case .italic: "斜体"
            case .strikethrough: "取り消し線"
            case .code: "インラインコード"
            case .link: "リンクを挿入"
            case .image: "画像を挿入"
            case .bulletList: "箇条書き"
            case .numberedList: "番号付きリスト"
            case .quote: "引用"
            case .horizontalRule: "区切り線"
            }
        }

        var endsToolbarGroup: Bool {
            switch self {
            case .heading, .strikethrough, .image, .numberedList:
                true
            case .bold, .italic, .code, .link, .bulletList, .quote, .horizontalRule:
                false
            }
        }

        func edit(for selectedText: String) -> Edit {
            switch self {
            case .heading:
                return prefix("# ", selectedText, placeholder: "見出し")
            case .bold:
                return wrap("**", selectedText, suffix: "**", placeholder: "太字")
            case .italic:
                return wrap("*", selectedText, suffix: "*", placeholder: "斜体")
            case .strikethrough:
                return wrap("~~", selectedText, suffix: "~~", placeholder: "取り消し")
            case .code:
                return wrap("`", selectedText, suffix: "`", placeholder: "コード")
            case .link:
                return wrap("[", selectedText, suffix: "](https://)", placeholder: "リンクテキスト")
            case .image:
                return wrap("![", selectedText, suffix: "](画像URL)", placeholder: "代替テキスト")
            case .bulletList:
                return prefixLines("- ", selectedText, placeholder: "項目")
            case .numberedList:
                return prefixLines("1. ", selectedText, placeholder: "項目")
            case .quote:
                return prefixLines("> ", selectedText, placeholder: "引用")
            case .horizontalRule:
                return Edit(replacement: "\n---\n", selectionOffset: 5, selectionLength: 0)
            }
        }

        private func prefix(_ prefix: String, _ selection: String, placeholder: String) -> Edit {
            let text = selection.isEmpty ? placeholder : selection
            return Edit(
                replacement: prefix + text,
                selectionOffset: prefix.utf16.count,
                selectionLength: text.utf16.count
            )
        }

        private func wrap(_ prefix: String, _ selection: String, suffix: String, placeholder: String) -> Edit {
            let text = selection.isEmpty ? placeholder : selection
            return Edit(
                replacement: prefix + text + suffix,
                selectionOffset: prefix.utf16.count,
                selectionLength: text.utf16.count
            )
        }

        private func prefixLines(_ prefix: String, _ selection: String, placeholder: String) -> Edit {
            let text = selection.isEmpty ? placeholder : selection
            let replacement = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { prefix + $0 }
                .joined(separator: "\n")
            return Edit(
                replacement: replacement,
                selectionOffset: prefix.utf16.count,
                selectionLength: replacement.utf16.count - prefix.utf16.count
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var selection: NSRange
        var fontSize: CGFloat
        var isSynchronizingText = false
        private var isHighlighting = false

        init(text: Binding<String>, selection: Binding<NSRange>, fontSize: CGFloat) {
            _text = text
            _selection = selection
            self.fontSize = fontSize
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizingText, !isHighlighting else { return }
            guard let textView = notification.object as? NSTextView else { return }
            publishText(from: textView)
            isHighlighting = true
            MarkdownSyntaxHighlighter.apply(to: textView, fontSize: fontSize)
            isHighlighting = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            recordSelection(textView.selectedRange())
        }

        func recordSelection(_ value: NSRange) {
            guard selection != value else { return }
            selection = value
        }

        func isActivelyEditing(_ textView: NSTextView) -> Bool {
            textView.window?.firstResponder === textView
        }

        func publishText(from textView: NSTextView) {
            if text != textView.string {
                text = textView.string
            }
            recordSelection(textView.selectedRange())
        }
    }
}

/// Applies lightweight Markdown syntax coloring without changing the document text.
/// System colors are dynamic, so the editor remains legible in both light and dark appearance.
@MainActor
enum MarkdownSyntaxHighlighter {
    private static let frontMatterDelimiterColor = NSColor.tertiaryLabelColor
    private static let frontMatterKeyColor = NSColor.systemPurple
    private static let frontMatterValueColor = NSColor.secondaryLabelColor
    private static let headingMarkerColor = NSColor.systemOrange
    private static let headingTextColor = NSColor.systemBlue
    private static let listMarkerColor = NSColor.systemOrange
    private static let quoteMarkerColor = NSColor.systemTeal
    private static let quoteTextColor = NSColor.secondaryLabelColor
    private static let codeColor = NSColor.systemPurple
    private static let linkLabelColor = NSColor.systemBlue
    private static let linkDestinationColor = NSColor.systemTeal
    private static let htmlCommentColor = NSColor.systemGray

    static func apply(to textView: NSTextView, fontSize: CGFloat = NSFont.systemFontSize) {
        guard let textStorage = textView.textStorage else { return }
        let text = textStorage.string
        let fullRange = NSRange(text.startIndex..., in: text)

        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        let baseAttributes = baseAttributes(fontSize: fontSize)
        textStorage.setAttributes(baseAttributes, range: fullRange)

        var isInFrontMatter = false
        var isInCodeFence = false
        var isInHTMLComment = false
        var canStartFrontMatter = true

        text.enumerateSubstrings(
            in: text.startIndex..., options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let line = String(text[lineRange])
            let nsLineRange = NSRange(lineRange, in: text)

            if line == "---" && (isInFrontMatter || canStartFrontMatter) {
                color(frontMatterDelimiterColor, in: nsLineRange, storage: textStorage)
                isInFrontMatter.toggle()
            } else if isInFrontMatter {
                applyFrontMatter(to: line, lineRange: nsLineRange, storage: textStorage)
            } else if isInCodeFence {
                color(codeColor, in: nsLineRange, storage: textStorage)
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    isInCodeFence = false
                }
            } else if isInHTMLComment {
                isInHTMLComment = applyHTMLComments(
                    to: line,
                    lineRange: nsLineRange,
                    storage: textStorage,
                    startsInComment: true
                )
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                canStartFrontMatter = false
                color(codeColor, in: nsLineRange, storage: textStorage)
                isInCodeFence = true
            } else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    canStartFrontMatter = false
                }
                applyBlockSyntax(to: line, lineRange: nsLineRange, storage: textStorage)
                applyInlineSyntax(to: line, lineRange: nsLineRange, storage: textStorage)
                isInHTMLComment = applyHTMLComments(
                    to: line,
                    lineRange: nsLineRange,
                    storage: textStorage,
                    startsInComment: false
                )
            }
        }

        textView.typingAttributes = baseAttributes
    }

    private static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static func applyFrontMatter(
        to line: String,
        lineRange: NSRange,
        storage: NSTextStorage
    ) {
        guard let separator = line.firstIndex(of: ":") else { return }
        let keyRange = NSRange(line.startIndex..<separator, in: line)
        let valueRange = NSRange(separator..<line.endIndex, in: line)
        color(frontMatterKeyColor, in: offset(keyRange, by: lineRange.location), storage: storage)
        color(frontMatterValueColor, in: offset(valueRange, by: lineRange.location), storage: storage)
    }

    private static func applyBlockSyntax(
        to line: String,
        lineRange: NSRange,
        storage: NSTextStorage
    ) {
        if let match = firstMatch(in: line, pattern: "^(#{1,6})(\\s+)(.*)$") {
            color(headingMarkerColor, in: range(match, at: 1, offsetBy: lineRange.location), storage: storage)
            color(headingTextColor, in: range(match, at: 3, offsetBy: lineRange.location), storage: storage)
            return
        }

        if let match = firstMatch(in: line, pattern: "^(>+)(?:\\s+)?(.*)$") {
            color(quoteMarkerColor, in: range(match, at: 1, offsetBy: lineRange.location), storage: storage)
            color(quoteTextColor, in: range(match, at: 2, offsetBy: lineRange.location), storage: storage)
            return
        }

        if let match = firstMatch(in: line, pattern: "^(?:[-+*]|\\d+[.)])(\\s+)") {
            color(listMarkerColor, in: range(match, at: 0, offsetBy: lineRange.location), storage: storage)
        }
    }

    private static func applyInlineSyntax(
        to line: String,
        lineRange: NSRange,
        storage: NSTextStorage
    ) {
        for match in matches(in: line, pattern: "(!?\\[[^\\]]*\\])(?:\\()([^)]*)(?:\\))") {
            color(linkLabelColor, in: range(match, at: 1, offsetBy: lineRange.location), storage: storage)
            color(linkDestinationColor, in: range(match, at: 2, offsetBy: lineRange.location), storage: storage)
        }

        for match in matches(in: line, pattern: "`[^`]+`") {
            color(codeColor, in: range(match, at: 0, offsetBy: lineRange.location), storage: storage)
        }
    }

    /// Colors HTML comments, including comments that span multiple lines, without
    /// altering the document text.
    /// - Returns: Whether the final character of this line remains inside a comment.
    private static func applyHTMLComments(
        to line: String,
        lineRange: NSRange,
        storage: NSTextStorage,
        startsInComment: Bool
    ) -> Bool {
        var index = line.startIndex
        var isInComment = startsInComment

        while index < line.endIndex {
            if isInComment {
                if let end = line.range(of: "-->", range: index..<line.endIndex) {
                    color(
                        htmlCommentColor,
                        in: offset(
                            NSRange(index..<end.upperBound, in: line),
                            by: lineRange.location
                        ),
                        storage: storage
                    )
                    index = end.upperBound
                    isInComment = false
                } else {
                    color(
                        htmlCommentColor,
                        in: offset(
                            NSRange(index..<line.endIndex, in: line),
                            by: lineRange.location
                        ),
                        storage: storage
                    )
                    return true
                }
            } else if let start = line.range(of: "<!--", range: index..<line.endIndex) {
                index = start.lowerBound
                isInComment = true
            } else {
                break
            }
        }

        return isInComment
    }

    private static func color(_ color: NSColor, in range: NSRange, storage: NSTextStorage) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }

    private static func offset(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func range(_ match: NSTextCheckingResult, at index: Int, offsetBy offset: Int) -> NSRange {
        self.offset(match.range(at: index), by: offset)
    }

    private static func firstMatch(in line: String, pattern: String) -> NSTextCheckingResult? {
        matches(in: line, pattern: pattern).first
    }

    private static func matches(in line: String, pattern: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
    }
}

final class ImagePasteTextView: NSTextView {
    var onPasteImages: (([BlogImageInput], NSRange) -> Bool)?

    override func paste(_ sender: Any?) {
        let inputs = ImageDragPasteboardReader.imageInputs(from: .general)
        if !inputs.isEmpty, onPasteImages?(inputs, selectedRange()) == true {
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageDragPasteboardReader.canReadImages(from: sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ImageDragPasteboardReader.canReadImages(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        // NSTextView keeps its old selected range while a Finder drag is in
        // progress. Resolve the insertion position from the actual drop point
        // instead, then retain it for asynchronous file-promise imports.
        let selection = selectionAtDropLocation(sender.draggingLocation)
        let inputs = ImageDragPasteboardReader.imageInputs(from: pasteboard)
        if !inputs.isEmpty {
            return onPasteImages?(inputs, selection) ?? false
        }

        let receivers = ImageDragPasteboardReader.filePromiseReceivers(from: pasteboard)
        guard !receivers.isEmpty else { return false }
        ImageDragPasteboardReader.loadPromisedImageInputs(from: receivers) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let promisedInputs):
                guard !promisedInputs.isEmpty else {
                    NSSound.beep()
                    return
                }
                _ = self.onPasteImages?(promisedInputs, selection)
            case .failure:
                NSSound.beep()
            }
        }
        return true
    }

    private func selectionAtDropLocation(_ windowLocation: NSPoint) -> NSRange {
        let location = convert(windowLocation, from: nil)
        let index = min(characterIndexForInsertion(at: location), (string as NSString).length)
        let selection = NSRange(location: index, length: 0)
        setSelectedRange(selection)
        window?.makeFirstResponder(self)
        return selection
    }
}
