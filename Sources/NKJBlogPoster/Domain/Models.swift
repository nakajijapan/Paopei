import Foundation

struct BlogPost: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let date: Date?
    let isDraft: Bool
    let category: String
    let slug: String
    let previewImages: [BlogImage]

    var id: URL { url }

    var relativePath: String {
        let components = url.pathComponents
        guard let contentIndex = components.lastIndex(of: "content") else {
            return url.lastPathComponent
        }
        return components[(contentIndex + 1)...].joined(separator: "/")
    }
}

enum PostFilter: String, CaseIterable, Identifiable {
    case all = "すべて"
    case drafts = "下書き"
    case published = "公開済み"

    var id: Self { self }
}

struct PostYearSection: Identifiable {
    let year: Int?
    let posts: [BlogPost]

    var id: Int? { year }

    var title: String {
        if let year {
            return "\(year)年"
        }
        return "日付未設定"
    }
}

enum ChatMode: String, CaseIterable, Identifiable, Sendable {
    case consultation = "相談"
    case edit = "記事を編集"

    var id: Self { self }
}

struct ChatMessage: Identifiable, Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    let text: String
    let citations: [WebCitation]

    init(id: UUID = UUID(), role: Role, text: String, citations: [WebCitation] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
    }
}

struct ChatDraftRequest: Sendable {
    let markdown: String
    let message: String
    let persona: String
    let mode: ChatMode
    let history: [ChatMessage]
    let webSearchEnabled: Bool
    let editingInstructions: String

    init(
        markdown: String,
        message: String,
        persona: String,
        mode: ChatMode,
        history: [ChatMessage],
        webSearchEnabled: Bool = false,
        editingInstructions: String = ArticlePromptSettings.defaults.editingInstructions
    ) {
        self.markdown = markdown
        self.message = message
        self.persona = persona
        self.mode = mode
        self.history = history
        self.webSearchEnabled = webSearchEnabled
        self.editingInstructions = editingInstructions
    }
}

struct ChatDraftResponse: Sendable, Equatable {
    let content: String
    let citations: [WebCitation]

    init(content: String, citations: [WebCitation] = []) {
        self.content = content
        self.citations = citations
    }
}

/// A fragment of displayed text received from the consultation mode's server-sent event stream.
struct ChatDraftStreamDelta: Sendable, Equatable {
    let content: String
    let citations: [WebCitation]

    init(content: String, citations: [WebCitation] = []) {
        self.content = content
        self.citations = citations
    }
}

struct WebCitation: Identifiable, Sendable, Equatable, Hashable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

struct OpenRouterModel: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let name: String
}

enum OpenRouterAPIKeyStatus: Sendable, Equatable {
    case configured
    case missing
    case keychainError
}

struct ChatProposal: Sendable, Equatable {
    let postURL: URL
    let baseMarkdown: String
    let markdown: String
}

/// A conversation scoped to one article. It stays in memory until the app exits to protect draft content.
struct ChatSession: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var proposal: ChatProposal?

    init(
        id: UUID = UUID(),
        title: String = "新しいチャット",
        messages: [ChatMessage] = [],
        proposal: ChatProposal? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.proposal = proposal
    }
}

struct PublishConfiguration: Sendable {
    let sourceRepository: URL
    let outputRepository: URL
    let postURL: URL
    let commitMessage: String
}

struct PublishReport: Sendable {
    let summary: String
    let log: String
}

struct BlogImage: Identifiable, Hashable, Sendable {
    let fileURL: URL
    let publicPath: String

    var id: String { publicPath }
    var markdown: String { "![](\(publicPath))" }
    var fileName: String { fileURL.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
}

enum BlogImageInput: Sendable, Equatable {
    case file(URL)
    case data(Data, fileExtension: String)
}

struct RemoteImageCandidate: Identifiable, Equatable {
    let imageURL: URL
    let sourcePageURL: URL?
    let insertion: ImageInsertion

    var id: String { imageURL.absoluteString }
}

enum ImageInsertion: Equatable {
    case append
    case replace(NSRange)
}

struct EditorSelectionRequest: Equatable {
    let id = UUID()
    let range: NSRange
}

enum AppError: LocalizedError {
    case invalidRepository(String)
    case invalidPost([String])
    case commandFailed(command: String, output: String)
    case modelUnavailable(String)
    case invalidChatProposal(String)
    case persona(String)
    case imageImport(String)
    case noSelection

    var errorDescription: String? {
        switch self {
        case .invalidRepository(let message), .modelUnavailable(let message),
             .invalidChatProposal(let message), .persona(let message), .imageImport(let message):
            return message
        case .invalidPost(let messages):
            return messages.joined(separator: "\n")
        case .commandFailed(let command, let output):
            return "\(command) に失敗しました。\n\(output)"
        case .noSelection:
            return "記事が選択されていません。"
        }
    }
}
