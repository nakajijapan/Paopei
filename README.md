# Paopei

English | [日本語](README.ja.md)

Paopei is a macOS app for creating, editing, previewing, and publishing Hugo blog posts. Posts are stored as Markdown in your own blog. Hugo and a blog are not bundled with the app.

## Requirements

- macOS 15 or later, Xcode 26 or later, and Swift 6.2 or later.
- Hugo is required for previews and publishing; Git is required for publishing.
- AI chat requires an OpenRouter API key and an internet connection. The API key is stored in the macOS Keychain. Post content and conversations are sent to the service, so do not enter sensitive information.

## Development

```sh
make test
make app
open dist/Paopei.app
```

To try the app without using your own blog, copy `examples/hugo-site` to another folder and select it in the app. The sample site cannot be used for publishing.

## Blog setup and publishing

The current version supports Hugo sites with `config.toml`, `content/posts`, and a `public` submodule for generated output. Before publishing, copy `examples/publishing-profile.json` to `.nkjblogposter.json` in the Hugo source root, then set your own repositories and branch. Do not put API keys in this file.

Select your Hugo source folder in the app settings. Publishing is disabled when the publishing profile is missing. Before publishing, check the profile and the actual Git remotes. Publishing builds the blog, commits changes, and pushes them.

## Distribution

`make app` creates a Debug build for local use. A Release build for distribution requires Developer ID signing and Apple notarization. Store CI certificates and credentials in GitHub Actions secrets or another secure location, not in the repository.

After changes have been merged into `main`, run `./scripts/publish-release.sh 1.0.1` to create and push a tag. GitHub Actions runs tests, signs and notarizes the app, creates the installer, and publishes the release. Check the workflow status in GitHub Actions. Signing and notarization secrets must be configured in advance.

Paopei checks GitHub Releases at launch and every six hours while it runs. An update card appears below the article list. Choose **再起動して更新** to save your current article and apply the update, or **あとで** to hide that version until the next launch. You can also check from **Paopei → アップデートを確認…**. Users of a version released before this feature must install the first update-enabled DMG manually.

Before the first update-enabled release, run Sparkle’s `generate_keys --account paopei-release`. Export its base64 seed with `generate_keys --account paopei-release -x <private-key-file>` and set the GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY` to the file’s contents. Keep the key in Keychain and retain a secure backup. Use the same key for subsequent releases because installed copies verify updates against its public key. The release workflow signs the notarized DMG and update feed with this key and publishes `appcast.xml` alongside the DMG.

## License

MIT License. See [LICENSE](LICENSE) for details.
