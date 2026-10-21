#!/bin/bash
# llm-ime: 友達などに配る DMG を作る（管理アプリ＝IME 本体入り・モデル・説明・ライセンス）。
#
#   tools/dist/make_dmg.sh            Developer ID で署名し、管理アプリと IME 本体と DMG を公証する（配布用）
#   tools/dist/make_dmg.sh --dev      開発用の署名のまま作る（この Mac で手順を試す用。他の Mac では動かない）
#   --skip-dmg-notarize               DMG 自体の公証を省く（中の管理アプリと IME 本体は公証する）
#   --base-url <url>                  アップデートの配信元を差し替える（確認用。既定は release.conf の REPO の GitHub Releases）
#
# 版は配信（release.sh）と同じ付け方（日付）。DMG から入れた管理アプリも、以後は配信でアップデートできる。
# モデルは ~/Library/Application Support/llm-ime/models から APFS の複製（容量を使わない）で集める。
# DMG は圧縮しない（4bit の重みはほとんど縮まないため）。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DEV=false
SKIP_DMG_NOTARIZE=false
BASE_URL=""
MODELS="${MODELS:-gemma4-e4b-ane gemma4-e2b-ane gemma4-12b-it-mlx gemma4-31b-it-mlx ruri-v3-30m-coreml}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev) DEV=true ;;
        --skip-dmg-notarize) SKIP_DMG_NOTARIZE=true ;;
        --base-url) BASE_URL="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

VERSION="${VERSION:-$(date +%Y.%m.%d)}"
BUILD="$(date +%Y%m%d%H%M)"
VOLNAME="Shizuku"
if [[ -n "$BASE_URL" ]]; then
    FEED="$BASE_URL/update.json"
else
    [[ -n "${REPO:-}" ]] || { echo "tools/dist/release.conf に REPO=<owner>/<name> を書く" >&2; exit 1; }
    FEED="https://github.com/$REPO/releases/latest/download/update.json"
fi

# 必須の埋め込みは MODELS を絞った試作でも入れる。複製・ビルドの前に、出典とライセンスまで確認する。
MODELS="$(python3 "$ROOT/tools/dist/dmg_models.py" validate "$MODEL_DIR" $MODELS)"

OUT="$ROOT/build/dist"
rm -rf "$OUT"
mkdir -p "$OUT"
setup_identity
build_update_key_tool "$OUT"
PUBLIC_KEY="$(signing_key | "$UPDATE_KEY" public)"

build_ime "$OUT" "$VERSION" "$BUILD"
build_manager "$OUT" "$VERSION" "$BUILD" "$FEED" "$PUBLIC_KEY"

# 中身を並べる（モデルは APFS の複製）
echo "== 中身を並べる"
STAGE="$OUT/stage"
PAYLOAD="$STAGE/.payload"
mkdir -p "$PAYLOAD/models" "$STAGE/ライセンス"
ditto "$OUT/$MANAGER_NAME" "$STAGE/$MANAGER_NAME"
for m in $MODELS; do
    # 必須の埋め込みは署名済みの管理アプリ内だけに置く（二重に同梱しない）。
    [[ "$m" == ruri-v3-30m-coreml ]] && continue
    cp -cR "$MODEL_DIR/$m" "$PAYLOAD/models/$m"
done
python3 "$ROOT/tools/dist/dmg_models.py" dmg-manifest "$PAYLOAD" "$VERSION" \
    "$STAGE/$MANAGER_NAME/Contents/Resources/ModelPayload" $MODELS

# ライセンス
LIC="$STAGE/ライセンス"
cp "$IME/LICENSE" "$LIC/azooKey-Desktop.txt"
cp "$ROOT/third_party/AzooKeyKanaKanjiConverter/LICENSE" "$LIC/AzooKeyKanaKanjiConverter.txt"
cp "$ROOT/third_party/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/LICENSE" "$LIC/azooKey_dictionary_storage.txt"
for d in "$IME/build/dd-signed/SourcePackages/checkouts"/*; do
    f="$(ls "$d"/LICENSE* 2>/dev/null | head -1)"
    [[ -n "$f" ]] && cp "$f" "$LIC/$(basename "$d").txt"
done
cp "$ROOT/tools/dist/MODELS_NOTICE.txt" "$LIC/モデルについて.txt"
cp "$ROOT/tools/dist/ruri-v3-LICENSE.txt" "$LIC/ruri-v3.txt"
cp "$ROOT/tools/dist/README.txt" "$STAGE/はじめにお読みください.txt"

# DMG（並べたフォルダから読み取り専用の形式で直接作る。作業中に要る空き容量は DMG と同じ大きさだけ。
#    読み書きできる形式だと、署名が DMG に埋め込まれず拡張属性に付き、配る途中で落ちる）
echo "== DMG を作る"
DMG="$OUT/Shizuku-$VERSION.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRO "$DMG"
# 拡張属性（Finder の情報など）が付いていると codesign が失敗する
xattr -c "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
rm -rf "$STAGE" "$OUT/Shizuku.xcarchive" "$OUT/update_key"
# DMG 自体も公証する（ダウンロードした DMG を開くときの確認を通すため）。大きいのでアップロードに時間がかかる
if ! $DEV && ! $SKIP_DMG_NOTARIZE; then
    echo "== DMG を公証（アップロードに時間がかかります）"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
ls -lh "$DMG"
echo "完成: $DMG"
