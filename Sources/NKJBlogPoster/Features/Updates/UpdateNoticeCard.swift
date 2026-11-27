import SwiftUI

struct UpdateVersion: Equatable {
    let build: String
    let display: String
}

enum UpdateNoticeState: Equatable {
    case none
    case available(UpdateVersion)
    case downloading(UpdateVersion)
    case failed(UpdateVersion)

    var version: UpdateVersion? {
        switch self {
        case .none: nil
        case let .available(version), let .downloading(version), let .failed(version): version
        }
    }
}

struct UpdateNoticeCard: View {
    let state: UpdateNoticeState
    let update: () -> Void
    let postpone: () -> Void

    var body: some View {
        if let version = state.version {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("新しいバージョンがあります")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)

                        Text(state == .failed(version)
                             ? "更新できませんでした。少し待ってからもう一度お試しください。"
                             : "v\(version.display)・再起動すると反映されます")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 1)
                }

                if state == .downloading(version) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .accessibilityLabel("アップデートを準備中")
                } else {
                    HStack(spacing: 8) {
                        Button(state == .failed(version) ? "もう一度試す" : "再起動して更新", action: update)
                            .buttonStyle(UpdateNoticeButtonStyle(prominent: true))
                        if state == .available(version) {
                            Button("あとで", action: postpone)
                                .buttonStyle(UpdateNoticeButtonStyle(prominent: false))
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct UpdateNoticeButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: prominent ? .infinity : nil, minHeight: 28)
            .background(
                prominent ? Color.accentColor : Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

#if !SWIFT_PACKAGE
struct UpdateNoticeFooter: View {
    @Environment(UpdateManager.self) private var manager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if manager.state.version != nil {
                UpdateNoticeCard(state: manager.state, update: manager.install, postpone: manager.postpone)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 0, y: 8)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.state.version != nil)
    }
}
#endif

private let previewVersion = UpdateVersion(build: "1.0.2", display: "1.0.2")

#Preview("通知なし") {
    UpdateNoticeCard(state: .none, update: {}, postpone: {})
        .frame(width: 326, height: 102)
}

#Preview("更新あり") {
    UpdateNoticeCard(state: .available(previewVersion), update: {}, postpone: {})
        .frame(width: 326)
        .padding(12)
}

#Preview("ダウンロード中") {
    UpdateNoticeCard(state: .downloading(previewVersion), update: {}, postpone: {})
        .frame(width: 326)
        .padding(12)
}

#Preview("失敗") {
    UpdateNoticeCard(state: .failed(previewVersion), update: {}, postpone: {})
        .frame(width: 326)
        .padding(12)
}
