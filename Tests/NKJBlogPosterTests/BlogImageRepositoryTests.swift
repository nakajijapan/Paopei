import Foundation
import XCTest
@testable import NKJBlogPoster

final class BlogImageRepositoryTests: XCTestCase {
    func testImportsImagesUsingExistingYearMonthSequence() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let root = temporary.appendingPathComponent("blog")
        let imageDirectory = root.appendingPathComponent("static/images/posts/2026")
        let sourceDirectory = temporary.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: imageDirectory.appendingPathComponent("10-001.png"))
        try Data([2]).write(to: imageDirectory.appendingPathComponent("10-009.jpeg"))

        let jpeg = sourceDirectory.appendingPathComponent("photo-a.jpeg")
        let png = sourceDirectory.appendingPathComponent("photo-b.PNG")
        try Data([3, 4]).write(to: jpeg)
        try Data([5, 6]).write(to: png)
        let date = ISO8601DateFormatter().date(from: "2026-10-12T03:00:00Z")!

        let result = try BlogImageRepository(root: root)
            .importImages([jpeg, png], articleDate: date)

        XCTAssertEqual(result.map(\.fileName), ["10-010.jpg", "10-011.png"])
        XCTAssertEqual(
            result.map(\.publicPath),
            ["/images/posts/2026/10-010.jpg", "/images/posts/2026/10-011.png"]
        )
        XCTAssertEqual(try Data(contentsOf: result[0].fileURL), Data([3, 4]))
        XCTAssertEqual(try Data(contentsOf: result[1].fileURL), Data([5, 6]))
    }

    func testRejectsUnsupportedImageWithoutCreatingFiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let source = temporary.appendingPathComponent("photo.heic")
        try Data([1]).write(to: source)

        XCTAssertThrowsError(
            try BlogImageRepository(root: temporary.appendingPathComponent("blog"))
                .importImages([source], articleDate: Date())
        )
    }

    func testImportsClipboardDataUsingArticleYearMonth() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("blog")
        let date = ISO8601DateFormatter().date(from: "2025-11-12T03:00:00Z")!

        let result = try BlogImageRepository(root: root).importImages(
            [.data(Self.tinyPNG, fileExtension: "PNG")],
            articleDate: date
        )

        XCTAssertEqual(result.map(\.fileName), ["11-001.png"])
        XCTAssertEqual(result.map(\.publicPath), ["/images/posts/2025/11-001.png"])
        XCTAssertEqual(try Data(contentsOf: result[0].fileURL), Self.tinyPNG)
    }

    func testPreviewImagesExcludesMissingFilesAndLimitsResultToThree() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("blog")
        let imageDirectory = root.appendingPathComponent("static/images/posts/2026")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        for index in 1...4 {
            try Self.tinyPNG.write(
                to: imageDirectory.appendingPathComponent("10-00\(index).png")
            )
        }
        let markdown = (1...5)
            .map { "![](/images/posts/2026/10-00\($0).png)" }
            .joined(separator: "\n")

        let result = BlogImageRepository(root: root).previewImages(in: markdown)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(
            result.map(\.publicPath),
            [
                "/images/posts/2026/10-001.png",
                "/images/posts/2026/10-002.png",
                "/images/posts/2026/10-003.png"
            ]
        )
        XCTAssertFalse(result.contains(where: { $0.publicPath.hasSuffix("10-005.png") }))
    }

    func testReferencedAndPreviewImagesRejectTraversalAndExternalSymlink() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("blog")
        let imageDirectory = root.appendingPathComponent("static/images/posts/2026")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let regularImage = imageDirectory.appendingPathComponent("regular.png")
        try Self.tinyPNG.write(to: regularImage)
        let outsideImage = temporary.appendingPathComponent("outside.png")
        try Self.tinyPNG.write(to: outsideImage)
        try FileManager.default.createSymbolicLink(
            at: imageDirectory.appendingPathComponent("external.png"),
            withDestinationURL: outsideImage
        )
        try FileManager.default.createSymbolicLink(
            at: imageDirectory.appendingPathComponent("internal.png"),
            withDestinationURL: regularImage
        )
        let markdown = """
        ![](/images/posts/2026/regular.png)
        ![](/images/../../outside.png)
        ![](/images/posts/2026/external.png)
        ![](/images/posts/2026/internal.png)
        """
        let repository = BlogImageRepository(root: root)

        let referenced = repository.referencedImages(in: markdown)
        let previews = repository.previewImages(in: markdown)

        XCTAssertEqual(
            referenced.map(\.publicPath),
            [
                "/images/posts/2026/internal.png",
                "/images/posts/2026/regular.png"
            ]
        )
        XCTAssertEqual(previews.map(\.publicPath), referenced.map(\.publicPath))
        XCTAssertTrue(referenced.allSatisfy { $0.fileURL.resolvingSymlinksInPath().path == regularImage.path })
    }

    func testReferencedAndPreviewImagesRejectExternalImagesDirectorySymlink() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("blog")
        let staticDirectory = root.appendingPathComponent("static")
        let outsideImages = temporary.appendingPathComponent("outside-images")
        try FileManager.default.createDirectory(at: staticDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideImages, withIntermediateDirectories: true)
        try Self.tinyPNG.write(to: outsideImages.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(
            at: staticDirectory.appendingPathComponent("images"),
            withDestinationURL: outsideImages
        )
        let markdown = "![](/images/outside.png)"
        let repository = BlogImageRepository(root: root)

        XCTAssertTrue(repository.referencedImages(in: markdown).isEmpty)
        XCTAssertTrue(repository.previewImages(in: markdown).isEmpty)
    }

    func testReferencedImagesAllowsRepositoryRootSelectedThroughSymlink() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let actualRoot = temporary.appendingPathComponent("actual-blog")
        let imageDirectory = actualRoot.appendingPathComponent("static/images/posts")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try Self.tinyPNG.write(to: imageDirectory.appendingPathComponent("internal.png"))
        let linkedRoot = temporary.appendingPathComponent("linked-blog")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: actualRoot)

        let result = BlogImageRepository(root: linkedRoot)
            .referencedImages(in: "![](/images/posts/internal.png)")

        XCTAssertEqual(result.map(\.publicPath), ["/images/posts/internal.png"])
        XCTAssertEqual(result.first?.fileURL.path, imageDirectory.appendingPathComponent("internal.png").path)
    }

    private static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}
