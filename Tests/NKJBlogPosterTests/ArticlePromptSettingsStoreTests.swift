import Foundation
import XCTest
@testable import NKJBlogPoster

final class ArticlePromptSettingsStoreTests: XCTestCase {
    func testDefaultsAndVerbatimPersistenceAcrossStoreInstances() throws {
        try withDefaults { defaults in
            let store = ArticlePromptSettingsStore(defaults: defaults)
            XCTAssertEqual(store.load(), .defaults)
            let custom = ArticlePromptSettings(
                newArticleTemplate: "  # 背景\n\n本文  \n",
                editingInstructions: "見出しを変えず、短い文に整えてください。\n"
            )
            try store.save(custom)
            XCTAssertEqual(ArticlePromptSettingsStore(defaults: defaults).load(), custom)
        }
    }

    func testBlankFieldsRestoreTheirOwnDefaults() throws {
        try withDefaults { defaults in
            let store = ArticlePromptSettingsStore(defaults: defaults)
            try store.save(ArticlePromptSettings(newArticleTemplate: " \n", editingInstructions: "独自の指示"))
            XCTAssertEqual(store.load().newArticleTemplate, ArticlePromptSettings.defaults.newArticleTemplate)
            XCTAssertEqual(store.load().editingInstructions, "独自の指示")
            try store.save(ArticlePromptSettings(newArticleTemplate: "# 独自の本文", editingInstructions: "\t"))
            XCTAssertEqual(store.load().newArticleTemplate, "# 独自の本文")
            XCTAssertEqual(store.load().editingInstructions, ArticlePromptSettings.defaults.editingInstructions)
        }
    }

    func testOverLimitSaveDoesNotPartiallyOverwriteEitherField() throws {
        try withDefaults { defaults in
            let store = ArticlePromptSettingsStore(defaults: defaults)
            let original = ArticlePromptSettings(newArticleTemplate: "元の本文", editingInstructions: "元の指示")
            try store.save(original)
            let tooLong = String(repeating: "あ", count: ArticlePromptSettingsStore.maximumLength + 1)
            XCTAssertThrowsError(try store.save(ArticlePromptSettings(newArticleTemplate: "新しい本文", editingInstructions: tooLong)))
            XCTAssertEqual(store.load(), original)
            XCTAssertThrowsError(try store.save(ArticlePromptSettings(newArticleTemplate: tooLong, editingInstructions: "新しい指示")))
            XCTAssertEqual(store.load(), original)
        }
    }

    func testInvalidStoredFieldDoesNotDiscardTheOtherSetting() throws {
        try withDefaults { defaults in
            defaults.set(["newArticleTemplate": 123, "editingInstructions": "維持する指示"], forKey: "articlePromptSettings")
            let settings = ArticlePromptSettingsStore(defaults: defaults).load()
            XCTAssertEqual(settings.newArticleTemplate, ArticlePromptSettings.defaults.newArticleTemplate)
            XCTAssertEqual(settings.editingInstructions, "維持する指示")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "ArticlePromptSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
