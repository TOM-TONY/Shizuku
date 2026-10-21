"""Gemma 4（E2B/E4B）テキスト部を ANE 向けに組み直し、Core ML に変換する。

構成（ANEMLL と同じく部品ごとの Core ML モデル）:
  - 埋め込み（26 万語×C）と層ごとの追加埋め込み PLE（26 万語×L·P）の表引きは CPU（Swift）側で行い、
    結果をモデルに入力する（巨大な表を ANE に載せない）
  - ffn: 全 35 層。KV キャッシュは状態（MLState）として持つ。関数 infer（T=1）と prefill（T=PREFILL）
      入力 hidden (1,T,C)＝embed×√C、ple_rows (1,T,L·P)＝PLE 表の行×√P、
           cos_s/sin_s (1,1,T,Ds/2)、cos_f/sin_f (1,1,T,Df/2)、causal_mask (1,1,T,CTX)、current_pos (1,)
      出力 hidden (1,T,C)（最終 RMSNorm 済み）
  - lm_head: 共有埋め込みによる出力層（16 分割）＋ソフトキャップ
文脈長 CTX ≤ sliding_window（512）なので、sliding 層も全文脈を見る通常の因果注意で等価になる。
RMSNorm は [x, -x] を連結して LayerNorm する（平均 0 になるので RMS 正規化と一致）。ANE ネイティブの
layer_norm を使えて、fp16 での二乗のあふれも避けられる。
"""
import json
import math
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ref_torch import Weights  # noqa: E402

CTX = 256
PREFILL = 64
LM_SPLIT = 16


def rms_norm(x, weight=None, eps=1e-6):
    """最後の次元で RMSNorm。LayerNorm([x, -x]) の前半 = x / sqrt(mean(x²)+eps)。"""
    n = x.shape[-1]
    y = F.layer_norm(torch.cat([x, -x], dim=-1), (2 * n,), eps=eps)[..., :n]
    return y * weight if weight is not None else y


def rotate(x, cos, sin):  # x: (1,H,T,D), cos/sin: (1,1,T,D/2)
    half = x.shape[-1] // 2
    x1, x2 = x[..., :half], x[..., half:]
    return torch.cat([x1 * cos - x2 * sin, x2 * cos + x1 * sin], dim=-1)


def attention(q, kc, vc, causal_mask, H, KVH, T, D):
    """q (1,H,T,D), kc/vc (1,KVH,CTX,D) → (1,T,H·D)。scale = 1.0。

    KV ヘッドが複数（GQA）のときは、同じ KV ヘッドを使う G=H/KVH 個の q ヘッドを
    トークン方向に並べて (1,KVH,G·T,D) として 1 回の行列積にする（KV を複製しない）。
    """
    if KVH == 1:
        scores = torch.matmul(q, kc.transpose(-1, -2)) + causal_mask
        return torch.matmul(scores.softmax(-1), vc).transpose(1, 2).reshape(1, T, H * D)
    G = H // KVH
    q2 = q.reshape(1, KVH, G * T, D)
    mask = causal_mask.repeat(1, 1, G, 1) if G > 1 else causal_mask
    scores = torch.matmul(q2, kc.transpose(-1, -2)) + mask
    a = torch.matmul(scores.softmax(-1), vc)  # (1,KVH,G·T,D)
    return a.reshape(1, H, T, D).transpose(1, 2).reshape(1, T, H * D)


class Gemma4FFN(nn.Module):
    def __init__(self, model_dir, dtype=torch.float16):
        super().__init__()
        cfg = json.load(open(f"{model_dir}/config.json"))
        c = cfg.get("text_config", cfg)
        w = Weights(model_dir)
        self.L, self.H, self.C, self.P = c["num_hidden_layers"], c["num_attention_heads"], c["hidden_size"], c["hidden_size_per_layer_input"]
        self.Ds, self.Df = c["head_dim"], c["global_head_dim"]
        self.KVH = c["num_key_value_heads"]
        self.eps = c["rms_norm_eps"]
        self.types = c["layer_types"]
        self.first_shared = self.L - c["num_kv_shared_layers"]
        last = {}
        for i in range(self.first_shared):
            last[self.types[i]] = i
        self.kv_source = [i if i < self.first_shared else last[self.types[i]] for i in range(self.L)]
        # KV を持つ層ごとに、種類別バッファ内の番号を振る
        self.slot, ns, nf = {}, 0, 0
        for i in range(self.first_shared):
            if self.types[i] == "full_attention":
                self.slot[i], nf = nf, nf + 1
            else:
                self.slot[i], ns = ns, ns + 1
        self.register_buffer("kv_sliding", torch.zeros((2 * ns, self.KVH, CTX, self.Ds), dtype=dtype))
        self.register_buffer("kv_full", torch.zeros((2 * nf, self.KVH, CTX, self.Df), dtype=dtype))

        def lin(name):
            t = w.get(name)
            m = nn.Linear(t.shape[1], t.shape[0], bias=False)
            m.weight.data = t.to(dtype)
            return m

        def vec(name):
            return nn.Parameter(w.get(name).to(dtype), requires_grad=False)

        self.ple_proj = lin("per_layer_model_projection.weight")
        self.ple_norm = vec("per_layer_projection_norm.weight")
        self.final_norm = vec("norm.weight")
        self.layers = nn.ModuleList()
        for i in range(self.L):
            p = f"layers.{i}."
            m = nn.Module()
            m.q = lin(p + "self_attn.q_proj.weight")
            m.o = lin(p + "self_attn.o_proj.weight")
            m.q_norm = vec(p + "self_attn.q_norm.weight")
            if i < self.first_shared:
                m.k = lin(p + "self_attn.k_proj.weight")
                m.v = lin(p + "self_attn.v_proj.weight")
                m.k_norm = vec(p + "self_attn.k_norm.weight")
            m.gate, m.up, m.down = lin(p + "mlp.gate_proj.weight"), lin(p + "mlp.up_proj.weight"), lin(p + "mlp.down_proj.weight")
            m.ple_gate, m.ple_out = lin(p + "per_layer_input_gate.weight"), lin(p + "per_layer_projection.weight")
            for n in ("input_layernorm", "post_attention_layernorm", "pre_feedforward_layernorm",
                      "post_feedforward_layernorm", "post_per_layer_input_norm"):
                setattr(m, n, vec(p + n + ".weight"))
            m.scalar = vec(p + "layer_scalar")
            self.layers.append(m)

    def forward(self, hidden, ple_rows, cos_s, sin_s, cos_f, sin_f, causal_mask, current_pos):
        T = hidden.shape[1]
        L, P, H = self.L, self.P, self.H
        h = hidden
        # 層ごとの追加埋め込み: h からの射影（÷√C, RMSNorm）＋表の行、÷√2
        proj = self.ple_proj(h) * (self.C ** -0.5)
        proj = rms_norm(proj.view(1, T, L, P), self.ple_norm, self.eps)
        ple = (proj + ple_rows.view(1, T, L, P)) * (2.0 ** -0.5)
        pos = current_pos[0]
        for i, m in enumerate(self.layers):
            full = self.types[i] == "full_attention"
            D = self.Df if full else self.Ds
            cos, sin = (cos_f, sin_f) if full else (cos_s, sin_s)
            buf = self.kv_full if full else self.kv_sliding
            x = rms_norm(h, m.input_layernorm, self.eps)
            q = m.q(x).view(1, T, H, D).transpose(1, 2)
            q = rotate(rms_norm(q, m.q_norm, self.eps), cos, sin)
            if i < self.first_shared:
                k = m.k(x).view(1, T, self.KVH, D).transpose(1, 2)
                v = m.v(x).view(1, T, self.KVH, D).transpose(1, 2)
                k = rotate(rms_norm(k, m.k_norm, self.eps), cos, sin)
                v = rms_norm(v, None, self.eps)
                s = self.slot[i]
                buf[2 * s:2 * s + 1, :, pos:pos + T, :] = k
                buf[2 * s + 1:2 * s + 2, :, pos:pos + T, :] = v
            s = self.slot[self.kv_source[i]]
            kc = buf[2 * s:2 * s + 1]       # (1,KVH,CTX,D)
            vc = buf[2 * s + 1:2 * s + 2]
            a = attention(q, kc, vc, causal_mask, H, self.KVH, T, D)
            h = h + rms_norm(m.o(a), m.post_attention_layernorm, self.eps)
            x = rms_norm(h, m.pre_feedforward_layernorm, self.eps)
            hm = F.gelu(m.gate(x), approximate="tanh") * m.up(x)
            h = h + rms_norm(m.down(hm), m.post_feedforward_layernorm, self.eps)
            g = F.gelu(m.ple_gate(h), approximate="tanh") * ple[:, :, i, :]
            h = h + rms_norm(m.ple_out(g), m.post_per_layer_input_norm, self.eps)
            h = h * m.scalar
        return rms_norm(h, self.final_norm, self.eps)


class Gemma4LMHead(nn.Module):
    """共有埋め込みによる出力層を LM_SPLIT 個に分割し、ソフトキャップしてそれぞれ出力する。"""

    def __init__(self, model_dir, dtype=torch.float16):
        super().__init__()
        cfg = json.load(open(f"{model_dir}/config.json"))
        c = cfg.get("text_config", cfg)
        self.softcap = c.get("final_logit_softcapping") or 0.0
        emb = Weights(model_dir).get("embed_tokens.weight").to(dtype)
        V = emb.shape[0]
        n = V // LM_SPLIT
        self.heads = nn.ModuleList()
        for j in range(LM_SPLIT):
            m = nn.Linear(emb.shape[1], n, bias=False)
            m.weight.data = emb[j * n:(j + 1) * n].clone()
            self.heads.append(m)

    def forward(self, hidden):  # (1,1,C)
        outs = []
        for m in self.heads:
            y = m(hidden)
            if self.softcap:
                y = torch.tanh(y * (1.0 / self.softcap)) * self.softcap
            outs.append(y)
        return tuple(outs)


# --- CPU 側の補助（Swift 版でも同じことをする） -------------------------------------------

def rope_tables(positions, head_dim, rotated_dims, base):
    half = head_dim // 2
    inv = np.zeros(half)
    inv[: rotated_dims // 2] = base ** (-np.arange(0, rotated_dims, 2) / head_dim)
    ang = np.asarray(positions, dtype=np.float64)[:, None] * inv[None, :]
    return np.cos(ang).astype(np.float16)[None, None], np.sin(ang).astype(np.float16)[None, None]


def causal_mask_rows(start, T):
    m = np.full((1, 1, T, CTX), -np.inf, dtype=np.float16)
    for t in range(T):
        m[0, 0, t, : start + t + 1] = 0
    return m


class HostSide:
    """埋め込み・PLE の表引きと RoPE/マスクの準備（参照用。Swift 版の手本）。"""

    def __init__(self, model_dir):
        cfg = json.load(open(f"{model_dir}/config.json"))
        c = self.c = cfg.get("text_config", cfg)
        self.w = Weights(model_dir)
        rp = c.get("rope_parameters") or {}
        self.sl = (c["head_dim"], int(c["head_dim"] * rp.get("sliding_attention", {}).get("partial_rotary_factor", 1.0)),
                   rp.get("sliding_attention", {}).get("rope_theta", 1e4))
        self.fu = (c["global_head_dim"], int(c["global_head_dim"] * rp.get("full_attention", {}).get("partial_rotary_factor", 0.25)),
                   rp.get("full_attention", {}).get("rope_theta", 1e6))

    def inputs(self, ids, start):
        T = len(ids)
        C, P = self.c["hidden_size"], self.c["hidden_size_per_layer_input"]
        hidden = (self.w.rows("embed_tokens.weight", ids) * math.sqrt(C)).numpy().astype(np.float16)[None]
        ple = (self.w.rows("embed_tokens_per_layer.weight", ids) * math.sqrt(P)).numpy().astype(np.float16)[None]
        pos = list(range(start, start + T))
        cos_s, sin_s = rope_tables(pos, *self.sl[:2], self.sl[2])
        cos_f, sin_f = rope_tables(pos, *self.fu[:2], self.fu[2])
        return dict(hidden=hidden, ple_rows=ple, cos_s=cos_s, sin_s=sin_s, cos_f=cos_f, sin_f=sin_f,
                    causal_mask=causal_mask_rows(start, T), current_pos=np.array([start], dtype=np.int32))


class Gemma4FFNChunk(nn.Module):
    """層 [start, end) を担当する FFN の一部（ANE の 1 モデルあたりの大きさの制約のため分割する）。

    - start == 0 のチャンクは PLE を合成して出力 `ple` に出す。以降のチャンクは入力 `ple` を使う
    - KV を持つ層（owner）がチャンク内にあれば、その KV キャッシュを状態として持つ
    - 後のチャンクの KV 共有層が参照する owner 層の KV は、更新後のキャッシュ全体を `kv_out_<層>` として出力する
    - チャンク内の KV 共有層が他チャンクの owner を参照する場合は `kv_in_<層>` を入力に取る
    最後のチャンクは最終 RMSNorm を適用する。
    """

    def __init__(self, full: "Gemma4FFN", start: int, end: int):
        super().__init__()
        # 元の全体モデルは部品として登録しない（重み・状態が二重に追跡されるのを防ぐ）
        self.__dict__["f"] = full
        self.start, self.end = start, end
        self.layer_ids = list(range(start, end))
        f = full
        later_sources = {f.kv_source[i] for i in range(end, f.L) if i >= f.first_shared}
        self.owners = [i for i in self.layer_ids if i < f.first_shared]
        self.exports = sorted(s for s in later_sources if s in self.owners)
        self.imports = sorted({f.kv_source[i] for i in self.layer_ids if i >= f.first_shared} - set(self.owners))
        dtype = f.kv_sliding.dtype
        self.slot, ns, nf = {}, 0, 0
        for i in self.owners:
            if f.types[i] == "full_attention":
                self.slot[i], nf = ("full", nf), nf + 1
            else:
                self.slot[i], ns = ("sliding", ns), ns + 1
        if ns:
            self.register_buffer("kv_sliding", torch.zeros((2 * ns, f.KVH, CTX, f.Ds), dtype=dtype))
        if nf:
            self.register_buffer("kv_full", torch.zeros((2 * nf, f.KVH, CTX, f.Df), dtype=dtype))
        self.layers = nn.ModuleList([f.layers[i] for i in self.layer_ids])
        if start == 0:
            self.ple_proj, self.ple_norm = f.ple_proj, f.ple_norm
        if end == f.L:
            self.final_norm = f.final_norm

    def buffer(self, kind):
        return self.kv_full if kind == "full" else self.kv_sliding

    def forward(self, hidden, ple_in, cos_s, sin_s, cos_f, sin_f, causal_mask, current_pos, *kv_inputs):
        f = self.f
        T = hidden.shape[1]
        L, P, H = f.L, f.P, f.H
        h = hidden
        if self.start == 0:
            proj = self.ple_proj(h) * (f.C ** -0.5)
            proj = rms_norm(proj.view(1, T, L, P), self.ple_norm, f.eps)
            ple = (proj + ple_in.view(1, T, L, P)) * (2.0 ** -0.5)
        else:
            ple = ple_in.view(1, T, L, P)
        imported = {s: kv for s, kv in zip(self.imports, kv_inputs)}
        pos = current_pos[0]
        for i, m in zip(self.layer_ids, self.layers):
            full = f.types[i] == "full_attention"
            D = f.Df if full else f.Ds
            cos, sin = (cos_f, sin_f) if full else (cos_s, sin_s)
            x = rms_norm(h, m.input_layernorm, f.eps)
            q = m.q(x).view(1, T, H, D).transpose(1, 2)
            q = rotate(rms_norm(q, m.q_norm, f.eps), cos, sin)
            if i in self.owners:
                k = m.k(x).view(1, T, f.KVH, D).transpose(1, 2)
                v = m.v(x).view(1, T, f.KVH, D).transpose(1, 2)
                k = rotate(rms_norm(k, m.k_norm, f.eps), cos, sin)
                v = rms_norm(v, None, f.eps)
                kind, s = self.slot[i]
                buf = self.buffer(kind)
                # ANEMLL と同じく current_pos（要素 1 のテンソル）をそのまま開始位置に使う。
                # current_pos[0] でスカラーに取り出すと位置計算が CPU 側になり、状態操作ごと CPU に落ちる
                buf[2 * s:2 * s + 1, :, current_pos:current_pos + T, :] = k
                buf[2 * s + 1:2 * s + 2, :, current_pos:current_pos + T, :] = v
            src = f.kv_source[i]
            if src in self.owners:
                kind, s = self.slot[src]
                buf = self.buffer(kind)
                kc, vc = buf[2 * s:2 * s + 1], buf[2 * s + 1:2 * s + 2]
            else:
                kv = imported[src]
                kc, vc = kv[0:1], kv[1:2]
            a = attention(q, kc, vc, causal_mask, H, f.KVH, T, D)
            h = h + rms_norm(m.o(a), m.post_attention_layernorm, f.eps)
            x = rms_norm(h, m.pre_feedforward_layernorm, f.eps)
            hm = F.gelu(m.gate(x), approximate="tanh") * m.up(x)
            h = h + rms_norm(m.down(hm), m.post_feedforward_layernorm, f.eps)
            g = F.gelu(m.ple_gate(h), approximate="tanh") * ple[:, :, i, :]
            h = h + rms_norm(m.ple_out(g), m.post_per_layer_input_norm, f.eps)
            h = h * m.scalar
        if self.end == f.L:
            h = rms_norm(h, self.final_norm, f.eps)
        outs = [h]
        if self.start == 0:
            outs.append(ple.reshape(1, T, L * P))
        for s in self.exports:
            kind, idx = self.slot[s]
            buf = self.buffer(kind)
            outs.append(buf[2 * idx:2 * idx + 2] * 1.0)  # (2,KVH,CTX,D) 状態を出力へコピー
        return tuple(outs)

    def io_names(self):
        ins = ["hidden", "ple_rows" if self.start == 0 else "ple", "cos_s", "sin_s", "cos_f", "sin_f",
               "causal_mask", "current_pos"] + [f"kv_in_{s}" for s in self.imports]
        outs = ["output_hidden"] + (["ple"] if self.start == 0 else []) + [f"kv_out_{s}" for s in self.exports]
        return ins, outs


def chunk_ranges(L, first_shared, n_shared_chunks=2, n_owner_chunks=1):
    """KV を持つ層（先頭 first_shared 層）を n_owner_chunks 個、残りの共有層を n_shared_chunks 個に等分する。"""
    def split(a, b, n):
        step = math.ceil((b - a) / n)
        return [(x, min(b, x + step)) for x in range(a, b, step)]
    return split(0, first_shared, n_owner_chunks) + split(first_shared, L, n_shared_chunks)
