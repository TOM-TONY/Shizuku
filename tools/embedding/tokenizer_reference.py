"""ruri-v3 の tokenizer.json（公式、コミット固定）で、確かめ用の文を字句に分けた結果を JSON に書く（Swift の UnigramTokenizer と比べる）。

使い方: build/.venv-convert/bin/python tools/embedding/tokenizer_reference.py <model_dir> <out.json>
"""
import json
import os
import sys

from tokenizers import Tokenizer

SENTENCES = [
    "経費の申請をお願いします。",
    "お疲れさまです。来週の打ち合わせの件ですが、",
    "検索クエリ: 了解しました",
    "ANE の続き予測は E2B と E4B から選べる。",
    "🙏ありがとうございます！",
    "半角 space と全角　スペース、改行\nも含む",
    "𠮷野家で𩸽を食べた",
    "",
    "ｶﾀｶﾅとＡＢＣ１２３",
]


def main():
    model_dir, out = sys.argv[1], sys.argv[2]
    tokenizer = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
    rows = []
    for text in SENTENCES:
        encoded = tokenizer.encode(text, add_special_tokens=False)
        rows.append({"text": text, "ids": encoded.ids})
    with open(out, "w") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)
    print(f"wrote {len(rows)} sentences to {out}")


if __name__ == "__main__":
    main()
