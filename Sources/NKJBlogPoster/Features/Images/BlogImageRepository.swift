import Foundation

struct BlogImageRepository: Sendable {
    let root: URL

    private static let acceptedExtensions = Set(["jpg", "jpeg", "png", "gif"])
    private static let maximumPreviewImageCount = 3

    func importImages(_ sourceURLs: [URL], articleDate: Date) throws -> [BlogImage] {
        try importImages(sourceURLs.map(BlogImageInput.file), articleDate: articleDate)
    }

    func importImages(_ inputs: [BlogImageInput], articleDate: Date) throws -> [BlogImage] {
        guard !inputs.isEmpty else { return [] }

        let unsupported = inputs.compactMap { input -> String? in
            switch input {
            case .file(let url):
                return Self.acceptedExtensions.contains(url.pathExtension.lowercased())
                    ? nil
                    : url.lastPathComponent
            case .data(_, let fileExtension):
                return Self.acceptedExtensions.contains(fileExtension.lowercased())
                    ? nil
                    : ".\(fileExtension)"
            }
        }
        guard unsupported.isEmpty else {
            throw AppError.imageImport(
                "対応していない画像形式です: \(unsupported.joined(separator: "、"))\nJPG、JPEG、PNG、GIFを選択してください。"
            )
        }

        let year = Self.yearFormatter.string(from: articleDate)
        let month = Self.monthFormatter.string(from: articleDate)
        let directory = root
            .appendingPathComponent("static/images/posts", isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var nextIndex = try nextAvailableIndex(in: directory, month: month)
        guard nextIndex + inputs.count - 1 <= 999 else {
            throw AppError.imageImport("\(year)年\(month)月の画像連番が上限999を超えます。")
        }

        var createdURLs: [URL] = []
        var imported: [BlogImage] = []
        do {
            for input in inputs {
                let extensionName: String
                switch input {
                case .file(let source):
                    extensionName = normalizedExtension(source.pathExtension)
                case .data(let data, let fileExtension):
                    guard !data.isEmpty else {
                        throw AppError.imageImport("クリップボードの画像データが空です。")
                    }
                    extensionName = normalizedExtension(fileExtension)
                }
                let fileName = String(format: "%@-%03d.%@", month, nextIndex, extensionName)
                let destination = directory.appendingPathComponent(fileName)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw AppError.imageImport("保存先に同名ファイルがあります: \(fileName)")
                }

                switch input {
                case .file(let source):
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue else {
                        throw AppError.imageImport("画像ファイルを読み込めません: \(source.lastPathComponent)")
                    }
                    let didAccess = source.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { source.stopAccessingSecurityScopedResource() }
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                case .data(let data, _):
                    try data.write(to: destination, options: .atomic)
                }
                createdURLs.append(destination)
                imported.append(
                    BlogImage(
                        fileURL: destination,
                        publicPath: "/images/posts/\(year)/\(fileName)"
                    )
                )
                nextIndex += 1
            }
        } catch {
            for url in createdURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return imported
    }

    func referencedImages(in markdown: String) -> [BlogImage] {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let imagesDirectory = root
            .appendingPathComponent("static/images", isDirectory: true)
            .standardizedFileURL
        let resolvedImagesDirectory = imagesDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(resolvedImagesDirectory, of: resolvedRoot) else { return [] }

        return FrontMatterParser.imagePaths(in: markdown).compactMap { path in
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let candidate = root
                .appendingPathComponent("static", isDirectory: true)
                .appendingPathComponent(normalized)
                .standardizedFileURL
            guard Self.isDescendant(candidate, of: imagesDirectory) else { return nil }

            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isDescendant(resolvedCandidate, of: resolvedImagesDirectory),
                  Self.isDescendant(resolvedCandidate, of: resolvedRoot) else { return nil }

            return BlogImage(
                fileURL: resolvedCandidate,
                publicPath: path.hasPrefix("/") ? path : "/" + path
            )
        }
    }

    func previewImages(in markdown: String) -> [BlogImage] {
        Array(
            referencedImages(in: markdown)
                .filter(\.exists)
                .prefix(Self.maximumPreviewImageCount)
        )
    }

    private func nextAvailableIndex(in directory: URL, month: String) throws -> Int {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let expression = try NSRegularExpression(
            pattern: "^\(NSRegularExpression.escapedPattern(for: month))-(\\d{2,3})\\.(?:jpe?g|png|gif)$",
            options: [.caseInsensitive]
        )
        let maximum = names.compactMap { name -> Int? in
            let range = NSRange(name.startIndex..., in: name)
            guard let match = expression.firstMatch(in: name, range: range),
                  let indexRange = Range(match.range(at: 1), in: name) else { return nil }
            return Int(name[indexRange])
        }.max() ?? 0
        return maximum + 1
    }

    private func normalizedExtension(_ value: String) -> String {
        value.lowercased() == "jpeg" ? "jpg" : value.lowercased()
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        candidate.path.hasPrefix(directory.path + "/")
    }

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "MM"
        return formatter
    }()
}
