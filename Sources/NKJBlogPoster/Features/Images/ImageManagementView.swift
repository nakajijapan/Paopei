import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false
    @State private var showingImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.selectedPost == nil {
                ContentUnavailableView(
                    "記事が選択されていません",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("左の記事一覧から画像を管理する記事を選択してください。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: model.isImportingImages
                                  ? "arrow.triangle.2.circlepath"
                                  : "square.and.arrow.down")
                                .font(.title3)
                                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isDropTargeted ? "ここにドロップ" : "画像をドラッグ＆ドロップ")
                                    .font(.callout.weight(.semibold))
                                Text("JPEG・PNG・GIFを記事に追加します")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isImportingImages {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    showingImporter = true
                                } label: {
                                    Label("選択", systemImage: "plus")
                                }
                                .buttonStyle(.bordered)
                                .help("Finderから記事へ追加する画像を選択")
                                .accessibilityLabel("追加する画像を選択")
                                .accessibilityHint("Finderを開いてJPEG、PNG、GIF画像を選びます")
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isDropTargeted ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                                style: StrokeStyle(lineWidth: 1, dash: [6])
                            )
                    }
                    .overlay {
                        ImageDropReceiver(isTargeted: $isDropTargeted) { inputs in
                            guard !model.isImportingImages else { return false }
                            model.importImages(inputs)
                            return true
                        } onError: { error in
                            model.present(error)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("画像のドロップ領域")
                    .accessibilityHint("FinderまたはPhotosから画像をドロップすると、選択中の記事へ追加します")

                    HStack(alignment: .firstTextBaseline) {
                        Label("参照画像", systemImage: "photo.stack")
                            .font(.headline)
                        Spacer()
                        Text("\(model.referencedImages.count)枚")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if model.referencedImages.isEmpty {
                        ContentUnavailableView(
                            "参照画像はありません",
                            systemImage: "photo.on.rectangle",
                            description: Text("画像を追加すると、この記事が参照する画像をここで確認できます。")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.referencedImages.enumerated()), id: \.element.id) { index, image in
                                    ImageTile(image: image)
                                    if index < model.referencedImages.count - 1 {
                                        Divider()
                                            .padding(.leading, 70)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.jpeg, .png, .gif],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importImages(urls)
            case .failure(let error):
                model.present(error)
            }
        }
    }

}

private struct ImageTile: View {
    let image: BlogImage

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if image.exists, let nsImage = NSImage(contentsOf: image.fileURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 58, height: 58)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(image.fileName)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                if image.exists {
                    Text(image.publicPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Label("ファイルが見つかりません", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                ImageActionButton(
                    title: "Markdownをコピー",
                    systemImage: "doc.on.doc",
                    isEnabled: image.exists,
                    accessibilityLabel: "\(image.fileName)のMarkdownをコピー",
                    accessibilityHint: image.exists
                        ? "画像参照用のMarkdownをクリップボードへコピーします"
                        : "画像ファイルが見つからないため利用できません"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(image.markdown, forType: .string)
                }

                ImageActionButton(
                    title: "Finderで表示",
                    systemImage: "folder",
                    isEnabled: image.exists,
                    accessibilityLabel: "\(image.fileName)をFinderで表示",
                    accessibilityHint: image.exists
                        ? "画像ファイルの保存場所をFinderで開きます"
                        : "画像ファイルが見つからないため利用できません"
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([image.fileURL])
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(image.exists
                            ? "記事画像 \(image.fileName)"
                            : "欠落している記事画像 \(image.fileName)")
    }
}

/// An AppKit-backed button so row actions retain their hover and press feedback
/// even while hosted inside the native detail-panel container.
private struct ImageActionButton: NSViewRepresentable {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    func makeNSView(context: Context) -> HoverFeedbackButton {
        let button = HoverFeedbackButton()
        configure(button)
        return button
    }

    func updateNSView(_ button: HoverFeedbackButton, context: Context) {
        configure(button)
    }

    private func configure(_ button: HoverFeedbackButton) {
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.toolTip = title
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHint)
        button.actionHandler = action
        button.isEnabled = isEnabled
    }
}

private final class HoverFeedbackButton: NSButton {
    var actionHandler: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressing = false { didSet { updateAppearance() } }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovering = false }
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(didPress)
        setFrameSize(NSSize(width: 28, height: 28))
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = isEnabled
        super.mouseDown(with: event)
        isPressing = false
    }

    @objc private func didPress() {
        actionHandler?()
    }

    private func updateAppearance() {
        let background: NSColor
        let foreground: NSColor
        if !isEnabled {
            background = .clear
            foreground = .disabledControlTextColor
        } else if isPressing {
            background = .controlAccentColor.withAlphaComponent(0.28)
            foreground = .controlAccentColor
        } else if isHovering {
            background = .labelColor.withAlphaComponent(0.12)
            foreground = .labelColor
        } else {
            background = .clear
            foreground = .secondaryLabelColor
        }
        layer?.backgroundColor = background.cgColor
        contentTintColor = foreground
    }
}
