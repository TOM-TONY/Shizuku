"""ruri-v3（ModernBERT）の公式の重み（safetensors）から、文の埋め込みの Core ML モデルを作る（解析と学習 段階 B）。

- 重みは引数のフォルダ（ダウンロードした公式のリポジトリ。コミットを固定）から safetensors だけを読む。trust_remote_code は使わない
- 平均プーリング（sentence-transformers の設定と同じ）と L2 正規化までを 1 つのモデルにする。入力の長さは固定（64・128）
- 元の PyTorch の出力と比べて、コサイン類似度を確かめる（0.999 以上でなければ失敗にする）

使い方（リポジトリの外のフォルダから。ダウンロードしたフォルダの中のものを import しないように）:
  build/.venv-convert/bin/python tools/embedding/convert_ruri_coreml.py <model_dir> <out_dir> [--lengths 64,128] [--int8]
"""
import argparse
import json
import math
import os
import time

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

SENTENCES = [
    "検索クエリ: 経費の申請をお願いします。",
    "検索文書: 今月の経費精算の締め切りは金曜日です。",
    "お疲れさまです。来週の打ち合わせの件ですが、",
    "変換の第 1 候補ではない表記を同じ場面で 2 回選ぶと、次からその表記を先に出します。",
    "了解しました",
    "ANE の続き予測は E2B と E4B から選べる。",
]


class PlainModernBert(torch.nn.Module):
    """ModernBERT の順伝播を、変換しやすい素直な PyTorch で書いたもの（重みは公式のモデルのものをそのまま使う）。
    transformers の実装は注意のマスク・回転位置の作り方が coremltools で変換できない（new_ones・int など）ので、入力の長さを固定して
    回転位置の cos/sin と、局所注意の窓（前後 local_attention/2）を定数にする。結果は transformers の出力と比べて確かめる"""

    def __init__(self, model, length, raw_config):
        super().__init__()
        config = model.config
        self.model = model
        self.heads = config.num_attention_heads
        self.head_dim = config.hidden_size // config.num_attention_heads
        self.length = length
        # 回転位置・局所注意の値は、モデルの config.json から読む（transformers の版で config の持ち方が変わるので）
        self.global_every = raw_config["global_attn_every_n_layers"]
        positions = torch.arange(length, dtype=torch.float32)
        def rotary(theta):
            inv_freq = 1.0 / (theta ** (torch.arange(0, self.head_dim, 2, dtype=torch.float32) / self.head_dim))
            freqs = torch.outer(positions, inv_freq)
            emb = torch.cat([freqs, freqs], dim=-1)
            return emb.cos(), emb.sin()
        global_cos, global_sin = rotary(raw_config["global_rope_theta"])
        local_cos, local_sin = rotary(raw_config["local_rope_theta"])
        self.register_buffer("global_cos", global_cos)
        self.register_buffer("global_sin", global_sin)
        self.register_buffer("local_cos", local_cos)
        self.register_buffer("local_sin", local_sin)
        distance = (positions[:, None] - positions[None, :]).abs()
        self.register_buffer("window", (distance > raw_config["local_attention"] // 2).to(torch.float32) * -1e4)

    def rotate_half(self, x):
        # 形は決まっているので、トレースで形の値（int）を作らないように定数で切る
        half = self.head_dim // 2
        return torch.cat([-x[..., half:], x[..., :half]], dim=-1)

    def forward(self, input_ids, attention_mask):
        model = self.model
        hidden = model.embeddings.norm(model.embeddings.tok_embeddings(input_ids))
        padding = (1.0 - attention_mask.to(torch.float32))[:, None, None, :] * -1e4
        batch = 1
        for index, layer in enumerate(model.layers):
            is_global = index % self.global_every == 0
            cos, sin = (self.global_cos, self.global_sin) if is_global else (self.local_cos, self.local_sin)
            mask = padding if is_global else padding + self.window
            normed = layer.attn_norm(hidden)
            qkv = layer.attn.Wqkv(normed).view(batch, self.length, 3, self.heads, self.head_dim)
            q, k, v = qkv.permute(2, 0, 3, 1, 4)
            q = q * cos + self.rotate_half(q) * sin
            k = k * cos + self.rotate_half(k) * sin
            scores = torch.matmul(q, k.transpose(-1, -2)) / math.sqrt(self.head_dim) + mask
            attended = torch.matmul(torch.softmax(scores, dim=-1), v)
            attended = attended.transpose(1, 2).reshape(batch, self.length, self.heads * self.head_dim)
            hidden = hidden + layer.attn.Wo(attended)
            up, gate = layer.mlp.Wi(layer.mlp_norm(hidden)).chunk(2, dim=-1)
            hidden = hidden + layer.mlp.Wo(torch.nn.functional.gelu(up) * gate)
        return model.final_norm(hidden)


class Embedder(torch.nn.Module):
    def __init__(self, model, length=None, raw_config=None):
        super().__init__()
        self.model = model
        self.plain = PlainModernBert(model, length, raw_config) if length else None

    def forward(self, input_ids, attention_mask):
        if self.plain is not None:
            hidden = self.plain(input_ids, attention_mask)
        else:
            hidden = self.model(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1.0)
        return torch.nn.functional.normalize(pooled, p=2, dim=-1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model_dir")
    parser.add_argument("out_dir")
    parser.add_argument("--lengths", default="64,128")
    parser.add_argument("--int8", action="store_true")
    args = parser.parse_args()
    model_dir = os.path.abspath(args.model_dir)
    os.makedirs(args.out_dir, exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(model_dir, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(
        model_dir, local_files_only=True, trust_remote_code=False, use_safetensors=True, attn_implementation="eager",
        dtype=torch.float32,
    ).eval()
    embedder = Embedder(model).eval()
    with open(os.path.join(model_dir, "config.json")) as f:
        raw_config = json.load(f)

    for length in [int(x) for x in args.lengths.split(",")]:
        batch = tokenizer(SENTENCES, padding="max_length", truncation=True, max_length=length, return_tensors="pt")
        plain = Embedder(model, length, raw_config).eval()
        with torch.no_grad():
            reference = embedder(batch["input_ids"], batch["attention_mask"]).numpy()
            mine = np.concatenate([
                plain(batch["input_ids"][i:i + 1], batch["attention_mask"][i:i + 1]).numpy() for i in range(len(SENTENCES))
            ])
            agreement = min(float(np.dot(a, b)) for a, b in zip(mine, reference))
            print(f"plain ModernBERT vs transformers (length {length}): cosine min {agreement:.6f}")
            if agreement < 0.9999:
                raise SystemExit("the plain ModernBERT does not match transformers")
            example = (batch["input_ids"][:1], batch["attention_mask"][:1])
            traced = torch.jit.trace(plain, example, strict=False)
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="input_ids", shape=(1, length), dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=(1, length), dtype=np.int32),
            ],
            outputs=[ct.TensorType(name="embedding")],
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=ct.precision.FLOAT16,
            convert_to="mlprogram",
        )
        if args.int8:
            config = ct.optimize.coreml.OptimizationConfig(global_config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric"))
            mlmodel = ct.optimize.coreml.linear_quantize_weights(mlmodel, config=config)
        name = f"embedder-{length}{'-int8' if args.int8 else ''}.mlpackage"
        path = os.path.join(args.out_dir, name)
        mlmodel.save(path)

        # 元の出力と比べる・時間を測る（Python からの呼び出しを含む目安。正確な時間は Swift で測る）
        for units_name, units in [("ALL", ct.ComputeUnit.ALL), ("CPU_AND_NE", ct.ComputeUnit.CPU_AND_NE), ("CPU_ONLY", ct.ComputeUnit.CPU_ONLY)]:
            loaded = ct.models.MLModel(path, compute_units=units)
            cosines = []
            for i in range(len(SENTENCES)):
                out = loaded.predict({
                    "input_ids": batch["input_ids"][i:i + 1].numpy().astype(np.int32),
                    "attention_mask": batch["attention_mask"][i:i + 1].numpy().astype(np.int32),
                })["embedding"][0]
                cosines.append(float(np.dot(out, reference[i]) / (np.linalg.norm(out) * np.linalg.norm(reference[i]))))
            feed = {"input_ids": batch["input_ids"][:1].numpy().astype(np.int32), "attention_mask": batch["attention_mask"][:1].numpy().astype(np.int32)}
            for _ in range(5):
                loaded.predict(feed)
            times = []
            for _ in range(50):
                t0 = time.perf_counter()
                loaded.predict(feed)
                times.append((time.perf_counter() - t0) * 1000)
            times.sort()
            print(f"{name} {units_name}: cosine min {min(cosines):.5f}  median {times[len(times) // 2]:.2f}ms  p90 {times[int(len(times) * 0.9)]:.2f}ms")
            if min(cosines) < 0.999:
                raise SystemExit(f"cosine too low for {name} ({units_name}): {min(cosines)}")
        size = sum(os.path.getsize(os.path.join(root, f)) for root, _, files in os.walk(path) for f in files)
        print(f"{name}: {size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
