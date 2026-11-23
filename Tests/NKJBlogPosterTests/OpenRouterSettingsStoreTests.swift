import Foundation
import XCTest
@testable import NKJBlogPoster

final class OpenRouterSettingsStoreTests: XCTestCase {
    func testDefaultsToGLMFlashAndPersistsMigrationMarker() throws {
        let suiteName = "OpenRouterSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenRouterSettingsStore(defaults: defaults)

        XCTAssertEqual(store.modelID(), "z-ai/glm-5.3-flash")
        store.saveModelID("  provider/model  ")
        XCTAssertEqual(store.modelID(), "provider/model")
        store.saveModelID("   ")
        XCTAssertEqual(store.modelID(), OpenRouterSettingsStore.defaultModelID)
        XCTAssertEqual(
            Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys),
            ["openRouterModelID", "openRouterModelIDMigrationVersion"]
        )
    }

    func testMigratesLegacyKimiDefaultExactlyOnce() throws {
        let suiteName = "OpenRouterSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(OpenRouterSettingsStore.legacyDefaultModelID, forKey: "openRouterModelID")
        let store = OpenRouterSettingsStore(defaults: defaults)

        XCTAssertEqual(store.modelID(), OpenRouterSettingsStore.defaultModelID)
        XCTAssertEqual(defaults.string(forKey: "openRouterModelID"), OpenRouterSettingsStore.defaultModelID)

        // A later explicit selection of Kimi K3 is a custom user choice and must be preserved.
        store.saveModelID(OpenRouterSettingsStore.legacyDefaultModelID)
        XCTAssertEqual(store.modelID(), OpenRouterSettingsStore.legacyDefaultModelID)
    }

    func testDoesNotOverwriteExistingCustomModelDuringMigration() throws {
        let suiteName = "OpenRouterSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("provider/custom-model", forKey: "openRouterModelID")

        XCTAssertEqual(
            OpenRouterSettingsStore(defaults: defaults).modelID(),
            "provider/custom-model"
        )
    }
}
