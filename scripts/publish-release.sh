#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

if (( $# != 1 )); then
  print -u2 "使い方: ./scripts/publish-release.sh 1.0.1"
  exit 2
fi

VERSION="${1#v}"
if [[ ! "$VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]; then
  print -u2 "バージョンは 1.0.1 のように指定してください。"
  exit 2
fi
TAG="v$VERSION"

if [[ "$(git branch --show-current)" != "main" ]]; then
  print -u2 "main ブランチに切り替えてください。"
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  print -u2 "未コミットの変更があります。先に確認してコミットしてください。"
  exit 1
fi
git fetch origin main --tags
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse refs/remotes/origin/main)" ]]; then
  print -u2 "ローカルの main と GitHub の main が一致しません。先に同期してください。"
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  print -u2 "タグ $TAG は既に存在します。"
  exit 1
fi

git tag -a "$TAG" -m "Paopei $VERSION"
if ! git push origin "refs/tags/$TAG"; then
  print -u2 "タグの送信に失敗しました。ローカルの $TAG を確認してから再試行してください。"
  exit 1
fi
print "タグ $TAG を送信しました。GitHub Actionsで署名・公証・公開を開始します。"
print "進行状況: https://github.com/nakajijapan/Paopei/actions/workflows/release-macos.yml"
