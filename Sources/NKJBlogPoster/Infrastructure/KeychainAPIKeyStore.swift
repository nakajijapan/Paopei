import Foundation
import Security

protocol APIKeyStoring: Sendable {
    func load() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
}

enum KeychainAPIKeyStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData
    case emptyAPIKey

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus:
            return "KeychainのAPIキーを操作できませんでした。"
        case .invalidData:
            return "KeychainのAPIキーを読み取れませんでした。"
        case .emptyAPIKey:
            return "空のAPIキーは保存できません。"
        }
    }
}

struct KeychainAPIKeyStore: APIKeyStoring {
    static let service = "net.nakajijapan.paopei.openrouter"
    static let account = "api-key"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainAPIKeyStoreError.invalidData
        }
        return value
    }

    func save(_ apiKey: String) throws {
        let data = try Self.encodedAPIKey(apiKey)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }

        var addition = baseQuery
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(addStatus)
        }
    }

    static func encodedAPIKey(_ apiKey: String) throws -> Data {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw KeychainAPIKeyStoreError.emptyAPIKey
        }
        guard let data = value.data(using: .utf8), !data.isEmpty else {
            throw KeychainAPIKeyStoreError.invalidData
        }
        return data
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }
}
