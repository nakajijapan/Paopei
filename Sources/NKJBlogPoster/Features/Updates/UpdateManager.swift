#if !SWIFT_PACKAGE
import AppKit
import Observation
import OSLog
import Sparkle

@MainActor
@Observable
final class UpdateManager {
    private(set) var state: UpdateNoticeState = .none
    private(set) var canCheckForUpdates = false

    private let model: AppModel
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Paopei", category: "Updates")
    private static let postponedBuildsKey = "PaopeiPostponedUpdateBuilds"

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var sessionObservation: NSKeyValueObservation?
    @ObservationIgnored private var discoveredVersion: UpdateVersion?
    @ObservationIgnored private var installing = false
    @ObservationIgnored private var installPreparedUpdate: (() -> Void)?

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
    }

    func start() {
        guard updater == nil,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32 else { return }

        let driver = SparkleUpdateDriver(manager: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)

        // The app owns the check schedule. Enable Sparkle's silent installer only for an explicit update.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
        } catch {
            logger.error("Could not start updater: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.updater = updater
        defaults.removeObject(forKey: Self.postponedBuildsKey)
        sessionObservation = updater.observe(\.sessionInProgress, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue == true, change.newValue == false else { return }
            Task { @MainActor [weak self] in self?.sessionEnded() }
        }

        checkForUpdates()
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                } catch {
                    break
                }
                guard let self else { return }
                self.checkForUpdates()
            }
        }
    }

    func checkForUpdates() {
        guard let updater, !updater.sessionInProgress, !installing else { return }
        discoveredVersion = nil
        canCheckForUpdates = false
        updater.checkForUpdateInformation()
    }

    func install() {
        let version: UpdateVersion
        switch state {
        case let .available(update), let .failed(update): version = update
        case .none, .downloading: return
        }

        state = .downloading(version)

        if let installPreparedUpdate {
            if mayRestart() { installPreparedUpdate() }
        } else {
            beginInstallation()
        }
    }

    func postpone() {
        guard case let .available(version) = state else { return }
        let builds = defaults.stringArray(forKey: Self.postponedBuildsKey) ?? []
        defaults.set(builds + [version.build], forKey: Self.postponedBuildsKey)
        state = .none
    }

    fileprivate func mayPerform(_ check: SPUUpdateCheck) -> Bool {
        if check == .updateInformation { return true }
        guard check == .updatesInBackground, installing else { return false }
        // Sparkle has selected its installer by this point. A later check must only probe.
        updater?.automaticallyDownloadsUpdates = false
        return true
    }

    fileprivate func shouldProceed(with item: SUAppcastItem, check: SPUUpdateCheck) -> Bool {
        guard item.signingValidationStatus == .succeeded,
              !item.isInformationOnlyUpdate,
              item.installationType == "application" else { return false }
        if check == .updateInformation { return true }

        guard installing, case let .downloading(requested) = state else { return false }
        let version = UpdateVersion(item)
        guard version.build == requested.build else {
            offer(version)
            return false
        }
        return true
    }

    fileprivate func found(_ item: SUAppcastItem) {
        if !installing { discoveredVersion = UpdateVersion(item) }
    }

    fileprivate func finishedProbe(error: (any Error)?) {
        if case .downloading = state { return }
        if let discoveredVersion {
            if case let .failed(version) = state, version.build == discoveredVersion.build { return }
            offer(discoveredVersion)
        } else if error == nil || isNoUpdate(error) {
            state = .none
        }
    }

    fileprivate func prepared(_ item: SUAppcastItem, install: @escaping () -> Void) -> Bool {
        guard installing, case let .downloading(version) = state, version.build == item.versionString else {
            return false
        }
        installPreparedUpdate = install
        if mayRestart() { install() }
        return true
    }

    fileprivate func mayRestart() -> Bool {
        guard let version = state.version else { return false }
        guard saveBeforeRestart() else {
            state = .failed(version)
            return false
        }
        state = .downloading(version)
        return true
    }

    fileprivate func canTerminate() -> Bool {
        guard installing, let version = state.version else { return true }
        if saveBeforeRestart() { return true }
        state = .failed(version)
        return false
    }

    private func beginInstallation() {
        guard let updater, !updater.sessionInProgress, !installing, case let .downloading(version) = state else {
            return
        }
        guard canReplaceApplication(), saveBeforeRestart() else {
            state = .failed(version)
            return
        }
        installing = true
        canCheckForUpdates = false
        updater.automaticallyDownloadsUpdates = true
        updater.checkForUpdatesInBackground()
    }

    private func sessionEnded() {
        guard let updater, !updater.sessionInProgress else { return }
        canCheckForUpdates = true
        if installing {
            updater.automaticallyDownloadsUpdates = false
            installing = false
            installPreparedUpdate = nil
            if case let .downloading(version) = state { state = .failed(version) }
        } else {
            beginInstallation()
        }
    }

    private func offer(_ version: UpdateVersion) {
        let builds = defaults.stringArray(forKey: Self.postponedBuildsKey) ?? []
        state = builds.contains(version.build) ? .none : .available(version)
    }

    private func canReplaceApplication() -> Bool {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let files = FileManager.default
        guard files.isWritableFile(atPath: bundleURL.path),
              files.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else { return false }

        // Sparkle must preserve the bundle owner. A writable, group-owned location
        // can still require authorization if the app belongs to a different user.
        let userID = geteuid()
        let attributes = try? files.attributesOfItem(atPath: bundleURL.path)
        let ownerID = attributes?[.ownerAccountID] as? NSNumber
        return userID == 0 || ownerID?.uint32Value == userID
    }

    private func saveBeforeRestart() -> Bool {
        guard !model.isImportingImages, !model.isPublishing else { return false }
        do {
            if model.isDirty { try model.save() }
            return true
        } catch {
            logger.error("Could not save before updating: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func isNoUpdate(_ error: (any Error)?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue
    }
}

@MainActor
final class UpdateTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var updateManager: UpdateManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (updateManager?.canTerminate() ?? true) ? .terminateNow : .terminateCancel
    }
}

private extension UpdateVersion {
    init(_ item: SUAppcastItem) {
        self.init(build: item.versionString, display: item.displayVersionString)
    }
}

@MainActor
private final class SparkleUpdateDriver: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    private weak var manager: UpdateManager?

    init(manager: UpdateManager) {
        self.manager = manager
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard manager?.mayPerform(updateCheck) == true else { throw CocoaError(.userCancelled) }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard manager?.shouldProceed(with: item, check: updateCheck) == true else { throw CocoaError(.userCancelled) }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        manager?.found(item)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: (any Error)?) {
        if check == .updateInformation { manager?.finishedProbe(error: error) }
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock install: @escaping () -> Void
    ) -> Bool {
        manager?.prepared(item, install: install) ?? false
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        manager?.mayRestart() ?? false
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool {
        false
    }

    // The card is the only interface. Decline any fallback to Sparkle's interactive installer.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.dismiss)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.skip) }
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { cancellation() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { cancellation() }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func dismissUpdateInstallation() {}
}
#endif
