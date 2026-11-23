import Foundation
import XCTest
@testable import NKJBlogPoster

final class KeychainAPIKeyStoreTests: XCTestCase {
    func testEncodedAPIKeyRejectsEmptyAndWhitespaceWithoutAccessingKeychain() {
        for value in ["", "   ", "\n\t  \r\n"] {
            XCTAssertThrowsError(try KeychainAPIKeyStore.encodedAPIKey(value)) { error in
                guard case KeychainAPIKeyStoreError.emptyAPIKey = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(error.localizedDescription, "空のAPIキーは保存できません。")
            }
        }
    }

    func testEncodedAPIKeyTrimsAndEncodesOrdinaryFakeValueWithoutAccessingKeychain() throws {
        let data = try KeychainAPIKeyStore.encodedAPIKey("  fake-api-key\n")

        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(String(data: data, encoding: .utf8), "fake-api-key")
    }
}
