#!/bin/bash
# アプリに同梱するモデルを、固定した Release の添付ファイルから取得し、ビルドが読む場所へ置く。
# 内容は tools/dist/build-assets.conf のハッシュと一致するものだけを使う。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tools/dist/release.conf"
source "$root/tools/dist/build-assets.conf"
[[ -n "${REPO:-}" ]] || { echo "tools/dist/release.conf の REPO が空です" >&2; exit 1; }
[[ -n "${BUILD_ASSETS_TAG:-}" && -n "${BUILD_ASSETS_FILE:-}" && -n "${BUILD_ASSETS_SHA256:-}" ]] || {
    echo "tools/dist/build-assets.conf が未設定です（docs/release.md を参照）" >&2
    exit 1
}

model_dir="${MODEL_DIR:-$HOME/Library/Application Support/llm-ime/models}"
resources="$root/third_party/Shizuku/Shizuku/Resources"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shizuku-build-assets.XXXXXX")"
trap 'rm -rf "$work"' EXIT

gh release download "$BUILD_ASSETS_TAG" --repo "$REPO" --pattern "$BUILD_ASSETS_FILE" --dir "$work"
actual="$(shasum -a 256 "$work/$BUILD_ASSETS_FILE" | cut -d' ' -f1)"
[[ "$actual" == "$BUILD_ASSETS_SHA256" ]] || {
    echo "$BUILD_ASSETS_FILE のハッシュが build-assets.conf と一致しません" >&2
    exit 1
}

mkdir "$work/extracted"
tar -xzf "$work/$BUILD_ASSETS_FILE" -C "$work/extracted"
rm "$work/$BUILD_ASSETS_FILE"
mkdir -p "$resources" "$model_dir"
for name in base_n5_lm gguf typo-lm zenz-ane; do
    rm -rf "${resources:?}/$name"
    mv "$work/extracted/Resources/$name" "$resources/$name"
done
rm -rf "${model_dir:?}/ruri-v3-30m-coreml"
mv "$work/extracted/models/ruri-v3-30m-coreml" "$model_dir/ruri-v3-30m-coreml"
echo "同梱するモデルを用意しました: $BUILD_ASSETS_FILE"
