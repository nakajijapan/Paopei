import Foundation
import XCTest
@testable import NKJBlogPoster

final class PublishingProfileTests: XCTestCase {
    func testMissingProfileStopsPublishing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try PublishingProfile.load(from: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".paopei.json"))
        }
    }

    func testCustomTargetsAndMainBranchCanBeLoaded() throws {
        try withProfile(#"{"sourceRepository":"example/blog","outputRepository":"example/site","outputBranch":"main"}"#) { root in
            let profile = try PublishingProfile.load(from: root)
            XCTAssertEqual(profile.sourceRepository, "example/blog")
            XCTAssertEqual(profile.outputRepository, "example/site")
            XCTAssertEqual(profile.outputBranch, "main")
        }
    }

    func testLegacyProfileStillLoadsWhenNewProfileIsAbsent() throws {
        try withProfile(#"{"sourceRepository":"example/blog","outputRepository":"example/site","outputBranch":"main"}"#) { root in
            try FileManager.default.moveItem(at: root.appendingPathComponent(".paopei.json"), to: root.appendingPathComponent(".nkjblogposter.json"))
            XCTAssertEqual(try PublishingProfile.load(from: root).sourceRepository, "example/blog")
        }
    }

    func testInvalidNewProfileDoesNotFallBackToLegacyProfile() throws {
        try withProfile("{") { root in
            try #"{"sourceRepository":"example/blog","outputRepository":"example/site","outputBranch":"main"}"#.write(to: root.appendingPathComponent(".nkjblogposter.json"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try PublishingProfile.load(from: root))
        }
    }

    func testNewProfileTakesPrecedenceOverLegacyProfile() throws {
        try withProfile(#"{"sourceRepository":"example/new","outputRepository":"example/site","outputBranch":"main"}"#) { root in
            try #"{"sourceRepository":"example/old","outputRepository":"example/site","outputBranch":"master"}"#.write(to: root.appendingPathComponent(".nkjblogposter.json"), atomically: true, encoding: .utf8)
            XCTAssertEqual(try PublishingProfile.load(from: root).sourceRepository, "example/new")
        }
    }

    func testInvalidProfileFails() throws {
        for json in [
            "{",
            #"{"sourceRepository":"example/blog","outputRepository":"example/blog","outputBranch":"main"}"#,
            #"{"sourceRepository":"https://github.com/example/blog","outputRepository":"example/site","outputBranch":"main"}"#,
            #"{"sourceRepository":"example/blog","outputRepository":"example/site","outputBranch":"--all"}"#,
            #"{"sourceRepository":"example/blog","outputRepository":"example/site"}"#
        ] {
            try withProfile(json) { root in
                XCTAssertThrowsError(try PublishingProfile.load(from: root))
            }
        }
    }

    func testOriginChecksAcceptSSHAndHTTPSButRejectSubstringAndCredentialMatches() {
        for remote in ["git@github.com:example/blog.git\n", "https://github.com/example/blog", "ssh://git@github.com/example/blog.git"] {
            XCTAssertTrue(PublishingProfile.matches(remote: remote, repository: "example/blog"), remote)
        }
        for remote in [
            "https://github.com/example/blog-evil.git",
            "https://evil.example/example/blog.git",
            "https://github.com.evil.example/example/blog.git",
            "https://github.com/other/example/blog.git",
            "https://credential@github.com/example/blog.git",
            "https://github.com/example/blog.git?next=evil",
            "/tmp/example/blog"
        ] {
            XCTAssertFalse(PublishingProfile.matches(remote: remote, repository: "example/blog"), remote)
        }
    }

    private func withProfile(_ json: String, body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try json.write(to: root.appendingPathComponent(".paopei.json"), atomically: true, encoding: .utf8)
        try body(root)
    }
}
