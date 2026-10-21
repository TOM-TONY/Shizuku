"""EmbeddingGemma 2（テキストだけ、270M）の公式の重み（safetensors）から、文の埋め込みの Core ML モデルを作る。

- 重みは引数のフォルダ（ダウンロードした公式のリポジトリ。コミットを固定）から読む。trust_remote_code は使わない
- テキストの部分だけを使う（画像・音声の符号器は読まない）。平均プーリング（プロンプトを含む）、MRL の先頭 dim 次元への切り詰め、
  L2 正規化までを 1 つのモデルにする。入力の長さは固定。出力の名前・入力の名前は ruri-v3 の変換（convert_ruri_coreml.py）と同じ
- 公式は fp16 を避けるよう書いている（あふれ・NaN）。ANE は fp16 なので、残差の流れを 1/resid_scale で計算する
  （RMSNorm は縮尺に依らないので、正規化の前後の値は変わらない。足し込むところだけを縮める）
- transformers の実装（fp32）と比べて、コサイン類似度を確かめる

使い方（リポジトリの外のフォルダから。ダウンロードしたフォルダの中のものを import しないように -I で）:
  build/.venv-convert/bin/python -I tools/embedding/convert_embeddinggemma2_coreml.py <model_dir> <out_dir>
      [--lengths 64] [--dim 256] [--resid-scale 1] [--stats] [--lut 0]
"""
import argparse
import json
import os
import time

import coremltools as ct
import numpy as np
import torch
from safetensors import safe_open
from tokenizers import Tokenizer

QUERY_PREFIX = "task: search result | query: "
DOCUMENT_PREFIX = "title: none | text: "

SENTENCES = [
    QUERY_PREFIX + "経費の申請をお願いします。",
    DOCUMENT_PREFIX + "今月の経費精算の締め切りは金曜日です。",
    "お疲れさまです。来週の打ち合わせの件ですが、",
    "変換の第 1 候補ではない表記を同じ場面で 2 回選ぶと、次からその表記を先に出します。",
    "了解しました",
    "ANE の続き予測は E2B と E4B から選べる。🙇‍♂️",
]

TEXT_PREFIX = "model.language_model."


def load_text_weights(model_dir):
    """model.safetensors からテキストの部分の重みだけを fp32 で読む（キーは language_model 以下の名前）"""
    weights = {}
    with safe_open(os.path.join(model_dir, "model.safetensors"), "pt") as f:
        keys = list(f.keys())
        prefix = next((p for p in (TEXT_PREFIX, "language_model.") if any(k.startswith(p) for k in keys)), None)
        if prefix is None:
            raise SystemExit("テキストの重みの接頭辞が見つかりません: " + ", ".join(sorted({k.split('.')[0] for k in keys})))
        for key in keys:
            if key.startswith(prefix):
                weights[key[len(prefix):]] = f.get_tensor(key).to(torch.float32)
    return weights


class PlainEmbeddingGemma2(torch.nn.Module):
    """EmbeddingGemma 2 のテキストの順伝播を、長さ固定・バッチ 1 の素直な PyTorch で書いたもの（重みは公式のもの）。
    長さ ≤ 窓（512）なので、局所注意と全体注意はマスクが同じ（どちらも双方向・パディングだけ隠す）。回転位置の cos/sin は定数"""

    def __init__(self, weights, config, length, dim, resid_scale=1.0, record=None):
        super().__init__()
        text = config["text_config"]
        self.w = {k: torch.nn.Parameter(v, requires_grad=False) for k, v in weights.items()}
        for k, v in self.w.items():
            self.register_parameter(k.replace(".", "__"), v)
        self.hidden = text["hidden_size"]
        self.heads = text["num_attention_heads"]
        self.layers = text["num_hidden_layers"]
        self.ple_dim = text["hidden_size_per_layer_input"]
        self.eps = text["rms_norm_eps"]
        self.length = length
        self.dim = dim
        self.resid_scale = resid_scale
        self.record = record
        self.layer_types = text["layer_types"]
        per_layer = text.get("per_layer_config") or {}
        self.head_dims = []
        self.kv_heads = []
        for index in range(self.layers):
            override = per_layer.get(f"{index:02d}", {})
            self.head_dims.append(override.get("head_dim", text["head_dim"]))
            self.kv_heads.append(override.get("num_key_value_heads", text["num_key_value_heads"]))
        positions = torch.arange(length, dtype=torch.float32)
        self.rope = {}
        for index in sorted(set(range(self.layers)), key=lambda i: i):
            key = (self.layer_types[index], self.head_dims[index])
            if key in self.rope:
                continue
            theta = text["rope_parameters"][self.layer_types[index]]["rope_theta"]
            head_dim = self.head_dims[index]
            inv_freq = 1.0 / (theta ** (torch.arange(0, head_dim, 2, dtype=torch.float32) / head_dim))
            freqs = torch.outer(positions, inv_freq)
            emb = torch.cat([freqs, freqs], dim=-1)
            name = f"rope_{key[0]}_{head_dim}"
            self.register_buffer(name + "_cos", emb.cos())
            self.register_buffer(name + "_sin", emb.sin())
            self.rope[key] = name
        # bf16 で丸めた √hidden（transformers と同じ）
        self.embed_scale = float(torch.tensor(self.hidden ** 0.5, dtype=torch.bfloat16).item())

    def p(self, key):
        return self.w[key]

    def rms(self, x, size, weight_key=None):
        """RMSNorm を LayerNorm([x, −x]) の前半で書く（平均が 0 になるので RMS で割るのと同じ。ANE の layer_norm に載る）。
        トレースで形の値（int）を作らないように、大きさは引数で渡す"""
        doubled = torch.cat([x, -x], dim=-1)
        normed = torch.nn.functional.layer_norm(doubled, (2 * size,), eps=self.eps)[..., :size]
        if weight_key is not None:
            normed = normed * self.p(weight_key)
        return normed

    def linear(self, x, key):
        return torch.nn.functional.linear(x, self.p(key + ".weight"))

    def note(self, name, x):
        if self.record is not None:
            self.record[name] = max(self.record.get(name, 0.0), float(x.detach().abs().max()))

    @staticmethod
    def rotate_half(x, half):
        return torch.cat([-x[..., half:], x[..., :half]], dim=-1)

    def forward(self, input_ids, attention_mask):
        s = self.resid_scale
        L, H = self.length, self.hidden
        embeds = torch.nn.functional.embedding(input_ids, self.p("embed_tokens.weight")) * self.embed_scale
        self.note("embeds", embeds)
        # PLE（投影だけ。トークンごとの表引きはない）。正規化の後なので縮尺に依らない
        ple = self.linear(embeds, "ple.per_layer_model_projection") * (H ** -0.5)
        ple = ple.view(1, L, self.layers, self.ple_dim)
        ple = self.rms(ple, self.ple_dim, "ple.per_layer_projection_norm.weight")
        mask_f = attention_mask.to(torch.float32)
        padding = (1.0 - mask_f)[:, None, None, :] * -1e4
        hidden = embeds / s
        for i in range(self.layers):
            pre = f"layers.{i}."
            head_dim, kv = self.head_dims[i], self.kv_heads[i]
            normed = self.rms(hidden, H, pre + "input_layernorm.weight")
            q = self.linear(normed, pre + "self_attn.q_proj").view(1, L, self.heads, head_dim).transpose(1, 2)
            k = self.linear(normed, pre + "self_attn.k_proj").view(1, L, kv, head_dim).transpose(1, 2)
            v = self.linear(normed, pre + "self_attn.v_proj").view(1, L, kv, head_dim).transpose(1, 2)
            q = self.rms(q, head_dim, pre + "self_attn.q_norm.weight")
            k = self.rms(k, head_dim, pre + "self_attn.k_norm.weight")
            v = self.rms(v, head_dim)
            name = self.rope[(self.layer_types[i], head_dim)]
            cos, sin = getattr(self, name + "_cos"), getattr(self, name + "_sin")
            q = q * cos + self.rotate_half(q, head_dim // 2) * sin
            k = k * cos + self.rotate_half(k, head_dim // 2) * sin
            if kv != self.heads:
                k = k.repeat_interleave(self.heads // kv, dim=1)
                v = v.repeat_interleave(self.heads // kv, dim=1)
            scores = torch.matmul(q, k.transpose(-1, -2))
            self.note(f"scores{i}", scores)
            scores = scores + padding
            attended = torch.matmul(torch.softmax(scores, dim=-1), v).transpose(1, 2).reshape(1, L, self.heads * head_dim)
            out = self.rms(self.linear(attended, pre + "self_attn.o_proj"), H, pre + "post_attention_layernorm.weight")
            hidden = hidden + out / s
            normed = self.rms(hidden, H, pre + "pre_feedforward_layernorm.weight")
            gate = torch.nn.functional.gelu(self.linear(normed, pre + "mlp.gate_proj"), approximate="tanh")
            mlp = self.linear(gate * self.linear(normed, pre + "mlp.up_proj"), pre + "mlp.down_proj")
            self.note(f"mlp{i}", mlp)
            hidden = hidden + self.rms(mlp, H, pre + "post_feedforward_layernorm.weight") / s
            # PLE の gate は正規化を通らずに残差を受ける（gelu は縮尺で変わる）ので、この入力だけ元の大きさに戻す
            g = torch.nn.functional.gelu(self.linear(hidden * s, pre + "ple_block.per_layer_input_gate"), approximate="tanh")
            mixed = self.linear(g * ple[:, :, i, :], pre + "ple_block.per_layer_projection")
            hidden = hidden + self.rms(mixed, H, pre + "ple_block.post_per_layer_input_norm.weight") / s
            scalar = self.p(pre + "layer_scalar") if (pre + "layer_scalar") in self.w else None
            if scalar is not None:
                hidden = hidden * scalar
            self.note(f"resid{i}", hidden * s)
        hidden = self.rms(hidden, H, "norm.weight")
        projected = self.linear(hidden, "embedding_projection")[..., : self.dim]
        pooled = (projected * mask_f[..., None]).sum(dim=1) / mask_f.sum(dim=1, keepdim=True)
        # CPU の fp16 では二乗和があふれて 0 になるので、先に最大の絶対値で割ってから単位長にする（向きは変わらない）
        pooled = pooled / (pooled.abs().amax(dim=-1, keepdim=True) + 1e-6)
        return pooled / torch.sqrt((pooled * pooled).sum(dim=-1, keepdim=True) + 1e-12)


def encode(tokenizer, text, length):
    ids = tokenizer.encode(text).ids[:length]
    mask = [1] * len(ids) + [0] * (length - len(ids))
    ids = ids + [0] * (length - len(ids))
    return np.array([ids], dtype=np.int32), np.array([mask], dtype=np.int32)


def reference_embeddings(model_dir, tokenizer, dim):
    """transformers の EmbeddingGemma2Model（fp32、テキストだけの入力）で、可変長のまま埋め込みを作る"""
    from transformers import AutoModel
    model = AutoModel.from_pretrained(model_dir, dtype=torch.float32)
    model.eval()
    out = []
    with torch.no_grad():
        for text in SENTENCES:
            ids = torch.tensor([tokenizer.encode(text).ids])
            hidden = model(input_ids=ids, attention_mask=torch.ones_like(ids)).last_hidden_state[0]
            pooled = hidden.mean(dim=0)[:dim]
            out.append((pooled / pooled.norm()).numpy())
    del model
    return np.stack(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model_dir")
    parser.add_argument("out_dir")
    parser.add_argument("--lengths", default="64")
    parser.add_argument("--dim", type=int, default=256)
    parser.add_argument("--resid-scale", type=float, default=1.0)
    parser.add_argument("--stats", action="store_true", help="fp32 での各所の最大値を表示する（fp16 であふれる所を探す）")
    parser.add_argument("--lut", type=int, default=0, help="一様なパレット化のビット数（0 なら fp16 のまま。k-means は scikit-learn が要るので使わない）")
    parser.add_argument("--skip-reference", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    config = json.load(open(os.path.join(args.model_dir, "config.json")))
    tokenizer = Tokenizer.from_file(os.path.join(args.model_dir, "tokenizer.json"))
    weights = load_text_weights(args.model_dir)
    print(f"テキストの重み {len(weights)} 個、{sum(v.numel() for v in weights.values()) / 1e6:.1f}M")
    reference = None if args.skip_reference else reference_embeddings(args.model_dir, tokenizer, args.dim)
    report = {"dim": args.dim, "resid_scale": args.resid_scale, "lut": args.lut, "lengths": {}}
    for length in [int(x) for x in args.lengths.split(",")]:
        record = {} if args.stats else None
        plain = PlainEmbeddingGemma2(weights, config, length, args.dim, args.resid_scale, record).eval()
        with torch.no_grad():
            plain_out = np.stack([plain(*map(torch.from_numpy, encode(tokenizer, t, length)))[0].numpy() for t in SENTENCES])
        if record is not None:
            worst = sorted(record.items(), key=lambda kv: -kv[1])[:12]
            print("fp32 の最大値（大きい順）:", ", ".join(f"{k}={v:.0f}" for k, v in worst))
            report["lengths"].setdefault(str(length), {})["max_abs"] = dict(worst)
        plain.record = None
        if reference is not None:
            cos_ref = (plain_out * reference).sum(-1)
            print(f"長さ {length}: 書き直し対 transformers のコサイン 最小 {cos_ref.min():.6f}")
            if cos_ref.min() < 0.999:
                raise SystemExit("書き直した順伝播が transformers と一致しません")
        example = encode(tokenizer, SENTENCES[0], length)
        with torch.no_grad():
            traced = torch.jit.trace(plain, tuple(map(torch.from_numpy, example)))
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input_ids", shape=(1, length), dtype=np.int32),
                    ct.TensorType(name="attention_mask", shape=(1, length), dtype=np.int32)],
            outputs=[ct.TensorType(name="embedding")],
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=ct.precision.FLOAT16,
        )
        if args.lut:
            from coremltools.optimize.coreml import OpPalettizerConfig, OptimizationConfig, palettize_weights
            op_config = OpPalettizerConfig(mode="uniform", nbits=args.lut, granularity="per_grouped_channel", group_size=16)
            mlmodel = palettize_weights(mlmodel, OptimizationConfig(global_config=op_config))
        suffix = f"-lut{args.lut}" if args.lut else ""
        path = os.path.join(args.out_dir, f"embeddinggemma2-text-d{args.dim}-l{length}{suffix}.mlpackage")
        mlmodel.save(path)
        entry = report["lengths"].setdefault(str(length), {})
        for units_name, units in [("cpu_and_ne", ct.ComputeUnit.CPU_AND_NE), ("cpu_and_gpu", ct.ComputeUnit.CPU_AND_GPU),
                                  ("cpu_only", ct.ComputeUnit.CPU_ONLY)]:
            loaded = ct.models.MLModel(path, compute_units=units)
            outs = np.stack([loaded.predict({"input_ids": a, "attention_mask": b})["embedding"][0]
                             for a, b in (encode(tokenizer, t, length) for t in SENTENCES)])
            finite = bool(np.isfinite(outs).all())
            cos_plain = (outs * plain_out).sum(-1) if finite else np.array([float("nan")])
            times = []
            for _ in range(30):
                start = time.perf_counter()
                loaded.predict({"input_ids": example[0], "attention_mask": example[1]})
                times.append((time.perf_counter() - start) * 1000)
            entry[units_name] = {"finite": finite, "min_cos_vs_fp32": float(np.nanmin(cos_plain)),
                                 "median_ms_python": float(np.median(times))}
            print(f"  {units_name}: 有限 {finite}・fp32 とのコサイン最小 {np.nanmin(cos_plain):.6f}・中央値 {np.median(times):.2f}ms")
        size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(path) for f in fs)
        entry["mlpackage_bytes"] = size
        print(f"  {path}: {size / 1e6:.1f}MB")
    json.dump(report, open(os.path.join(args.out_dir, f"convert-report-d{args.dim}-s{args.resid_scale:g}{'-lut' + str(args.lut) if args.lut else ''}.json"), "w"),
              ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
