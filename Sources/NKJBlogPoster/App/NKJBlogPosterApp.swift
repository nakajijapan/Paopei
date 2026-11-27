import SwiftUI

@main
struct NKJBlogPosterApp: App {
    @StateObject private var model: AppModel
    #if !SWIFT_PACKAGE
    @State private var updateManager: UpdateManager
    @NSApplicationDelegateAdaptor(UpdateTerminationDelegate.self) private var updateTerminationDelegate
    #endif

    init() {
        let model = AppModel(deferAPIKeyStatusRefresh: true)
        _model = StateObject(wrappedValue: model)
        #if !SWIFT_PACKAGE
        _updateManager = State(initialValue: UpdateManager(model: model))
        #endif
    }

    var body: some Scene {
        WindowGroup("Paopei") {
            ContentView()
                .environmentObject(model)
                #if !SWIFT_PACKAGE
                .environment(updateManager)
                .task {
                    updateTerminationDelegate.updateManager = updateManager
                    updateManager.start()
                }
                #endif
                .task {
                    // A protected Keychain read can block the main actor while it
                    // waits for system authentication. Load the article list
                    // first; AI settings refresh the key status when opened.
                    model.loadInBackground()
                }
                .frame(minWidth: 1_500, minHeight: 900)
        }
        .defaultSize(width: 1_600, height: 1_000)
        .commands {
            #if !SWIFT_PACKAGE
            CommandGroup(after: .appInfo) {
                Button("アップデートを確認…") { updateManager.checkForUpdates() }
                    .disabled(!updateManager.canCheckForUpdates)
            }
            #endif

            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    do { try model.save() } catch { model.present(error) }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.selectedPost == nil || !model.isDirty)
            }

            CommandGroup(after: .newItem) {
                Button("新規記事") { model.showingNewPost = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Button("検索…") {
                    ArticleSearchCommand.focus()
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(after: .appSettings) {
                SettingsLink {
                    Text("設定を開く")
                }
                .keyboardShortcut(",", modifiers: .control)
            }
        }

        Settings {
            AppSettingsView()
                .environmentObject(model)
        }
    }
}

/// Routes the workspace-wide Find command to the article-list search field.
enum ArticleSearchCommand {
    static let focusNotification = Notification.Name("NKJBlogPoster.focusArticleSearch")

    static func focus() {
        NotificationCenter.default.post(name: focusNotification, object: nil)
    }
}
