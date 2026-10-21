"""Zenzai (GPT-2) を Apple Neural Engine 向けの構成に組み直し、Core ML に変換する。

ANE 向けの変更点（apple/ml-ane-transformers の方針に準拠）:
  - 隠れ状態は (B, C, 1, S) 配置。全結合層は 1x1 Conv2d。
  - 系列長 S は固定。因果マスクは定数として埋め込む。
    入力の後ろをパディングしても、因果マスクにより前の位置の出力は変わらない。
  - KV キャッシュは持たない（xsmall/small は小さいので毎回全位置を計算する）。

LayerNorm について:
  zenz の残差ストリームには 1 万超の外れ値があり、素直に二乗すると fp16 があふれる。
    native: (B,1,S,C) に並べ替えて F.layer_norm（Core ML の layer_norm 演算）を使う
    scaled: 入力を 1/LN_SCALE してから自前で正規化する（LayerNorm はスケール不変）

使い方:
  python zenz/ane_gpt2.py --model models/hf/zenz-v3.1-xsmall --seq 128 --ln native \
      --out models/zenz-v3.1-xsmall-s128.mlpackage

  # 複数の系列長を 1 つの mlpackage に（関数名 s128, s256。重みは共有される）
  python zenz/ane_gpt2.py --model ... --seqs 128,256 --out models/zenz-multi.mlpackage
"""
import argparse
import math

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from transformers import GPT2LMHeadModel

LN_SCALE = 256.0
# 注意機構の実装:
#   heads: (B,H,D,S) に reshape して einsum（初版）
#   split: apple/ml-ane-transformers 方式。ヘッドごとに split し、K を (B,S,1,D) にして einsum
#   block: クエリを ATTN_BLOCK ごとに分け、因果的に不要なキー（ブロック末尾より後）を計算しない
ATTN_BLOCK = 128
MASK_MIN = -1e4  # fp16 で表現でき、softmax 後に 0 になる値（safe_scores 使用時は -inf 相当を使う）
# 巨大な注意スコア対策（zenz-v2.5-medium の 2 層目は最大約 52 万に達し fp16 であふれる）。
# q, k を先に 1/SCORE_PRESCALE ずつ縮めて内積を取り（スコアは 1/SCORE_PRESCALE^2）、
# 行の最大値を引いてから元の大きさに戻して softmax する（softmax は定数シフト不変）。
# 戻す際に極端に小さい値は -inf になるが、softmax では 0 になるだけ。
SCORE_PRESCALE = 16.0


class LayerNormANE(nn.Module):
    def __init__(self, ln: nn.LayerNorm, mode: str, resid_scale: float = 1.0):
        super().__init__()
        self.mode = mode
        # 残差ストリームを 1/resid_scale して計算する場合、LayerNorm はスケール不変なので eps だけ合わせる
        self.eps = ln.eps / (resid_scale * resid_scale)
        self.weight = nn.Parameter(ln.weight.detach().clone())
        self.bias = nn.Parameter(ln.bias.detach().clone())

    def forward(self, x):  # x: (B, C, 1, S)
        if self.mode == "native":
            y = F.layer_norm(x.permute(0, 2, 3, 1), self.weight.shape, self.weight, self.bias, self.eps)
            return y.permute(0, 3, 1, 2)
        x = x * (1.0 / LN_SCALE)
        mean = x.mean(dim=1, keepdim=True)
        zm = x - mean
        var = (zm * zm).mean(dim=1, keepdim=True)
        y = zm * torch.rsqrt(var + self.eps / (LN_SCALE * LN_SCALE))
        return y * self.weight.view(1, -1, 1, 1) + self.bias.view(1, -1, 1, 1)


def conv_from_gpt2_conv1d(c) -> nn.Conv2d:
    """transformers の Conv1D（weight: [in, out]）を 1x1 Conv2d に変換する。"""
    w = c.weight.detach()
    conv = nn.Conv2d(w.shape[0], w.shape[1], kernel_size=1, bias=True)
    conv.weight.data = w.t().contiguous().view(w.shape[1], w.shape[0], 1, 1).clone()
    conv.bias.data = c.bias.detach().clone()
    return conv


class BlockANE(nn.Module):
    def __init__(self, blk, n_head: int, ln_mode: str, attn: str = "heads", resid_scale: float = 1.0,
                 safe_scores: bool = False):
        super().__init__()
        self.n_head = n_head
        self.attn = attn
        self.safe_scores = safe_scores
        self.ln_1 = LayerNormANE(blk.ln_1, ln_mode, resid_scale)
        self.c_attn = conv_from_gpt2_conv1d(blk.attn.c_attn)
        self.attn_proj = conv_from_gpt2_conv1d(blk.attn.c_proj)
        self.ln_2 = LayerNormANE(blk.ln_2, ln_mode, resid_scale)
        self.c_fc = conv_from_gpt2_conv1d(blk.mlp.c_fc)
        self.mlp_proj = conv_from_gpt2_conv1d(blk.mlp.c_proj)
        # 残差へ足し込む射影の出力も 1/resid_scale にする
        for proj in (self.attn_proj, self.mlp_proj):
            proj.weight.data /= resid_scale
            proj.bias.data /= resid_scale

    def attention_weights(self, equation: str, q, k, scale: float, mask, dim: int):
        """softmax(einsum(q, k) * scale + mask)。safe_scores なら fp16 であふれない手順で計算する。"""
        if not self.safe_scores:
            return (torch.einsum(equation, q, k) * scale + mask).softmax(dim=dim)
        p = SCORE_PRESCALE
        w = torch.einsum(equation, q * (scale / p), k * (1.0 / p)) + mask
        w = (w - w.amax(dim=dim, keepdim=True)) * (p * p)
        return w.softmax(dim=dim)

    def forward(self, x, mask):
        B, C, _, S = x.shape
        H = self.n_head
        D = C // H
        q, k, v = self.c_attn(self.ln_1(x)).split(C, dim=1)
        scale = 1.0 / math.sqrt(D)
        if self.attn == "split":
            # mask は (1, Sk, 1, Sq) 配置（ZenzANE.mask_t）
            outs = []
            for qi, ki, vi in zip(q.split(D, dim=1), k.transpose(1, 3).split(D, dim=3), v.split(D, dim=1)):
                w = self.attention_weights("bchq,bkhc->bkhq", qi, ki, scale, mask, dim=1)
                outs.append(torch.einsum("bkhq,bchk->bchq", w, vi))
            a = torch.cat(outs, dim=1)
        elif self.attn == "block":
            q = q.reshape(B, H, D, S)
            k = k.reshape(B, H, D, S)
            v = v.reshape(B, H, D, S)
            outs = []
            for q0 in range(0, S, ATTN_BLOCK):
                q1 = min(q0 + ATTN_BLOCK, S)
                w = self.attention_weights("bhdq,bhdk->bhqk", q[..., q0:q1], k[..., :q1], scale,
                                           mask[:, :, q0:q1, :q1], dim=-1)
                outs.append(torch.einsum("bhqk,bhdk->bhdq", w, v[..., :q1]))
            a = torch.cat(outs, dim=-1).reshape(B, C, 1, S)
        else:
            q = q.reshape(B, H, D, S)
            k = k.reshape(B, H, D, S)
            v = v.reshape(B, H, D, S)
            w = self.attention_weights("bhdq,bhdk->bhqk", q, k, scale, mask, dim=-1)
            a = torch.einsum("bhqk,bhdk->bhdq", w, v).reshape(B, C, 1, S)
        x = x + self.attn_proj(a)
        h = F.gelu(self.c_fc(self.ln_2(x)), approximate="tanh")
        return x + self.mlp_proj(h)


class ZenzANE(nn.Module):
    def __init__(self, hf: GPT2LMHeadModel, seq_len: int, ln_mode: str, attn: str = "heads",
                 resid_scale: float = 1.0, safe_scores: bool = False):
        super().__init__()
        self.attn = attn
        # 残差ストリームの外れ値が fp16 の上限（65504）を超えるモデル（zenz-v2.5-medium は約 9.6 万）向けに、
        # 残差全体を 1/resid_scale して計算する。LayerNorm のスケール不変性により出力は数学的に同一。
        self.resid_scale = resid_scale
        cfg = hf.config
        assert cfg.activation_function == "gelu_new"
        assert not cfg.scale_attn_by_inverse_layer_idx and not cfg.reorder_and_upcast_attn
        self.seq_len = seq_len
        self.wte = nn.Parameter(hf.transformer.wte.weight.detach().clone())  # (V, C)
        self.register_buffer("wpe", hf.transformer.wpe.weight.detach()[:seq_len].t().reshape(1, -1, 1, seq_len).clone() / resid_scale)
        self.blocks = nn.ModuleList(
            BlockANE(b, cfg.n_head, ln_mode, attn, resid_scale, safe_scores) for b in hf.transformer.h)
        self.ln_f = LayerNormANE(hf.transformer.ln_f, ln_mode, resid_scale)
        V, C = self.wte.shape
        self.lm_head = nn.Conv2d(C, V, kernel_size=1, bias=False)
        self.lm_head.weight.data = hf.lm_head.weight.detach().clone().view(V, C, 1, 1)
        # safe_scores ではスコアが 1/SCORE_PRESCALE^2 の段階（最大でも数千）でマスクする。
        # fp16 で表せない値（-inf 等）を使うと Core ML が fp32 のまま残して CPU 実行になるため、有限値にする。
        mask_min = -30000.0 if safe_scores else MASK_MIN
        causal = torch.full((seq_len, seq_len), mask_min).triu(1)
        self.register_buffer("mask", causal.view(1, 1, seq_len, seq_len))
        # split 方式用: (1, Sk, 1, Sq)
        self.register_buffer("mask_t", causal.t().contiguous().view(1, seq_len, 1, seq_len))

    def forward(self, input_ids):  # (1, S) int32
        x = F.embedding(input_ids.long(), self.wte)  # (1, S, C)
        if self.resid_scale != 1.0:
            x = x * (1.0 / self.resid_scale)
        x = x.permute(0, 2, 1).unsqueeze(2) + self.wpe  # (1, C, 1, S)
        mask = self.mask_t if self.attn == "split" else self.mask
        for blk in self.blocks:
            x = blk(x, mask)
        return self.lm_head(self.ln_f(x))  # (1, V, 1, S)


def build(model_dir: str, seq_len: int, ln_mode: str, attn: str = "heads", resid_scale: float = 1.0,
          safe_scores: bool = False) -> ZenzANE:
    hf = GPT2LMHeadModel.from_pretrained(model_dir, dtype=torch.float32).eval()
    return ZenzANE(hf, seq_len, ln_mode, attn, resid_scale, safe_scores).eval()


def convert(module: ZenzANE, out_path: str):
    import coremltools as ct

    S = module.seq_len
    example = torch.zeros((1, S), dtype=torch.int32)
    traced = torch.jit.trace(module, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, S), dtype=np.int32)],
        outputs=[ct.TensorType(name="logits", dtype=np.float16)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.short_description = f"zenz GPT-2 for ANE, seq_len={S}, logits layout (1, V, 1, S)"
    mlmodel.save(out_path)
    return mlmodel


def export_multifunction(model_dir: str, seqs, ln_mode: str, out_path: str, attn: str = "heads",
                         resid_scale: float = 1.0, safe_scores: bool = False):
    """系列長ごとの関数（s<seq>）を持つマルチファンクションモデルを書き出す。"""
    import os
    import shutil
    import tempfile

    import coremltools as ct

    tmp = tempfile.mkdtemp()
    desc = ct.utils.MultiFunctionDescriptor()
    for s in seqs:
        path = os.path.join(tmp, f"s{s}.mlpackage")
        convert(build(model_dir, s, ln_mode, attn, resid_scale, safe_scores), path)
        desc.add_function(path, src_function_name="main", target_function_name=f"s{s}")
    desc.default_function_name = f"s{seqs[0]}"
    if os.path.exists(out_path):
        shutil.rmtree(out_path)
    ct.utils.save_multifunction(desc, out_path)
    shutil.rmtree(tmp)
    print("saved:", out_path, "functions:", [f"s{s}" for s in seqs])


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--seq", type=int, default=128)
    ap.add_argument("--seqs", help="カンマ区切り。指定するとマルチファンクションで書き出す")
    ap.add_argument("--ln", choices=["native", "scaled"], default="native")
    ap.add_argument("--attn", choices=["heads", "split", "block"], default="heads")
    ap.add_argument("--resid-scale", type=float, default=1.0,
                    help="残差ストリームを 1/N で計算する（fp16 であふれるモデル向け。例: 4）")
    ap.add_argument("--safe-scores", action="store_true",
                    help="注意スコアを縮めて最大値を引いてから softmax する（巨大スコアで fp16 があふれるモデル向け）")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.seqs:
        export_multifunction(args.model, [int(x) for x in args.seqs.split(",")], args.ln, args.out, args.attn,
                             args.resid_scale, args.safe_scores)
        raise SystemExit(0)

    m = build(args.model, args.seq, args.ln, args.attn, args.resid_scale, args.safe_scores)
    # 変換前に PyTorch 上で元モデルと一致することを確認する（fp32）
    hf = GPT2LMHeadModel.from_pretrained(args.model, dtype=torch.float32).eval()
    ids = torch.randint(4, 6000, (1, args.seq), dtype=torch.int32)
    with torch.no_grad():
        ref = hf(ids.long()).logits[0]  # (S, V)
        got = m(ids)[0, :, 0, :].t()
    print(f"[torch fp32] max|diff| = {float((ref - got).abs().max()):.2e}")
    convert(m, args.out)
    print("saved:", args.out)
