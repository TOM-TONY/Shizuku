#!/bin/bash
# GitHub Actions のビルドに渡す、アプリ同梱のモデルのアーカイブを作る（モデルを更新したときだけ使う）。
#   tools/dist/package_build_assets.sh <番号> <出力先ディレクトリ>
# 作ったファイルを build-assets-<番号> の Release へ載せ、表示された値を tools/dist/build-assets.conf へ書く。
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: package_build_assets.sh <番号> <出力先ディレクトリ>" >&2; exit 2; }
number="$1"
output="$2"
[[ "$number" =~ ^[0-9]+$ ]] || { echo "番号は数字で指定してください" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
resources="$root/third_party/Shizuku/Shizuku/Resources"
models="${MODEL_DIR:-$HOME/Library/Application Support/llm-ime/models}"
for path in "$resources/base_n5_lm" "$resources/gguf" "$resources/typo-lm" "$resources/zenz-ane" "$models/ruri-v3-30m-coreml"; do
    [[ -d "$path" ]] || { echo "見つかりません: $path" >&2; exit 1; }
done

file="shizuku-build-assets-$number.tar.gz"
mkdir -p "$output"
COPYFILE_DISABLE=1 tar -czf "$output/$file" --no-xattrs --no-mac-metadata \
    --exclude .git --exclude .gitattributes --exclude .DS_Store \
    -C "$(dirname "$resources")" Resources/base_n5_lm Resources/gguf Resources/typo-lm Resources/zenz-ane \
    -C "$(dirname "$models")" "$(basename "$models")/ruri-v3-30m-coreml" \
    -C "$root/tools/dist" MODELS_NOTICE.txt

echo "BUILD_ASSETS_TAG=\"build-assets-$number\""
echo "BUILD_ASSETS_FILE=\"$file\""
echo "BUILD_ASSETS_SHA256=\"$(shasum -a 256 "$output/$file" | cut -d' ' -f1)\""
