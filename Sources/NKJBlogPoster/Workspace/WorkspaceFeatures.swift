import Combine
import Foundation

/// State owned by the article-list and editor feature. File access itself stays in
/// `BlogRepository`; this type deliberately contains no I/O.
@MainActor
final class PostEditorFeature: ObservableObject {
    @Published var posts: [BlogPost] = []
    @Published var selectedPost: BlogPost?
    @Published var editorText = ""
    @Published var savedText = ""
    @Published var searchQuery = ""
    @Published var filter: PostFilter = .all
    @Published var sourcePath = ""
    @Published var isLoadingPosts = false
    @Published var editorSelectionRequest: EditorSelectionRequest?

    var isDirty: Bool { editorText != savedText }

    var filteredPosts: [BlogPost] {
        posts.filter { post in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .drafts: matchesFilter = post.isDraft
            case .published: matchesFilter = !post.isDraft
            }
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || post.title.localizedCaseInsensitiveContains(query)
                || post.slug.localizedCaseInsensitiveContains(query)
                || post.relativePath.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
        }
    }

    var postYearSections: [PostYearSection] {
        var postsByYear: [Int: [BlogPost]] = [:]
        var postsWithoutDate: [BlogPost] = []
        for post in filteredPosts {
            guard let date = post.date else {
                postsWithoutDate.append(post)
                continue
            }
            let year = Calendar.current.component(.year, from: date)
            postsByYear[year, default: []].append(post)
        }
        var sections = postsByYear.keys.sorted(by: >).map {
            PostYearSection(year: $0, posts: postsByYear[$0, default: []])
        }
        if !postsWithoutDate.isEmpty {
            sections.append(PostYearSection(year: nil, posts: postsWithoutDate))
        }
        return sections
    }
}

/// State owned by the AI assistant feature. Conversation history remains in memory
/// only and is scoped by the workspace coordinator to a selected article.
@MainActor
final class ChatFeature: ObservableObject {
    @Published var input = ""
    @Published var messages: [ChatMessage] = []
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionID: UUID?
    @Published var mode: ChatMode = .consultation
    @Published var webSearchEnabled = false
    @Published var proposal: ChatProposal?
    @Published var personaText = ""
    @Published var personaDraft = ""
    @Published var openRouterModelID = ""
    @Published var openRouterModels: [OpenRouterModel] = []
    @Published var apiKeyStatus: OpenRouterAPIKeyStatus = .missing
    @Published var isFetchingModels = false
    @Published var isSavingSettings = false
    @Published var settingsMessage: String?
    @Published var isGenerating = false
}

/// State owned by the image feature. The repositories and network client remain
/// adapters; the feature only represents user-visible import state.
@MainActor
final class ImageFeature: ObservableObject {
    @Published var isImporting = false
    @Published var referencedImages: [BlogImage] = []
    @Published var pendingRemoteImage: RemoteImageCandidate?
}

/// State owned by the explicit publication feature.
@MainActor
final class PublishFeature: ObservableObject {
    @Published var isPublishing = false
}
