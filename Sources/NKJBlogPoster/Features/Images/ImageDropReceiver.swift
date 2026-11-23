import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit drag destination that accepts both Finder file URLs and Photos file promises.
struct ImageDropReceiver: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onImageInputs: ([BlogImageInput]) -> Bool
    let onError: (Error) -> Void

    func makeNSView(context: Context) -> ImageDropReceiverView {
        let view = ImageDropReceiverView()
        view.onImageInputs = onImageInputs
        view.onError = onError
        view.onTargetedChanged = { isTargeted = $0 }
        return view
    }

    func updateNSView(_ view: ImageDropReceiverView, context: Context) {
        view.onImageInputs = onImageInputs
        view.onError = onError
        view.onTargetedChanged = { isTargeted = $0 }
    }
}

final class ImageDropReceiverView: NSView {
    var onImageInputs: (([BlogImageInput]) -> Bool)?
    var onError: ((Error) -> Void)?
    var onTargetedChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ImageDragPasteboardReader.readableDraggedTypes)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ImageDragPasteboardReader.canReadImages(from: sender.draggingPasteboard) else {
            return []
        }
        onTargetedChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ImageDragPasteboardReader.canReadImages(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetedChanged?(false)
        let pasteboard = sender.draggingPasteboard
        let inputs = ImageDragPasteboardReader.imageInputs(from: pasteboard)
        if !inputs.isEmpty {
            return onImageInputs?(inputs) ?? false
        }

        let receivers = ImageDragPasteboardReader.filePromiseReceivers(from: pasteboard)
        guard !receivers.isEmpty else { return false }
        ImageFilePromiseLoader.loadImages(from: receivers) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let promisedInputs):
                guard !promisedInputs.isEmpty else {
                    self.onError?(AppError.imageImport("Photosから画像データを読み込めませんでした。"))
                    return
                }
                _ = self.onImageInputs?(promisedInputs)
            case .failure(let error):
                self.onError?(error)
            }
        }
        return true
    }
}

enum ImageDragPasteboardReader {
    private static let acceptedFileExtensions = Set(["jpg", "jpeg", "png", "gif"])
    private static let encodedTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
        (NSPasteboard.PasteboardType(UTType.gif.identifier), "gif")
    ]

    static var readableDraggedTypes: [NSPasteboard.PasteboardType] {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier)
        ]
        let promiseTypes: [NSPasteboard.PasteboardType] = NSFilePromiseReceiver
            .readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) }
        return imageTypes + promiseTypes
    }

    static func canReadImages(from pasteboard: NSPasteboard) -> Bool {
        !imageInputs(from: pasteboard).isEmpty || !filePromiseReceivers(from: pasteboard).isEmpty
    }

    static func imageInputs(from pasteboard: NSPasteboard) -> [BlogImageInput] {
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []).compactMap { object -> URL? in
            guard let value = object as? NSURL else { return nil }
            return value as URL
        }.filter {
            acceptedFileExtensions.contains($0.pathExtension.lowercased())
        }
        if !fileURLs.isEmpty {
            return fileURLs.map(BlogImageInput.file)
        }

        for (type, fileExtension) in encodedTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return [.data(data, fileExtension: fileExtension)]
            }
        }
        return pngInput(from: NSImage(pasteboard: pasteboard)).map { [$0] } ?? []
    }

    static func filePromiseReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) ?? [])
            .compactMap { $0 as? NSFilePromiseReceiver }
    }

    static func loadPromisedImageInputs(
        from receivers: [NSFilePromiseReceiver],
        completion: @escaping (Result<[BlogImageInput], Error>) -> Void
    ) {
        ImageFilePromiseLoader.loadImages(from: receivers, completion: completion)
    }

    static func imageInput(fromPromisedFile url: URL) -> BlogImageInput? {
        let fileExtension = url.pathExtension.lowercased()
        if acceptedFileExtensions.contains(fileExtension),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return .data(data, fileExtension: fileExtension == "jpeg" ? "jpg" : fileExtension)
        }

        guard UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true,
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return pngInput(from: image)
    }

    private static func pngInput(from image: NSImage?) -> BlogImageInput? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]),
              !png.isEmpty else {
            return nil
        }
        return .data(png, fileExtension: "png")
    }
}

private enum ImageFilePromiseLoader {
    static func loadImages(
        from receivers: [NSFilePromiseReceiver],
        completion: @escaping (Result<[BlogImageInput], Error>) -> Void
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("NKJBlogPoster-Drop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        let state = FilePromiseLoadState(
            expectedReceiverCount: receivers.count,
            destination: destination,
            completion: completion
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: queue
            ) { url, error in
                state.receive(receiverID: ObjectIdentifier(receiver), url: url, error: error)
            }
        }
    }
}

final class FilePromiseLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedReceiverCount: Int
    private let destination: URL
    private let completion: (Result<[BlogImageInput], Error>) -> Void
    private var inputs: [BlogImageInput] = []
    private var completedReceivers = Set<ObjectIdentifier>()
    private var completed = false

    init(
        expectedReceiverCount: Int,
        destination: URL,
        completion: @escaping (Result<[BlogImageInput], Error>) -> Void
    ) {
        self.expectedReceiverCount = expectedReceiverCount
        self.destination = destination
        self.completion = completion
    }

    func receive(receiverID: ObjectIdentifier, url: URL, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        if let error {
            finish(.failure(error))
            return
        }
        if let input = ImageDragPasteboardReader.imageInput(fromPromisedFile: url) {
            inputs.append(input)
        }
        completedReceivers.insert(receiverID)
        if completedReceivers.count >= expectedReceiverCount {
            finish(.success(inputs))
        }
    }

    private func finish(_ result: Result<[BlogImageInput], Error>) {
        completed = true
        try? FileManager.default.removeItem(at: destination)
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}
