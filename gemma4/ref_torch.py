"""Gemma 4（E2B/E4B）テキスト部の素直な PyTorch 参照実装（fp32, KV キャッシュなし）。

mlx_lm/models/gemma4_text.py を手本にしている。ANE 版（ane_gemma4.py）の比較基準に使う。
- RMSNorm は x / rms(x) * weight（Gemma 4 の重みは 1+w 形式ではない）
- 注意のスケールは 1.0（q_norm / k_norm があるため）
- RoPE: sliding 層は head_dim 全体（θ=1e4）、full 層は proportional（先頭 25% のみ回転、θ=1e6、指数の分母は head_dim）
- 後半 num_kv_shared_layers 層は、前半の同種の最後の層の K/V を使う
- 層ごとの追加埋め込み（PLE）は使うトークンの行だけ読む（全体は fp32 で 9GB を超える）
"""
import glob
import json
import math

import torch
import torch.nn.functional as F
from safetensors import safe_open

PREFIX = "model.language_model."


class Weights:
    def __init__(self, model_dir):
        self.files = sorted(glob.glob(f"{model_dir}/*.safetensors"))
        self.index = {}
        for f in self.files:
            with safe_open(f, "pt") as g:
                for k in g.keys():
                    if k.startswith(PREFIX):
                        self.index[k[len(PREFIX):]] = f

    def get(self, name):
        with safe_open(self.index[name], "pt") as g:
            return g.get_tensor(PREFIX + name).float()

    def has(self, name):
        return name in self.index

    def rows(self, name, ids):
        with safe_open(self.index[name], "pt") as g:
            sl = g.get_slice(PREFIX + name)
            return torch.stack([sl[int(i):int(i) + 1][0] for i in ids]).float()


def rms_norm(x, w=None, eps=1e-6):
    y = x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + eps)
    return y * w if w is not None else y


def rope_cos_sin(positions, head_dim, rotated_dims, base):
    """非 traditional（前半・後半を組にする）RoPE の cos/sin。回転しない組は cos=1, sin=0。"""
    half = head_dim // 2
    exps = torch.arange(0, rotated_dims, 2, dtype=torch.float64) / head_dim
    inv = torch.zeros(half, dtype=torch.float64)
    inv[: rotated_dims // 2] = base ** (-exps)
    ang = positions.double()[:, None] * inv[None, :]  # (T, half)
    return torch.cos(ang).float(), torch.sin(ang).float()


def apply_rope(x, cos, sin):  # x: (H, T, D)
    half = x.shape[-1] // 2
    x1, x2 = x[..., :half], x[..., half:]
    return torch.cat([x1 * cos - x2 * sin, x2 * cos + x1 * sin], dim=-1)


class Gemma4Ref:
    def __init__(self, model_dir):
        cfg = json.load(open(f"{model_dir}/config.json"))
        self.cfg = c = cfg.get("text_config", cfg)
        self.w = Weights(model_dir)
        self.L = c["num_hidden_layers"]
        self.H = c["num_attention_heads"]
        self.C = c["hidden_size"]
        self.P = c["hidden_size_per_layer_input"]
        self.types = c["layer_types"]
        self.first_shared = self.L - c["num_kv_shared_layers"]
        last_by_type = {}
        for i in range(self.first_shared):
            last_by_type[self.types[i]] = i
        self.kv_source = [i if i < self.first_shared else last_by_type[self.types[i]] for i in range(self.L)]
        rp = c.get("rope_parameters") or {}
        self.rope = {
            "sliding_attention": (c["head_dim"], rp.get("sliding_attention", {}).get("rope_theta", 1e4),
                                  rp.get("sliding_attention", {}).get("partial_rotary_factor", 1.0)),
            "full_attention": (c["global_head_dim"], rp.get("full_attention", {}).get("rope_theta", 1e6),
                               rp.get("full_attention", {}).get("partial_rotary_factor", 0.25)),
        }
        self.softcap = c.get("final_logit_softcapping")
        self.eps = c["rms_norm_eps"]
        self.embed = self.w.get("embed_tokens.weight")  # (V, C) 出力層と共有
        self.lw = [{k.split(f"layers.{i}.")[1]: None for k in self.w.index if k.startswith(f"layers.{i}.")}
                   for i in range(self.L)]
        self.cache = {}

    def p(self, name):
        if name not in self.cache:
            self.cache[name] = self.w.get(name)
        return self.cache[name]

    def per_layer_inputs(self, ids, h):
        """PLE: 表の行 × √P と、h からの射影（÷√C, RMSNorm）を足して ÷√2。(T, L, P)"""
        T = len(ids)
        tab = self.w.rows("embed_tokens_per_layer.weight", ids).view(T, self.L, self.P) * math.sqrt(self.P)
        proj = (h @ self.p("per_layer_model_projection.weight").T) * (self.C ** -0.5)
        proj = rms_norm(proj.view(T, self.L, self.P), self.p("per_layer_projection_norm.weight"), self.eps)
        return (proj + tab) * (2.0 ** -0.5)

    @torch.no_grad()
    def forward(self, ids, stats=None):
        ids = torch.tensor(ids)
        T = len(ids)
        h = self.embed[ids] * math.sqrt(self.C)
        ple = self.per_layer_inputs(ids, h)
        pos = torch.arange(T)
        mask = torch.full((T, T), -math.inf).triu(1)
        kvs = {}
        for i in range(self.L):
            pre = f"layers.{i}."
            t = self.types[i]
            hd, base, frac = self.rope[t]
            cos, sin = rope_cos_sin(pos, hd, int(hd * frac), base)
            x = rms_norm(h, self.p(pre + "input_layernorm.weight"), self.eps)
            q = (x @ self.p(pre + "self_attn.q_proj.weight").T).view(T, self.H, hd).transpose(0, 1)
            q = apply_rope(rms_norm(q, self.p(pre + "self_attn.q_norm.weight"), self.eps), cos, sin)
            if i < self.first_shared:
                k = (x @ self.p(pre + "self_attn.k_proj.weight").T).view(T, -1, hd).transpose(0, 1)
                v = (x @ self.p(pre + "self_attn.v_proj.weight").T).view(T, -1, hd).transpose(0, 1)
                k = apply_rope(rms_norm(k, self.p(pre + "self_attn.k_norm.weight"), self.eps), cos, sin)
                v = rms_norm(v, None, self.eps)
                kvs[i] = (k, v)
            else:
                k, v = kvs[self.kv_source[i]]
            if k.shape[0] != self.H:  # GQA: KV ヘッド j を q ヘッド j·G .. j·G+G-1 で共有
                k = k.repeat_interleave(self.H // k.shape[0], dim=0)
                v = v.repeat_interleave(self.H // v.shape[0], dim=0)
            scores = q @ k.transpose(-1, -2) + mask  # scale = 1.0
            if stats is not None:
                stats.setdefault("attn_score_max", []).append(float(scores[torch.isfinite(scores)].abs().max()))
            a = (scores.softmax(-1) @ v).transpose(0, 1).reshape(T, -1)
            a = a @ self.p(pre + "self_attn.o_proj.weight").T
            h = h + rms_norm(a, self.p(pre + "post_attention_layernorm.weight"), self.eps)
            x = rms_norm(h, self.p(pre + "pre_feedforward_layernorm.weight"), self.eps)
            g = F.gelu(x @ self.p(pre + "mlp.gate_proj.weight").T, approximate="tanh")
            u = x @ self.p(pre + "mlp.up_proj.weight").T
            if stats is not None:
                stats.setdefault("mlp_inner_max", []).append(float((g * u).abs().max()))
            m = (g * u) @ self.p(pre + "mlp.down_proj.weight").T
            h = h + rms_norm(m, self.p(pre + "post_feedforward_layernorm.weight"), self.eps)
            gate = F.gelu(h @ self.p(pre + "per_layer_input_gate.weight").T, approximate="tanh") * ple[:, i, :]
            gate = gate @ self.p(pre + "per_layer_projection.weight").T
            h = h + rms_norm(gate, self.p(pre + "post_per_layer_input_norm.weight"), self.eps)
            h = h * self.p(pre + "layer_scalar")
            if stats is not None:
                stats.setdefault("resid_max", []).append(float(h.abs().max()))
        h = rms_norm(h, self.p("norm.weight"), self.eps)
        logits = h @ self.embed.T
        if self.softcap:
            logits = torch.tanh(logits / self.softcap) * self.softcap
        return logits
