import Foundation

/// Owns background article-index access so a cancelled or repeated reload cannot open a second
/// SQLite writer while an earlier synchronization is still finishing.
actor PostLoader {
    private let queue = DispatchQueue(label: "net.nakajijapan.paopei.post-loader", qos: .userInitiated)

    func load(root: URL) async throws -> [BlogPost] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try BlogRepository(root: root).loadPosts()
                })
            }
        }
    }
}
