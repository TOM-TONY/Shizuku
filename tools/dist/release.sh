#!/bin/bash
# llm-ime: アップデートを配信する（管理アプリ＋IME 本体の zip と update.json を作り、GitHub Releases に載せる）。
#
#   tools/dist/release.sh -m "変更点"              作るだけ（build/release/<版>/ に zip と update.json）
#   tools/dist/release.sh -m "変更点" --publish    作って GitHub Releases に載せる（release.conf の REPO）
#   tools/dist/release.sh --dev --base-url http://127.0.0.1:8765
#                                                  開発用の署名で、この Mac の http から配る形で作る（確認用）
#
# 配った管理アプリは https://github.com/<REPO>/releases/latest/download/update.json を見て、新しい版を入れる。
# リポジトリが非公開の間は、友達の Mac からは確認できない（公開すると届くようになる）。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV=false
PUBLISH=false
NOTES=""
BASE_URL=""
VERSION="${VERSION:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev) DEV=true ;;
        --publish) PUBLISH=true ;;
        -m) NOTES="$2"; shift ;;
        --base-url) BASE_URL="$2"; shift ;;
        --version) VERSION="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

BUILD="$(date +%Y%m%d%H%M)"
if [[ -z "$VERSION" ]]; then
    VERSION="$(date +%Y.%m.%d)"
    # 同じ日の 2 回目以降は .2, .3 …
    if $PUBLISH && gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
        n=2
        while gh release view "v$VERSION.$n" --repo "$REPO" >/dev/null 2>&1; do n=$((n + 1)); done
        VERSION="$VERSION.$n"
    fi
fi
ZIP_NAME="Shizuku-$VERSION.zip"
if [[ -n "$BASE_URL" ]]; then
    FEED="$BASE_URL/update.json"
    DOWNLOAD_URL="$BASE_URL/$ZIP_NAME"
else
    [[ -n "${REPO:-}" ]] || { echo "tools/dist/release.conf に REPO=<owner>/<name> を書く" >&2; exit 1; }
    FEED="https://github.com/$REPO/releases/latest/download/update.json"
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$ZIP_NAME"
fi
$PUBLISH && $DEV && { echo "--dev の版は配信しない" >&2; exit 1; }

OUT="$ROOT/build/release/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
setup_identity
build_update_key_tool "$OUT"
PUBLIC_KEY="$(signing_key | "$UPDATE_KEY" public)"

build_ime "$OUT" "$VERSION" "$BUILD"
build_manager "$OUT" "$VERSION" "$BUILD" "$FEED" "$PUBLIC_KEY"

echo "== zip と update.json"
ZIP="$OUT/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$OUT/$MANAGER_NAME" "$ZIP"
SIGNED="$(signing_key | "$UPDATE_KEY" sign "$ZIP" "$BUILD" "$DOWNLOAD_URL")"
python3 - "$OUT/update.json" "$VERSION" "$BUILD" "$DOWNLOAD_URL" "$NOTES" "$SIGNED" <<'EOF'
import json, sys
path, version, build, url, notes, signed = sys.argv[1:]
info = {"version": version, "build": int(build), "url": url, "minimumSystemVersion": "15.0", "notes": notes, **json.loads(signed)}
json.dump(info, open(path, "w"), ensure_ascii=False, indent=1)
EOF
cat "$OUT/update.json"
rm -rf "$OUT/Shizuku.xcarchive" "$OUT/update_key"

if $PUBLISH; then
    echo "== GitHub Releases に載せる（$REPO）"
    gh release create "v$VERSION" "$ZIP" "$OUT/update.json" --repo "$REPO" --title "$VERSION" --notes "${NOTES:-$VERSION}"
fi
echo "完成: $OUT"
