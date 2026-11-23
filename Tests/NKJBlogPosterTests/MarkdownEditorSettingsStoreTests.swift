import Foundation
import XCTest
@testable import NKJBlogPoster

final class MarkdownEditorSettingsStoreTests: XCTestCase {
    func testDefaultsToReadableFontSizeAndPersistsSelection() throws {
        let suiteName = "MarkdownEditorSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MarkdownEditorSettingsStore(defaults: defaults)

        XCTAssertEqual(store.fontSize(), 15)

        store.saveFontSize(19)

        XCTAssertEqual(store.fontSize(), 19)
        XCTAssertEqual(defaults.double(forKey: "markdownEditorFontSize"), 19)
    }

    func testInvalidStoredOrRequestedFontSizeFallsBackToDefault() throws {
        let suiteName = "MarkdownEditorSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MarkdownEditorSettingsStore(defaults: defaults)

        defaults.set(100, forKey: "markdownEditorFontSize")
        XCTAssertEqual(store.fontSize(), MarkdownEditorSettingsStore.defaultFontSize)

        store.saveFontSize(100)
        XCTAssertEqual(store.fontSize(), MarkdownEditorSettingsStore.defaultFontSize)
    }
}
