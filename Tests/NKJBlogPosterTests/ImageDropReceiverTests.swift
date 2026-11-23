import AppKit
import Foundation
import XCTest
@testable import NKJBlogPoster

final class ImageDropReceiverTests: XCTestCase {
    func testPromisedSupportedImageIsCopiedIntoDataInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("photo.PNG")
        let data = Data([1, 2, 3])
        try data.write(to: source)

        XCTAssertEqual(
            ImageDragPasteboardReader.imageInput(fromPromisedFile: source),
            .data(data, fileExtension: "png")
        )
    }

    func testPromiseDragTypesIncludeFilePromiseTypes() {
        let registered = Set(ImageDragPasteboardReader.readableDraggedTypes.map(\.rawValue))
        XCTAssertTrue(
            NSFilePromiseReceiver.readableDraggedTypes.allSatisfy { registered.contains($0) }
        )
    }

    func testPromiseStateCompletesOnceForReceiverWithMultipleAdvertisedTypes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: source)
        let completion = expectation(description: "promise completion")
        let receiver = NSObject()
        let state = FilePromiseLoadState(
            expectedReceiverCount: 1,
            destination: directory
        ) { result in
            switch result {
            case .success(let inputs):
                XCTAssertEqual(inputs, [.data(Data([1, 2, 3]), fileExtension: "png")])
            case .failure(let error):
                XCTFail("Unexpected promise error: \(error)")
            }
            completion.fulfill()
        }

        state.receive(receiverID: ObjectIdentifier(receiver), url: source, error: nil)
        wait(for: [completion], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
