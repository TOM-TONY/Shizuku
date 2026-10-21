#!/bin/zsh
# 変換した EmbeddingGemma 2（convert_embeddinggemma2_coreml.py の出力）を、ModelCatalog の形（embedding.json・tokenizer.json・
# tokenizer.bin・embedder.mlmodelc）のフォルダにする。tokenizer.bin は Gemma 4 の BPE（gemma4/export_host.py と同じ形式。
# Swift の GemmaEmbeddingTokenizer が読む）。tokenizer.json は字句分けの種類（BPE）を見分けるために置く
# 使い方: tools/embedding/package_embeddinggemma2.sh <元のモデルのフォルダ> <変換した .mlpackage> <長さ> <次元> <出力のフォルダ>
#           <source（リポジトリ@コミット）> [--no-prefix]
set -eu
src=$1; package=$2; length=$3; dimension=$4; out=$5; source=$6; prefix=${7:-}
root=${0:A:h:h:h}
python=$root/build/.venv-convert/bin/python
rm -rf "$out"; mkdir -p "$out"
work=$(mktemp -d)
xcrun coremlcompiler compile "$package" "$work" > /dev/null
mv "$work"/*.mlmodelc "$out/embedder.mlmodelc"
rm -rf "$work"
cp "$src/tokenizer.json" "$out/tokenizer.json"
cp "$src/README.md" "$out/README.md"
"$python" -I -c "import sys; sys.path.insert(0, sys.argv[1]); from export_host import write_tokenizer; write_tokenizer(sys.argv[2], sys.argv[3])" \
  "$root/gemma4" "$src/tokenizer.json" "$out/tokenizer.bin"
license=$(awk '/^---$/{n++; next} n==1 && /^license:/{print $2; exit}' "$src/README.md")
"$python" -I - "$out/embedding.json" "$length" "$dimension" "$source" "$license" "$prefix" <<'PY'
import json, sys
out, length, dimension, source, license, prefix = sys.argv[1:7]
use = prefix != "--no-prefix"
json.dump({
    "length": int(length), "dimension": int(dimension),
    "queryPrefix": "task: search result | query: " if use else "", "documentPrefix": "title: none | text: " if use else "",
    "source": source, "license": license,
}, open(out, "w"), ensure_ascii=False, indent=1)
PY
du -sh "$out"; cat "$out/embedding.json"
