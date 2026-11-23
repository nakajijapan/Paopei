import Foundation
import XCTest
@testable import NKJBlogPoster

final class PersonaStoreTests: XCTestCase {
    func testSavesRestoresAndClearsPersonaInDedicatedSuite() throws {
        let suiteName = "PersonaStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonaStore(defaults: defaults)

        XCTAssertNil(store.load())
        try store.save("落ち着いた一人称で書く")
        XCTAssertEqual(store.load(), "落ち着いた一人称で書く")
        try store.save("   \n")
        XCTAssertNil(store.load())
    }

    func testRejectsPersonaOverMaximumLength() throws {
        let suiteName = "PersonaStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonaStore(defaults: defaults)

        XCTAssertThrowsError(try store.save(String(repeating: "あ", count: PersonaStore.maximumLength + 1)))
        XCTAssertNil(store.load())
    }
}
