# 更新カードの確認

Xcode で [UpdateNoticeCard.swift](../Sources/NKJBlogPoster/Features/Updates/UpdateNoticeCard.swift) を開くと、通知なし・更新あり・ダウンロード中・失敗のプレビューを確認できます。

## 実アプリで新版を再現する

以下をリポジトリのルートから zsh で実行してください。別のバンドル ID と一時的な署名鍵を使い、コピーしたサンプルブログを開きます。検証用 DMG はローカルの HTTP サーバーで配布します。Python 3 が必要です。

```zsh
set -euo pipefail
make app

qa="$(mktemp -d "${TMPDIR:-/tmp}/paopei-update-qa.XXXXXX")"
qa_id="net.nakajijapan.paopei.update-qa.$(uuidgen | tr '[:upper:]' '[:lower:]')"
feed_url="http://localhost:18768"
sparkle_tools="$PWD/.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin"
mkdir -p "$qa/current" "$qa/image" "$qa/feed"
ditto examples/hugo-site "$qa/hugo-site"

keys="$(swift -e '
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
')"
seed="$(printf '%s\n' "$keys" | sed -n '1p')"
public_key="$(printf '%s\n' "$keys" | sed -n '2p')"

for fixture in current:1.0.1 image:1.0.2; do
  version="${fixture#*:}"
  app="$qa/${fixture%:*}/Paopei.app"
  ditto dist/Paopei.app "$app"
  info="$app/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$qa_id" "$info"
  plutil -replace CFBundleShortVersionString -string "$version" "$info"
  plutil -replace CFBundleVersion -string "$version" "$info"
  plutil -replace SUPublicEDKey -string "$public_key" "$info"
  plutil -replace SUFeedURL -string "$feed_url/appcast.xml" "$info"
  codesign --force --sign - "$app"
  codesign --verify --deep --strict "$app"
done

hdiutil create -srcfolder "$qa/image" -volname 'Paopei QA' -format UDZO "$qa/feed/Paopei-1.0.2.dmg"
printf '%s\n' "$seed" | "$sparkle_tools/generate_appcast" \
  --ed-key-file - --maximum-deltas 0 --download-url-prefix "$feed_url/" "$qa/feed"
printf '%s\n' "$seed" | "$sparkle_tools/sign_update" --ed-key-file - --verify "$qa/feed/appcast.xml"
unset seed keys

defaults write "$qa_id" sourceRepositoryPath -string "$qa/hugo-site"
python3 -m http.server 18768 --bind 127.0.0.1 --directory "$qa/feed" > "$qa/server.log" 2>&1 &
server_pid=$!
curl --fail --silent --show-error --retry 5 --retry-connrefused --output /dev/null "$feed_url/appcast.xml"
open -n "$qa/current/Paopei.app"
```

同じターミナルを使って、以下を確認します。

1. 記事一覧の下に v1.0.2 のカードが出ることを確認します。記事が多いブログでは一覧をスクロールして、カードの位置を確認します。
2. 「あとで」を押し、**Paopei → アップデートを確認…** を選びます。同じ版は表示されません。アプリを終了して `open -n "$qa/current/Paopei.app"` で起動し直すと、同じ版が再表示されます。
3. `mv "$qa/feed/Paopei-1.0.2.dmg" "$qa/"` で DMG を配布先から移し、カードの「再起動して更新」を押します。失敗メッセージと「もう一度試す」がカードに表示されます。
4. `mv "$qa/Paopei-1.0.2.dmg" "$qa/feed/"` で DMG を戻します。サンプル記事を編集し、「もう一度試す」を押します。進捗表示のあとに再起動し、サンプル記事に変更が保存されていることを確認します。`plutil -extract CFBundleShortVersionString raw "$qa/current/Paopei.app/Contents/Info.plist"` が `1.0.2` を返します。
5. 確認後に検証用アプリを終了し、同じターミナルで `kill "$server_pid"` を実行します。
