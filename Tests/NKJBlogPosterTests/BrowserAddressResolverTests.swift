import Foundation
import XCTest
@testable import NKJBlogPoster

final class BrowserAddressResolverTests: XCTestCase {
    func testNavigatesExplicitHTTPSAndBarePublicHost() {
        XCTAssertEqual(
            BrowserAddressResolver.resolve("https://example.com/path?q=1"),
            .navigate(URL(string: "https://example.com/path?q=1")!)
        )
        XCTAssertEqual(
            BrowserAddressResolver.resolve("example.com/path?q=1"),
            .navigate(URL(string: "https://example.com/path?q=1")!)
        )
    }

    func testBuildsGoogleSearchURLForJapaneseEnglishAndReservedCharacters() throws {
        let japanese = try navigationURL(for: "京都 カフェ & 朝食")
        XCTAssertEqual(japanese.scheme, "https")
        XCTAssertEqual(japanese.host, "www.google.com")
        XCTAssertEqual(japanese.path, "/search")
        XCTAssertEqual(URLComponents(url: japanese, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "q", value: "京都 カフェ & 朝食")
        ])

        let english = try navigationURL(for: "Swift URLComponents q=a&b")
        XCTAssertEqual(URLComponents(url: english, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "q", value: "Swift URLComponents q=a&b")
        ])
        XCTAssertFalse(english.absoluteString.contains("q=a&b"))
    }

    func testRejectsExplicitUnsafeSchemesHTTPAndLocalHosts() {
        for value in [
            "http://example.com",
            "file:///tmp/image.png",
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            "about:blank",
            "localhost",
            "127.0.0.1",
            "10.0.0.1",
            "192.168.1.1",
            "172.16.0.1",
            "https://[::1]/"
        ] {
            XCTAssertEqual(BrowserAddressResolver.resolve(value), .rejected, "Expected rejection: \(value)")
        }
    }

    func testWhitespaceDoesNotNavigate() {
        XCTAssertEqual(BrowserAddressResolver.resolve(" \n\t "), .empty)
    }

    private func navigationURL(for input: String) throws -> URL {
        guard case .navigate(let url) = BrowserAddressResolver.resolve(input) else {
            throw NSError(domain: "BrowserAddressResolverTests", code: 1)
        }
        return url
    }
}
