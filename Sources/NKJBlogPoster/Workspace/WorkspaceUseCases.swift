import Foundation

/// Application operation for saving Markdown. It keeps file-system access behind
/// `BlogRepository` and gives the editor feature a small, directly testable seam.
struct SavePostUseCase {
    let repository: BlogRepository

    func execute(markdown: String, post: BlogPost?) throws {
        guard let post else { throw AppError.noSelection }
        try repository.save(markdown, to: post.url)
    }
}

/// Applies an explicitly accepted AI proposal only when it still belongs to the
/// selected article and the editor has not changed since generation.
struct ApplyChatProposalUseCase {
    let repository: BlogRepository

    func execute(
        proposal: ChatProposal,
        selectedPost: BlogPost?,
        currentMarkdown: String
    ) throws -> String {
        guard let selectedPost, selectedPost.url == proposal.postURL else {
            throw AppError.invalidChatProposal("別の記事で作成された更新案のため反映できません。")
        }
        guard currentMarkdown == proposal.baseMarkdown else {
            throw AppError.invalidChatProposal("更新案の作成後に本文が編集されたため反映できません。更新案を破棄して作り直してください。")
        }
        try ChatDraftService.validateProposal(proposal.markdown, baseMarkdown: proposal.baseMarkdown)
        try repository.save(proposal.markdown, to: selectedPost.url)
        return proposal.markdown
    }
}

/// Pure Markdown composition used by local and remote image imports. Keeping this
/// out of the SwiftUI view makes invalid selections and concurrent editor changes
/// testable without invoking file or network adapters.
enum ImageInsertionUseCase {
    static func replacing(
        markdown: String,
        range: NSRange,
        replacement: String
    ) throws -> String {
        let length = (markdown as NSString).length
        guard range.location <= length, range.length <= length - range.location else {
            throw AppError.imageImport("画像の挿入位置を取得できませんでした。")
        }
        return (markdown as NSString).replacingCharacters(in: range, with: replacement)
    }

    static func appending(_ imageMarkdown: String, to markdown: String) -> String {
        let separator = markdown.hasSuffix("\n\n") ? "" : (markdown.hasSuffix("\n") ? "\n" : "\n\n")
        return markdown + separator + imageMarkdown + "\n"
    }
}

/// Explicit publication operation. The caller owns confirmation and UI state;
/// this use case only creates the fixed configuration and delegates to the
/// publishing adapter, which retains all preflight safety checks.
struct PublishPostUseCase {
    let sourceRepository: URL

    func configuration(for post: BlogPost, markdown: String) -> PublishConfiguration {
        PublishConfiguration(
            sourceRepository: sourceRepository,
            outputRepository: sourceRepository.appendingPathComponent("public", isDirectory: true),
            postURL: post.url,
            commitMessage: "Publish: \(FrontMatterParser.parse(markdown).title)"
        )
    }

    func preflight(_ configuration: PublishConfiguration, markdown: String) throws {
        try PublishingService.preflight(configuration, markdown: markdown)
    }

    func publish(_ configuration: PublishConfiguration) throws -> PublishReport {
        try PublishingService.publish(configuration)
    }
}
