# Paopei

[English](README.md) | 日本語

Hugoブログの記事を作成・編集し、プレビューや投稿ができるmacOSアプリです。記事は利用者のブログ内にMarkdown形式で保存します。Hugoとブログはアプリに同梱されません。

## 動作環境

- macOS 15以降、Xcode 26以降、Swift 6.2以降
- プレビューと投稿にはHugo、投稿にはGitが必要です。
- AIチャットにはOpenRouterのAPIキーとネットワーク接続が必要です。APIキーはmacOSのKeychainに保存されます。記事本文や会話は送信先へ渡されるため、秘密情報を入力しないでください。

## 開発

```sh
make test
make app
open dist/Paopei.app
```

実ブログを使わずに試す場合は、`examples/hugo-site`を別のフォルダへコピーし、アプリで選択してください。サンプルでは投稿できません。

## ブログの設定と投稿

現行版は`config.toml`、`content/posts`、公開先の`public`サブモジュールを持つHugoサイトに対応します。投稿前に`examples/publishing-profile.json`をHugoソース直下の`.paopei.json`へコピーし、利用者自身のリポジトリとブランチを設定してください。このファイルにAPIキーは書かないでください。

設定画面でHugoソースのフォルダを選択してください。投稿設定ファイルがない場合、投稿は実行されません。投稿前に設定ファイルと実際のGit remoteを確認してください。投稿はブログの生成、commit、pushを実行します。

## 配布

`make app`はローカル確認用のDebugビルドです。配布用のReleaseビルドにはDeveloper ID署名とAppleの公証が必要です。CI用の証明書や認証情報はGitHub Actionsのシークレットなどに設定し、リポジトリに保存しないでください。

`main` に修正を反映した後、`./scripts/publish-release.sh 1.0.1` のように実行すると、タグの作成・送信を行います。GitHub Actionsが署名、公証、インストーラーの作成と公開を実行します。ワークフローの実行状況はGitHub Actionsで確認できます。署名・公証に必要なシークレットの事前設定が必要です。

## ライセンス

MITライセンスです。詳細は `LICENSE` を参照してください。
