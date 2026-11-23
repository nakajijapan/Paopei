import Foundation

struct OpenRouterSettingsStore: @unchecked Sendable {
    static let defaultModelID = "z-ai/glm-5.3-flash"
    static let defaultModelName = "GLM 5.3 Flash"
    static let legacyDefaultModelID = "moonshotai/kimi-k3"
    static let migrationVersion = 1

    private let defaults: UserDefaults
    private let modelKey: String
    private let migrationKey: String

    init(
        defaults: UserDefaults = .standard,
        modelKey: String = "openRouterModelID",
        migrationKey: String = "openRouterModelIDMigrationVersion"
    ) {
        self.defaults = defaults
        self.modelKey = modelKey
        self.migrationKey = migrationKey
    }

    func modelID() -> String {
        migrateLegacyDefaultIfNeeded()
        guard let stored = defaults.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else {
            return Self.defaultModelID
        }
        return stored
    }

    func saveModelID(_ modelID: String) {
        // Record the migration before a user explicitly chooses Kimi K3 again.
        migrateLegacyDefaultIfNeeded()
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed.isEmpty ? Self.defaultModelID : trimmed, forKey: modelKey)
    }

    private func migrateLegacyDefaultIfNeeded() {
        guard defaults.integer(forKey: migrationKey) < Self.migrationVersion else { return }
        let stored = defaults.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stored == Self.legacyDefaultModelID {
            defaults.set(Self.defaultModelID, forKey: modelKey)
        }
        defaults.set(Self.migrationVersion, forKey: migrationKey)
    }
}
