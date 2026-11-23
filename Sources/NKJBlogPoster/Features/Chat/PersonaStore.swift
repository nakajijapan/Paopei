import Foundation

struct PersonaStore {
    static let maximumLength = 2_000

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "chatPersona") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> String? {
        guard let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return String(value.prefix(Self.maximumLength))
    }

    func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maximumLength else {
            throw AppError.persona("人格設定は\(Self.maximumLength)文字以内にしてください。")
        }
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }
}
