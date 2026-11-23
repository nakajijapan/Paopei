import SwiftUI

@main
struct NKJBlogPosterApp: App {
    @StateObject private var model = AppModel(deferAPIKeyStatusRefresh: true)

    var body: some Scene {
        WindowGroup("Paopei") {
            ContentView()
                .environmentObject(model)
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
