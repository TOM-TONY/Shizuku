"""Gemma 4（E2B/E4B）の ANE 向け Core ML モデルを書き出す。

出力（out_dir）:
  ffn_c{k}.mlpackage 層の範囲ごとのチャンク。関数 infer（T=1）/ prefill（T=PREFILL）。
                     先頭チャンクは KV キャッシュを状態（kv_sliding, kv_full）として持ち、
                     後のチャンクが使う KV（kv_out_*）と合成済み PLE（ple）を出力する
  lm_head.mlpackage  出力層（LM_SPLIT 分割）＋ソフトキャップ
  meta.json          形状・設定
--lut N を付けると重みを N bit パレット化（線形層のみ）する。
使い方: python gemma4/convert_gemma4.py models/hf-llm/gemma-4-E2B models/gemma4-e2b-ane [--lut 6]
"""
import argparse
import json
import os
import shutil
import sys
import tempfile

import coremltools as ct
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(__file__))
import ane_gemma4  # noqa: E402
from ane_gemma4 import CTX, LM_SPLIT, PREFILL, Gemma4FFN, Gemma4FFNChunk, Gemma4LMHead, chunk_ranges  # noqa: E402


WORKERS = 1
INT8 = False
LUT_MODE = "kmeans"


def palettize(mlmodel, bits):
    if bits == 8 and INT8:
        # 8bit はパレット化（k-means）ではなく、出力チャンネルごとのスケールによる線形量子化
        import coremltools.optimize.coreml as cto
        op = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel",
                                         weight_threshold=2048)
        return cto.linear_quantize_weights(mlmodel, cto.OptimizationConfig(global_config=op))
    if not bits:
        return mlmodel
    import coremltools.optimize.coreml as cto
    op = cto.OpPalettizerConfig(mode=LUT_MODE, nbits=bits, granularity="per_grouped_channel", group_size=16,
                                num_kmeans_workers=WORKERS, weight_threshold=2048)
    out = cto.palettize_weights(mlmodel, cto.OptimizationConfig(global_config=op))
    # coremltools 9.0 は処理後にワーカーのプールを閉じるが参照を残すため、2 回目以降の呼び出しで
    # 「Pool not running」になる。参照を外して次回は作り直させる
    from coremltools.optimize.coreml._quantization_passes import palettize_weights as _pw
    _pw._compress_pool = None
    return out


class ChunkWrapper(torch.nn.Module):
    """チャンクの入力を、実際に使うものだけに揃える（KV を持たないチャンクは current_pos を取らない）。"""

    def __init__(self, chunk):
        super().__init__()
        self.chunk = chunk
        self.has_pos = bool(chunk.owners)

    def forward(self, *args):
        if self.has_pos:
            return self.chunk(*args)
        fixed, kvs = args[:7], args[7:]
        return self.chunk(*fixed, torch.zeros((1,), dtype=torch.int32), *kvs)


def convert_chunk(chunk, out_path, lut):
    f = chunk.f
    C, L, P = f.C, f.L, f.P
    # 状態（KV キャッシュ）を持つチャンクは直接トレースする。包みの中の状態は名前に「.」が入り、
    # coremltools の名前照合（「.」を「_」に置換）で見つからなくなるため
    wrapper = chunk if chunk.owners else ChunkWrapper(chunk).eval()
    if chunk.owners:
        wrapper.has_pos = True
    states = []
    for name in ("kv_sliding", "kv_full"):
        if hasattr(chunk, name):
            buf = getattr(chunk, name)
            states.append(ct.StateType(wrapped_type=ct.TensorType(shape=tuple(buf.shape), dtype=np.float16),
                                       name=name))
    in_names, out_names = chunk.io_names()
    if not wrapper.has_pos:
        in_names = [n for n in in_names if n != "current_pos"]
    tmp = tempfile.mkdtemp()
    desc = ct.utils.MultiFunctionDescriptor()
    for fname, T in (("infer", 1), ("prefill", PREFILL)):
        ex = [
            torch.zeros((1, T, C), dtype=torch.float16),
            torch.zeros((1, T, L * P), dtype=torch.float16),
            torch.ones((1, 1, T, f.Ds // 2), dtype=torch.float16),
            torch.zeros((1, 1, T, f.Ds // 2), dtype=torch.float16),
            torch.ones((1, 1, T, f.Df // 2), dtype=torch.float16),
            torch.zeros((1, 1, T, f.Df // 2), dtype=torch.float16),
            torch.zeros((1, 1, T, CTX), dtype=torch.float16),
        ]
        if wrapper.has_pos:
            ex.append(torch.zeros((1,), dtype=torch.int32))
        for s in chunk.imports:
            D = f.Df if f.types[s] == "full_attention" else f.Ds
            ex.append(torch.zeros((2, f.KVH, CTX, D), dtype=torch.float16))
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, tuple(ex))
        for name in ("kv_sliding", "kv_full"):
            if hasattr(chunk, name):
                getattr(chunk, name).zero_()
        inputs = [ct.TensorType(name=n, shape=tuple(t.shape), dtype=np.int32 if t.dtype == torch.int32 else np.float16)
                  for n, t in zip(in_names, ex)]
        ml = ct.convert(
            traced, inputs=inputs, outputs=[ct.TensorType(name=n, dtype=np.float16) for n in out_names],
            states=states or None, compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_NE,
            minimum_deployment_target=ct.target.macOS15, convert_to="mlprogram",
        )
        ml = palettize(ml, lut)
        path = os.path.join(tmp, f"{fname}.mlpackage")
        ml.save(path)
        desc.add_function(path, src_function_name="main", target_function_name=fname)
    desc.default_function_name = "infer"
    if os.path.exists(out_path):
        shutil.rmtree(out_path)
    ct.utils.save_multifunction(desc, out_path)
    shutil.rmtree(tmp)
    print("converted", out_path, in_names, out_names, flush=True)
    return in_names, out_names


def convert_head(model_dir, out_path, lut, C):
    head = Gemma4LMHead(model_dir, dtype=torch.float16).eval()
    ex = torch.zeros((1, 1, C), dtype=torch.float16)
    with torch.no_grad():
        traced = torch.jit.trace(head, ex)
    ml = ct.convert(
        traced, inputs=[ct.TensorType(name="hidden", shape=(1, 1, C), dtype=np.float16)],
        outputs=[ct.TensorType(name=f"logits{j}", dtype=np.float16) for j in range(LM_SPLIT)],
        compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS15, convert_to="mlprogram",
    )
    ml = palettize(ml, lut)
    if os.path.exists(out_path):
        shutil.rmtree(out_path)
    ml.save(out_path)
    print("converted lm_head", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--lut", type=int, default=0)
    ap.add_argument("--lut-head", type=int, default=None, help="出力層の bit 数（省略時は --lut と同じ）")
    ap.add_argument("--workers", type=int, default=1, help="パレット化の k-means 並列数")
    ap.add_argument("--int8", action="store_true", help="--lut 8 / --lut-head 8 をパレット化ではなく int8 線形量子化にする")
    ap.add_argument("--lut-mode", default="kmeans", choices=["kmeans", "uniform"], help="パレットの作り方（uniform は k-means なしの等間隔）")
    ap.add_argument("--ctx", type=int, default=CTX, help="KV キャッシュ長（扱える最大トークン数）。sliding_window（512）以下")
    ap.add_argument("--skip-head", action="store_true")
    ap.add_argument("--only-chunk", type=int, default=None, help="指定したチャンクだけ変換する（試験用）")
    ap.add_argument("--owner-chunks", type=int, default=1, help="KV を持つ層を分けるチャンク数")
    ap.add_argument("--shared-chunks", type=int, default=2, help="KV 共有層を分けるチャンク数")
    a = ap.parse_args()
    WORKERS = a.workers
    INT8 = a.int8
    # 文脈長を変える（ane_gemma4 は実行時にモジュールの CTX を参照する）。sliding 層を通常の因果注意で
    # 等価に扱えるのは sliding_window 以下のとき
    cfg = json.load(open(os.path.join(a.model_dir, "config.json")))
    window = cfg.get("text_config", cfg).get("sliding_window", 512)
    assert a.ctx <= window, f"--ctx は sliding_window（{window}）以下にする"
    CTX = ane_gemma4.CTX = a.ctx
    LUT_MODE = a.lut_mode
    lut_head = a.lut if a.lut_head is None else a.lut_head
    os.makedirs(a.out_dir, exist_ok=True)
    ffn = Gemma4FFN(a.model_dir, dtype=torch.float16).eval()
    chunks_meta = []
    for k, (start, end) in enumerate(chunk_ranges(ffn.L, ffn.first_shared, a.shared_chunks, a.owner_chunks)):
        if a.only_chunk is not None and k != a.only_chunk:
            continue
        chunk = Gemma4FFNChunk(ffn, start, end).eval()
        ins, outs = convert_chunk(chunk, os.path.join(a.out_dir, f"ffn_c{k}.mlpackage"), a.lut)
        chunks_meta.append(dict(file=f"ffn_c{k}", start=start, end=end, inputs=ins, outputs=outs,
                                imports=chunk.imports, exports=chunk.exports,
                                states=[n for n in ("kv_sliding", "kv_full") if hasattr(chunk, n)]))
    if not a.skip_head:
        convert_head(a.model_dir, os.path.join(a.out_dir, "lm_head.mlpackage"), lut_head, ffn.C)
    meta = dict(ctx=CTX, prefill=PREFILL, lm_split=LM_SPLIT, hidden=ffn.C, layers=ffn.L, ple=ffn.P, chunks=chunks_meta,
                kv_heads=ffn.KVH,
                head_dim_sliding=ffn.Ds, head_dim_full=ffn.Df, kv_sliding=list(ffn.kv_sliding.shape),
                kv_full=list(ffn.kv_full.shape), lut=a.lut, lut_head=lut_head, source=a.model_dir)
    json.dump(meta, open(os.path.join(a.out_dir, "meta.json"), "w"), indent=1)
    print(json.dumps(meta))
