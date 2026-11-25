import Foundation

/// Repository-local configuration required before publishing.
struct PublishingProfile: Decodable, Equatable {
    let sourceRepository: String
    let outputRepository: String
    let outputBranch: String

    static func load(from root: URL) throws -> Self {
        let current = root.appendingPathComponent(".paopei.json")
        let legacy = root.appendingPathComponent(".nkjblogposter.json")
        let file = FileManager.default.fileExists(atPath: current.path) ? current : legacy
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AppError.invalidRepository("投稿するには、Hugoソースに .paopei.json を作成して投稿先を設定してください。")
        }
        do {
            let profile = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            let repositoryPattern = #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#
            guard profile.sourceRepository.range(of: repositoryPattern, options: .regularExpression) != nil,
                  profile.outputRepository.range(of: repositoryPattern, options: .regularExpression) != nil,
                  profile.sourceRepository != profile.outputRepository,
                  ["main", "master"].contains(profile.outputBranch) else {
                throw AppError.invalidRepository("投稿設定は異なる2つの owner/repository と、公開ブランチ main または master を指定してください。")
            }
            return profile
        } catch {
            // A malformed file must never fall back to somebody else's publishing target.
            throw AppError.invalidRepository("\(file.lastPathComponent) を読み込めません。\n\(error.localizedDescription)")
        }
    }

    static func matches(remote: String, repository: String) -> Bool {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else if let url = URL(string: value),
                  ["https", "ssh"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.lowercased() == "github.com",
                  url.password == nil, url.query == nil, url.fragment == nil,
                  (url.scheme == "ssh" ? url.user == "git" : url.user == nil),
                  url.port == nil {
            path = String(url.path.dropFirst())
        } else {
            return false
        }
        let normalized = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        return normalized.caseInsensitiveCompare(repository) == .orderedSame
    }
}
