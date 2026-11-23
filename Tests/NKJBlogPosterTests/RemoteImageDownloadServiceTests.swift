import Foundation
import XCTest
@testable import NKJBlogPoster

final class RemoteImageDownloadServiceTests: XCTestCase {
    func testRejectsNonHTTPSAndPrivateImageURLsBeforeAnyRequest() {
        for value in [
            "http://example.com/image.png",
            "file:///tmp/image.png",
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            "https://localhost/image.png",
            "https://127.0.0.1/image.png",
            "https://192.168.1.10/image.png",
            "https://10.0.0.1/image.png",
            "https://172.16.0.1/image.png",
            "https://169.254.1.1/image.png"
        ] {
            XCTAssertThrowsError(try RemoteImageDownloadService.validatePublicHTTPSURL(URL(string: value)!))
        }
        XCTAssertNoThrow(try RemoteImageDownloadService.validatePublicHTTPSURL(
            URL(string: "https://images.example.com/photo.png")!
        ))
    }

    func testAcceptsOnlyMatchingSupportedContentTypeAndImageBytes() throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        XCTAssertEqual(
            try RemoteImageDownloadService.imageExtension(contentType: "image/png", data: png),
            "png"
        )
        XCTAssertThrowsError(
            try RemoteImageDownloadService.imageExtension(contentType: "image/jpeg", data: png)
        )
        XCTAssertThrowsError(
            try RemoteImageDownloadService.imageExtension(contentType: "image/webp", data: png)
        )
        XCTAssertThrowsError(
            try RemoteImageDownloadService.imageExtension(contentType: "image/png", data: Data("not an image".utf8))
        )
    }
}
