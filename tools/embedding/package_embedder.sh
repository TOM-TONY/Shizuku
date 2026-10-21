#!/bin/zsh
# 変換した文の埋め込みのモデル（convert_ruri_coreml.py の出力）を、ModelCatalog の形（embedding.json・tokenizer.json・
# embedder.mlmodelc）のフォルダにする。置き場所（~/Library/Application Support/llm-ime/models）や DMG に入れるのは別の手順
# 使い方: tools/embedding/package_embedder.sh <元のモデルのフォルダ（build/models/ruri-v3-30m@…）> <変換した .mlpackage> <長さ>
#           <出力のフォルダ（build/embedding/ruri-v3-30m-coreml）> <source（リポジトリ@コミット）> [--prefix]
set -eu
src=$1; package=$2; length=$3; out=$4; source=$5; prefix=${6:-}
rm -rf "$out"; mkdir -p "$out"
work=$(mktemp -d)
xcrun coremlcompiler compile "$package" "$work" > /dev/null
mv "$work"/*.mlmodelc "$out/embedder.mlmodelc"
rm -rf "$work"
cp "$src/tokenizer.json" "$out/tokenizer.json"
dimension=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['hidden_size'])" "$src/config.json")
# ライセンス: 固定したコミットのモデルカード（README の先頭の license）
license=$(awk '/^---$/{n++; next} n==1 && /^license:/{print $2; exit}' "$src/README.md")
python3 - "$out/embedding.json" "$length" "$dimension" "$source" "$license" "$prefix" <<'PY'
import json, sys
out, length, dimension, source, license, prefix = sys.argv[1:7]
json.dump({
    "length": int(length), "dimension": int(dimension),
    "queryPrefix": "検索クエリ: " if prefix == "--prefix" else "", "documentPrefix": "検索文書: " if prefix == "--prefix" else "",
    "source": source, "license": license,
}, open(out, "w"), ensure_ascii=False, indent=1)
PY
du -sh "$out"; cat "$out/embedding.json"
