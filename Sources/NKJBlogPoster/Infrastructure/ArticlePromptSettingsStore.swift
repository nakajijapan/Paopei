import Foundation

struct ArticlePromptSettings: Equatable, Sendable {
    var newArticleTemplate: String
    var editingInstructions: String

    static let defaults = ArticlePromptSettings(
        newArticleTemplate: """
        # きっかけ

        <!-- 何が気になったのか、何に困ったのかを書く -->

        # やったこと

        <!-- 実際に試したこと、見たもの、使ったものを書く -->

        # 使ってみて

        <!-- 良かった点と、まだ残る不便を書く -->

        # 次

        <!-- 次に試したいことを書く -->
        """,
        editingInstructions: """
        編集指示を反映したMarkdown全文だけを返してください。コードフェンスや説明文は付けません。
        YAML Front Matterのtitle、slug、draftを必ず残し、draftの値を変更してはいけません。
        dateは現在の記事の値をそのまま残し、表記を含めて変更してはいけません。
        """
    )
}

struct ArticlePromptSettingsStore {
    static let maximumLength = 20_000
    private let defaults: UserDefaults
    private let key = "articlePromptSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ArticlePromptSettings {
        let stored = defaults.dictionary(forKey: key)
        return ArticlePromptSettings(
            newArticleTemplate: Self.usable(stored?["newArticleTemplate"] as? String)
                ?? ArticlePromptSettings.defaults.newArticleTemplate,
            editingInstructions: Self.usable(stored?["editingInstructions"] as? String)
                ?? ArticlePromptSettings.defaults.editingInstructions
        )
    }

    func save(_ settings: ArticlePromptSettings) throws {
        guard settings.newArticleTemplate.count <= Self.maximumLength,
              settings.editingInstructions.count <= Self.maximumLength else {
            throw AppError.invalidChatProposal("本文テンプレートとAIの記事編集指示は、それぞれ\(Self.maximumLength)文字以内で入力してください。")
        }
        // Validate both fields before persisting either one. Preserve entered Markdown verbatim.
        defaults.set([
            "newArticleTemplate": Self.usable(settings.newArticleTemplate)
                ?? ArticlePromptSettings.defaults.newArticleTemplate,
            "editingInstructions": Self.usable(settings.editingInstructions)
                ?? ArticlePromptSettings.defaults.editingInstructions
        ], forKey: key)
    }

    private static func usable(_ text: String?) -> String? {
        guard let text, text.count <= maximumLength,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
