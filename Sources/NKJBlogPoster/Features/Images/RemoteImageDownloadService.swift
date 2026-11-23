import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RemoteImageDownloadError: LocalizedError, Equatable {
    case invalidURL
    case unsafeHost
    case invalidResponse
    case unsupportedContentType
    case tooLarge
    case invalidImage
    case timeout
    case network

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "画像のURLが不正です。HTTPSの公開URLだけを利用できます。"
        case .unsafeHost:
            return "ローカルネットワーク・プライベートアドレスの画像は取得できません。"
        case .invalidResponse:
            return "画像サーバーから有効な応答を受け取れませんでした。"
        case .unsupportedContentType:
            return "JPEG、PNG、GIF以外の画像は保存できません。"
        case .tooLarge:
            return "画像サイズが上限10MBを超えています。"
        case .invalidImage:
            return "取得した内容を画像として確認できませんでした。"
        case .timeout:
            return "画像の取得がタイムアウトしました。"
        case .network:
            return "画像を取得できませんでした。ネットワーク接続を確認してください。"
        }
    }
}

struct DownloadedRemoteImage: Sendable, Equatable {
    let data: Data
    let fileExtension: String
    let sourceURL: URL
}

/// Downloads a public image only after the user confirms it in the UI.
/// Redirects are deliberately not followed so a public URL cannot redirect into a local service.
struct RemoteImageDownloadService: Sendable {
    static let maximumBytes = 10 * 1_024 * 1_024
    static let timeout: TimeInterval = 15

    private let session: URLSession

    init(session: URLSession = RemoteImageDownloadService.makeSession()) {
        self.session = session
    }

    func download(_ url: URL) async throws -> DownloadedRemoteImage {
        try Self.validatePublicHTTPSURL(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw RemoteImageDownloadError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RemoteImageDownloadError.network
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let responseURL = response.url else {
            throw RemoteImageDownloadError.invalidResponse
        }
        try Self.validatePublicHTTPSURL(responseURL)
        guard data.count <= Self.maximumBytes else { throw RemoteImageDownloadError.tooLarge }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first
            .map { String($0).lowercased() }
        let fileExtension = try Self.imageExtension(contentType: contentType, data: data)
        return DownloadedRemoteImage(data: data, fileExtension: fileExtension, sourceURL: responseURL)
    }

    static func validatePublicHTTPSURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            throw RemoteImageDownloadError.invalidURL
        }
        guard !isPrivateOrLocal(host) else { throw RemoteImageDownloadError.unsafeHost }
    }

    static func imageExtension(contentType: String?, data: Data) throws -> String {
        let allowed: [String: String] = [
            "image/jpeg": "jpg",
            "image/png": "png",
            "image/gif": "gif"
        ]
        guard let contentType, let expectedExtension = allowed[contentType] else {
            throw RemoteImageDownloadError.unsupportedContentType
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let uti = CGImageSourceGetType(source) as String? else {
            throw RemoteImageDownloadError.invalidImage
        }
        let actualType = UTType(uti)
        let actualExtension: String?
        if actualType == .jpeg { actualExtension = "jpg" }
        else if actualType == .png { actualExtension = "png" }
        else if actualType == .gif { actualExtension = "gif" }
        else { actualExtension = nil }
        guard actualExtension == expectedExtension else {
            throw RemoteImageDownloadError.invalidImage
        }
        return expectedExtension
    }

    private static func isPrivateOrLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "0.0.0.0" { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (172, 16...31), (192, 168), (100, 64...127):
            return true
        default:
            return false
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": "NKJBlogPoster/1.0"]
        // The image source must remain exactly the URL the user reviewed.
        configuration.httpShouldUsePipelining = false
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
