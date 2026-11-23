import CryptoKit
import Foundation
import SQLite3

/// A disposable local cache of post metadata. Markdown files remain the source of truth.
struct SQLitePostIndex: Sendable {
    private static let schemaVersion = "1"

    let root: URL
    let cacheURL: URL

    init(root: URL, cacheDirectory: URL? = nil) {
        let standardizedRoot = root.standardizedFileURL
        self.root = standardizedRoot
        let directory = cacheDirectory ?? Self.defaultCacheDirectory()
        cacheURL = directory.appendingPathComponent("\(Self.cacheIdentifier(for: standardizedRoot.path)).sqlite")
    }

    func synchronize() throws -> [BlogPost] {
        do {
            return try synchronizeUsingCache()
        } catch is SQLitePostIndexError {
            try? resetCache()
            return try synchronizeUsingCache()
        }
    }

    private func synchronizeUsingCache() throws -> [BlogPost] {
        let snapshots = try fileSnapshots()
        let database = try SQLitePostIndexDatabase(url: cacheURL)
        try database.prepare(for: root.path, schemaVersion: Self.schemaVersion)
        let cached = try database.records()
        let imageRepository = BlogImageRepository(root: root)
        var posts: [BlogPost] = []
        var seen = Set<String>()

        try database.beginTransaction()
        do {
            for snapshot in snapshots {
                seen.insert(snapshot.relativePath)
                let record: SQLitePostIndexRecord
                if let cachedRecord = cached[snapshot.relativePath], cachedRecord.matches(snapshot) {
                    record = cachedRecord
                } else {
                    let markdown = try BlogRepository.readText(at: snapshot.url)
                    let frontMatter = FrontMatterParser.parse(markdown)
                    record = SQLitePostIndexRecord(
                        relativePath: snapshot.relativePath,
                        modificationMilliseconds: snapshot.modificationMilliseconds,
                        fileSize: snapshot.fileSize,
                        title: frontMatter.title,
                        date: frontMatter.date ?? snapshot.modificationDate,
                        isDraft: frontMatter.isDraft,
                        category: frontMatter.category,
                        slug: frontMatter.slug,
                        previewPaths: imageRepository.previewImages(in: markdown).map(\.publicPath)
                    )
                    try database.upsert(record)
                }
                posts.append(record.post(root: root))
            }

            try database.delete(paths: Set(cached.keys).subtracting(seen))
            try database.commit()
        } catch {
            database.rollback()
            throw error
        }

        return posts.sorted {
            ($0.date ?? .distantPast, $0.title) > ($1.date ?? .distantPast, $1.title)
        }
    }

    /// Updates one already-written Markdown file. Cache failures must never make saving Markdown fail.
    func update(url: URL, markdown: String) throws {
        let snapshot = try fileSnapshot(at: url)
        let frontMatter = FrontMatterParser.parse(markdown)
        let record = SQLitePostIndexRecord(
            relativePath: snapshot.relativePath,
            modificationMilliseconds: snapshot.modificationMilliseconds,
            fileSize: snapshot.fileSize,
            title: frontMatter.title,
            date: frontMatter.date ?? snapshot.modificationDate,
            isDraft: frontMatter.isDraft,
            category: frontMatter.category,
            slug: frontMatter.slug,
            previewPaths: BlogImageRepository(root: root).previewImages(in: markdown).map(\.publicPath)
        )
        let database = try SQLitePostIndexDatabase(url: cacheURL)
        try database.prepare(for: root.path, schemaVersion: Self.schemaVersion)
        try database.upsert(record)
    }

    private var postsDirectory: URL {
        root.appendingPathComponent("content/posts", isDirectory: true).standardizedFileURL
    }

    private func fileSnapshots() throws -> [SQLitePostFileSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: postsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { element -> SQLitePostFileSnapshot? in
            guard let url = element as? URL,
                  ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
                return nil
            }
            return try fileSnapshot(at: url)
        }
    }

    private func fileSnapshot(at url: URL) throws -> SQLitePostFileSnapshot {
        let standardizedURL = url.standardizedFileURL
        let basePath = postsDirectory.path + "/"
        guard standardizedURL.path.hasPrefix(basePath) else {
            throw AppError.invalidRepository("content/posts の外にある記事はインデックス化できません。")
        }

        let values = try standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey
        ])
        guard values.isRegularFile == true else {
            throw AppError.invalidRepository("記事ファイルを読み込めません: \(standardizedURL.lastPathComponent)")
        }
        let modificationDate = values.contentModificationDate ?? .distantPast
        return SQLitePostFileSnapshot(
            url: standardizedURL,
            relativePath: String(standardizedURL.path.dropFirst(basePath.count)),
            modificationDate: modificationDate,
            modificationMilliseconds: Int64((modificationDate.timeIntervalSince1970 * 1_000).rounded()),
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    private static func defaultCacheDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NKJBlogPoster/ArticleIndex", isDirectory: true)
    }

    private static func cacheIdentifier(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func resetCache() throws {
        let fileManager = FileManager.default
        for url in [
            cacheURL,
            URL(fileURLWithPath: cacheURL.path + "-shm"),
            URL(fileURLWithPath: cacheURL.path + "-wal")
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

private struct SQLitePostFileSnapshot {
    let url: URL
    let relativePath: String
    let modificationDate: Date
    let modificationMilliseconds: Int64
    let fileSize: Int64
}

private struct SQLitePostIndexRecord {
    let relativePath: String
    let modificationMilliseconds: Int64
    let fileSize: Int64
    let title: String
    let date: Date?
    let isDraft: Bool
    let category: String
    let slug: String
    let previewPaths: [String]

    func matches(_ snapshot: SQLitePostFileSnapshot) -> Bool {
        modificationMilliseconds == snapshot.modificationMilliseconds && fileSize == snapshot.fileSize
    }

    func post(root: URL) -> BlogPost {
        let imagesDirectory = root.appendingPathComponent("static/images", isDirectory: true).standardizedFileURL
        let previewImages = previewPaths.compactMap { publicPath -> BlogImage? in
            guard publicPath.hasPrefix("/images/") else { return nil }
            let relativePath = String(publicPath.dropFirst())
            let fileURL = root
                .appendingPathComponent("static", isDirectory: true)
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            guard fileURL.path.hasPrefix(imagesDirectory.path + "/") else { return nil }
            return BlogImage(fileURL: fileURL, publicPath: publicPath)
        }
        return BlogPost(
            url: root.appendingPathComponent("content/posts", isDirectory: true)
                .appendingPathComponent(relativePath)
                .standardizedFileURL,
            title: title,
            date: date,
            isDraft: isDraft,
            category: category,
            slug: slug,
            previewImages: previewImages
        )
    }
}

private final class SQLitePostIndexDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, handle != nil else {
            defer { sqlite3_close(handle) }
            throw SQLitePostIndexError.open(message: Self.errorMessage(handle))
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func prepare(for rootPath: String, schemaVersion: String) throws {
        try execute("PRAGMA journal_mode=WAL;")
        try execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS posts (
            path TEXT PRIMARY KEY NOT NULL,
            modified_ms INTEGER NOT NULL,
            file_size INTEGER NOT NULL,
            title TEXT NOT NULL,
            date_seconds REAL,
            is_draft INTEGER NOT NULL,
            category TEXT NOT NULL,
            slug TEXT NOT NULL,
            preview_paths BLOB NOT NULL
        );
        """)

        let storedRoot = try metadataValue(for: "repository_path")
        let storedVersion = try metadataValue(for: "schema_version")
        guard storedRoot == rootPath, storedVersion == schemaVersion else {
            try execute("DELETE FROM posts;")
            try setMetadataValue(rootPath, for: "repository_path")
            try setMetadataValue(schemaVersion, for: "schema_version")
            return
        }
    }

    func records() throws -> [String: SQLitePostIndexRecord] {
        let statement = try prepareStatement("""
        SELECT path, modified_ms, file_size, title, date_seconds, is_draft, category, slug, preview_paths
        FROM posts;
        """)
        defer { sqlite3_finalize(statement) }

        var records: [String: SQLitePostIndexRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = Self.string(at: 0, in: statement),
                  let title = Self.string(at: 3, in: statement),
                  let category = Self.string(at: 6, in: statement),
                  let slug = Self.string(at: 7, in: statement),
                  let previewData = Self.data(at: 8, in: statement) else {
                continue
            }
            let paths = (try? JSONDecoder().decode([String].self, from: previewData)) ?? []
            let date: Date? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            records[path] = SQLitePostIndexRecord(
                relativePath: path,
                modificationMilliseconds: sqlite3_column_int64(statement, 1),
                fileSize: sqlite3_column_int64(statement, 2),
                title: title,
                date: date,
                isDraft: sqlite3_column_int(statement, 5) != 0,
                category: category,
                slug: slug,
                previewPaths: paths
            )
        }
        try checkStepResult(statement)
        return records
    }

    func upsert(_ record: SQLitePostIndexRecord) throws {
        let statement = try prepareStatement("""
        INSERT INTO posts (path, modified_ms, file_size, title, date_seconds, is_draft, category, slug, preview_paths)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            modified_ms = excluded.modified_ms,
            file_size = excluded.file_size,
            title = excluded.title,
            date_seconds = excluded.date_seconds,
            is_draft = excluded.is_draft,
            category = excluded.category,
            slug = excluded.slug,
            preview_paths = excluded.preview_paths;
        """)
        defer { sqlite3_finalize(statement) }

        try bind(record.relativePath, at: 1, in: statement)
        try bind(record.modificationMilliseconds, at: 2, in: statement)
        try bind(record.fileSize, at: 3, in: statement)
        try bind(record.title, at: 4, in: statement)
        if let date = record.date {
            try bind(date.timeIntervalSince1970, at: 5, in: statement)
        } else if sqlite3_bind_null(statement, 5) != SQLITE_OK {
            throw error()
        }
        if sqlite3_bind_int(statement, 6, record.isDraft ? 1 : 0) != SQLITE_OK { throw error() }
        try bind(record.category, at: 7, in: statement)
        try bind(record.slug, at: 8, in: statement)
        try bind(JSONEncoder().encode(record.previewPaths), at: 9, in: statement)
        try execute(statement)
    }

    func delete(paths: Set<String>) throws {
        guard !paths.isEmpty else { return }
        let statement = try prepareStatement("DELETE FROM posts WHERE path = ?;")
        defer { sqlite3_finalize(statement) }
        for path in paths {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(path, at: 1, in: statement)
            try execute(statement)
        }
    }

    func beginTransaction() throws { try execute("BEGIN IMMEDIATE;") }
    func commit() throws { try execute("COMMIT;") }
    func rollback() { try? execute("ROLLBACK;") }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepareStatement("SELECT value FROM metadata WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return Self.string(at: 0, in: statement)
        case SQLITE_DONE:
            return nil
        default:
            throw error()
        }
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        let statement = try prepareStatement("""
        INSERT INTO metadata (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, in: statement)
        try bind(value, at: 2, in: statement)
        try execute(statement)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func prepareStatement(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        return statement
    }

    private func execute(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func checkStepResult(_ statement: OpaquePointer?) throws {
        let result = sqlite3_errcode(handle)
        guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
        guard result == SQLITE_OK else { throw error() }
    }

    private func bind(_ value: Data, at index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), sqliteTransient) }
        guard result == SQLITE_OK else { throw error() }
    }

    private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw error() }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw error() }
    }

    private func error() -> SQLitePostIndexError {
        .operation(message: Self.errorMessage(handle))
    }

    private static func string(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func data(at index: Int32, in statement: OpaquePointer?) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static func errorMessage(_ handle: OpaquePointer?) -> String {
        guard let handle, let message = sqlite3_errmsg(handle) else { return "SQLiteデータベースを開けませんでした。" }
        return String(cString: message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum SQLitePostIndexError: LocalizedError {
    case open(message: String)
    case operation(message: String)

    var errorDescription: String? {
        switch self {
        case .open(let message), .operation(let message):
            return "記事インデックスを更新できませんでした: \(message)"
        }
    }
}
