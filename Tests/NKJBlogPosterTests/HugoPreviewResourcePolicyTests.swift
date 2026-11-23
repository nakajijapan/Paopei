import Foundation
import XCTest
@testable import NKJBlogPoster

final class HugoPreviewResourcePolicyTests: XCTestCase {
    private let localPort = 13_131

    func testAllowsOnlyTheActiveLoopbackServerForTopLevelNavigation() throws {
        XCTAssertTrue(HugoPreviewResourcePolicy.allowsTopLevelNavigation(
            try XCTUnwrap(URL(string: "http://127.0.0.1:13131/posts/test/")),
            localPort: localPort
        ))
        XCTAssertTrue(HugoPreviewResourcePolicy.allowsTopLevelNavigation(
            try XCTUnwrap(URL(string: "about:blank")),
            localPort: localPort
        ))
        XCTAssertFalse(HugoPreviewResourcePolicy.allowsTopLevelNavigation(
            try XCTUnwrap(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")),
            localPort: localPort
        ))
        XCTAssertFalse(HugoPreviewResourcePolicy.allowsTopLevelNavigation(
            try XCTUnwrap(URL(string: "http://127.0.0.1:13132/")),
            localPort: localPort
        ))
    }

    func testAllowsRequiredEmbeddedResourcesOnly() throws {
        let allowed = [
            "https://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
            "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
            "https://rr1---sn-ab5l6nrl.googlevideo.com/videoplayback",
            "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"
        ]
        for string in allowed {
            XCTAssertTrue(HugoPreviewResourcePolicy.allowsEmbeddedNavigation(
                try XCTUnwrap(URL(string: string)),
                localPort: localPort
            ), string)
        }

        let denied = [
            "http://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://youtube.example.com/embed/dQw4w9WgXcQ",
            "https://notyoutube.com/embed/dQw4w9WgXcQ",
            "https://www.google.com/",
            "https://evilgooglevideo.com/videoplayback",
            "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs",
            "https://cdn.jsdelivr.net/npm/other-library@11/index.mjs"
        ]
        for string in denied {
            XCTAssertFalse(HugoPreviewResourcePolicy.allowsEmbeddedNavigation(
                try XCTUnwrap(URL(string: string)),
                localPort: localPort
            ), string)
        }
    }

    func testContentRulesAllowOnlyLocalPreviewAndRequiredEmbeddedResources() throws {
        let encoded = HugoPreviewResourcePolicy.contentRuleList(port: localPort)
        let rules = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]]
        )
        let filters = try rules.map { rule -> String in
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: String])
            return try XCTUnwrap(trigger["url-filter"])
        }

        XCTAssertEqual(filters.first, ".*")
        XCTAssertTrue(filters.contains("^http://127\\.0\\.0\\.1:13131/"))
        XCTAssertTrue(filters.contains("^https://(www\\.)?youtube\\.com/"))
        XCTAssertTrue(filters.contains("^https://(www\\.)?youtube-nocookie\\.com/"))
        XCTAssertTrue(filters.contains("^https://([A-Za-z0-9-]+\\.)?ytimg\\.com/"))
        XCTAssertTrue(filters.contains("^https://([A-Za-z0-9-]+\\.)?googlevideo\\.com/"))
        XCTAssertTrue(filters.contains("^https://cdn\\.jsdelivr\\.net/npm/mermaid@11/"))
    }
}
