import Foundation

struct BlogRepository {
    let root: URL
    private let fileManager = FileManager.default

    var postsDirectory: URL {
        root.appendingPathComponent("content/posts", isDirectory: true)
    }

    func validate() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.appendingPathComponent("config.toml").path),
              fileManager.fileExists(atPath: postsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppError.invalidRepository("Hugoソースとして認識できません。config.toml と content/posts が必要です。")
        }
    }

    func loadPosts() throws -> [BlogPost] {
        try validate()
        do {
            return try SQLitePostIndex(root: root).synchronize()
        } catch {
            // The index is only a cache. Keep the Markdown-only path available if it is unavailable or corrupt.
            return try loadPostsWithoutIndex()
        }
    }

    private func loadPostsWithoutIndex() throws -> [BlogPost] {
        let imageRepository = BlogImageRepository(root: root)
        guard let enumerator = fileManager.enumerator(
            at: postsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var posts: [BlogPost] = []
        for case let url as URL in enumerator {
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { continue }
            let markdown = try Self.readText(at: url)
            let frontMatter = FrontMatterParser.parse(markdown)
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            posts.append(
                BlogPost(
                    url: url,
                    title: frontMatter.title,
                    date: frontMatter.date ?? modified,
                    isDraft: frontMatter.isDraft,
                    category: frontMatter.category,
                    slug: frontMatter.slug,
                    previewImages: imageRepository.previewImages(in: markdown)
                )
            )
        }

        return posts.sorted {
            ($0.date ?? .distantPast, $0.title) > ($1.date ?? .distantPast, $1.title)
        }
    }

    func read(_ post: BlogPost) throws -> String {
        try Self.readText(at: post.url)
    }

    func save(_ markdown: String, to url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(postsDirectory.standardizedFileURL.path + "/") else {
            throw AppError.invalidRepository("content/posts の外には保存できません。")
        }
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Moves only the article Markdown file to the user's Trash. Referenced
    /// images are deliberately retained because they may be shared by articles.
    @discardableResult
    func moveToTrash(_ post: BlogPost) throws -> URL? {
        let postURL = post.url.standardizedFileURL
        guard postURL.path.hasPrefix(postsDirectory.standardizedFileURL.path + "/") else {
            throw AppError.invalidRepository("content/posts の外の記事は削除できません。")
        }

        var trashedURL: NSURL?
        try fileManager.trashItem(at: postURL, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }

    func createDraft(
        title: String,
        category: String,
        now: Date = Date(),
        bodyTemplate: String = ArticlePromptSettings.defaults.newArticleTemplate
    ) throws -> BlogPost {
        try validate()
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        let timestamp = Self.timestampFormatter.string(from: now)
        let slug = Self.slug(from: title, fallback: "post-\(Self.timeFormatter.string(from: now))")
        let yearDirectory = postsDirectory.appendingPathComponent(String(year), isDirectory: true)
        try fileManager.createDirectory(at: yearDirectory, withIntermediateDirectories: true)

        var url = yearDirectory.appendingPathComponent("\(timestamp)-\(slug).md")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = yearDirectory.appendingPathComponent("\(timestamp)-\(slug)-\(suffix).md")
            suffix += 1
        }

        let isoDate = Self.frontMatterDateFormatter.string(from: now)
        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let markdown = """
        ---
        title: "\(safeTitle)"
        date: \(isoDate)
        draft: true
        categories: \(category)
        slug: \(slug)
        ---

        \(bodyTemplate)
        """
        try save(markdown + "\n", to: url)
        return BlogPost(
            url: url,
            title: title,
            date: now,
            isDraft: true,
            category: category,
            slug: slug,
            previewImages: []
        )
    }

    static func slug(from title: String, fallback: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
        let lowered = folded.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                return Character(String(scalar))
            }
            return "-"
        }
        let value = String(allowed)
            .split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return value.isEmpty ? fallback : value
    }

    static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let shiftJIS = String(data: data, encoding: .shiftJIS) { return shiftJIS }
        return String(decoding: data, as: UTF8.self)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    private static let frontMatterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter
    }()
}
