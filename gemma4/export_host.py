"""Swift 実行系（CPU 側）が使う表とトークナイザを書き出す。

出力（out_dir）:
  embed.f16      (V, C) fp16。埋め込み × √C（モデル入力 hidden の 1 行分がそのまま入る）
  ple.f16        (V, L·P) fp16。層ごとの追加埋め込み × √P（入力 ple_rows の 1 行分）
  tokenizer.bin  BPE の語彙と結合規則（形式は下の write_tokenizer を参照）
  host.json      形状・RoPE などの設定
どちらの表も mmap して使うトークンの行だけ読む前提（ple は E2B で 4.7GB）。
使い方: python gemma4/export_host.py models/hf-llm/gemma-4-E2B models/gemma4-e2b-host
"""
import json
import math
import os
import struct
import sys

import numpy as np
import torch
from safetensors import safe_open

sys.path.insert(0, os.path.dirname(__file__))
from ref_torch import PREFIX, Weights  # noqa: E402


def write_table(w, name, out_path, scale, rows_per_step=8192):
    with safe_open(w.index[name], "pt") as g:
        sl = g.get_slice(PREFIX + name)
        V, D = sl.get_shape()
        peak = 0.0
        with open(out_path, "wb") as f:
            for s in range(0, V, rows_per_step):
                x = sl[s:min(V, s + rows_per_step)].float() * scale
                peak = max(peak, float(x.abs().max()))
                f.write(x.numpy().astype(np.float16).tobytes())
    assert peak < 60000, f"{name}: fp16 に収まらない値 {peak}"
    print(f"{out_path}: {V}x{D} peak {peak:.2f}", flush=True)
    return V, D


def write_tokenizer(tok_path, out_path):
    """形式（すべてリトルエンディアン）:
      "G4TK" u32 版=1, u32 語彙数 V, u32 結合規則数 M
      語彙 V 個: u16 バイト長 + UTF-8
      結合規則 M 個（優先順）: u32 左 id, u32 右 id, u32 結合後 id
      u32 特殊トークン数 S, 特殊トークン id S 個
    """
    t = json.load(open(tok_path))
    m = t["model"]
    assert m["type"] == "BPE" and m["byte_fallback"]
    assert t["normalizer"] == {"type": "Replace", "pattern": {"String": " "}, "content": "▁"}
    vocab = m["vocab"]
    V = len(vocab)
    pieces = [None] * V
    for s, i in vocab.items():
        pieces[i] = s
    assert all(p is not None for p in pieces)
    merges = []
    for mg in m["merges"]:
        a, b = mg if isinstance(mg, list) else mg.split(" ", 1)
        merges.append((vocab[a], vocab[b], vocab[a + b]))
    specials = sorted(x["id"] for x in t["added_tokens"] if x.get("special"))
    with open(out_path, "wb") as f:
        f.write(b"G4TK" + struct.pack("<III", 1, V, len(merges)))
        for p in pieces:
            b = p.encode("utf-8")
            f.write(struct.pack("<H", len(b)) + b)
        f.write(np.asarray(merges, dtype="<u4").tobytes())
        f.write(struct.pack("<I", len(specials)) + np.asarray(specials, dtype="<u4").tobytes())
    print(f"{out_path}: vocab {V} merges {len(merges)} specials {len(specials)}", flush=True)


def main(model_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    cfg = json.load(open(f"{model_dir}/config.json"))
    c = cfg.get("text_config", cfg)
    w = Weights(model_dir)
    C, P, L = c["hidden_size"], c["hidden_size_per_layer_input"], c["num_hidden_layers"]
    write_tokenizer(f"{model_dir}/tokenizer.json", f"{out_dir}/tokenizer.bin")
    V, _ = write_table(w, "embed_tokens.weight", f"{out_dir}/embed.f16", math.sqrt(C))
    write_table(w, "embed_tokens_per_layer.weight", f"{out_dir}/ple.f16", math.sqrt(P))
    rp = c.get("rope_parameters") or {}
    sl, fu = rp.get("sliding_attention", {}), rp.get("full_attention", {})
    host = dict(
        vocab=V, hidden=C, layers=L, ple=P,
        head_dim_sliding=c["head_dim"], head_dim_full=c["global_head_dim"],
        rope_sliding=dict(theta=sl.get("rope_theta", 1e4), rotated=int(c["head_dim"] * sl.get("partial_rotary_factor", 1.0))),
        rope_full=dict(theta=fu.get("rope_theta", 1e6), rotated=int(c["global_head_dim"] * fu.get("partial_rotary_factor", 0.25))),
        bos=2, eos=[1, 106], pad=0, source=model_dir,
    )
    json.dump(host, open(f"{out_dir}/host.json", "w"), indent=1)
    print(json.dumps(host))


if __name__ == "__main__":
    main(*sys.argv[1:3])
