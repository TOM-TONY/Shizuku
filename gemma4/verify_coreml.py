"""Core ML 版 Gemma 4 を参照実装（fp32）と比べ、1 トークンあたりの時間を測る。

使い方: python gemma4/verify_coreml.py <coreml_dir> <hf_model_dir> [CPU_AND_NE|CPU_AND_GPU]
"""
import json
import os
import sys
import time

import coremltools as ct
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from ane_gemma4 import HostSide  # noqa: E402
from ref_torch import Gemma4Ref  # noqa: E402

TEXT = "お世話になっております。先日の打ち合わせの件で"


class CoreMLGemma4:
    def __init__(self, d, units):
        self.meta = json.load(open(f"{d}/meta.json"))
        cu = getattr(ct.ComputeUnit, units)
        self.chunks = []
        for c in self.meta["chunks"]:
            path = f"{d}/{c['file']}.mlpackage"
            t0 = time.time()
            fns = {fn: ct.models.MLModel(path, compute_units=cu, function_name=fn) for fn in ("infer", "prefill")}
            print(f"  load {c['file']} {time.time() - t0:.1f}s", flush=True)
            self.chunks.append((c, fns))
        self.head = ct.models.MLModel(f"{d}/lm_head.mlpackage", compute_units=cu)
        self.reset()

    def reset(self):
        """KV キャッシュ（状態を持つチャンクごとの MLState）を空にする。"""
        self.states = [fns["infer"].make_state() if c["states"] else None for c, fns in self.chunks]

    def step(self, inputs, fn="infer"):
        """1 回分（infer は 1 トークン、prefill は PREFILL トークン）を流し、最終 hidden を返す。"""
        pool = dict(inputs)
        for (c, fns), state in zip(self.chunks, self.states):
            d = {n: pool[n] for n in c["inputs"]}
            out = fns[fn].predict(d, state=state) if state is not None else fns[fn].predict(d)
            pool["hidden"] = out["output_hidden"]
            if "ple" in out:
                pool["ple"] = out["ple"]
            for s in c["exports"]:
                pool[f"kv_in_{s}"] = out[f"kv_out_{s}"]
        return pool["hidden"]

    def logits(self, h_last):
        out = self.head.predict({"hidden": h_last.reshape(1, 1, -1).astype(np.float16)})
        return np.concatenate([out[f"logits{j}"].reshape(-1) for j in range(self.meta["lm_split"])]).astype(np.float32)


def main(d, hf, units="CPU_AND_NE"):
    host = HostSide(hf)
    from tokenizers import Tokenizer
    tok = Tokenizer.from_file(f"{hf}/tokenizer.json")
    ids = tok.encode(TEXT, add_special_tokens=False).ids
    if not ids or ids[0] != 2:
        ids = [2] + ids  # Gemma は先頭に BOS（id 2）
    print("ids", ids)
    ref = Gemma4Ref(hf).forward(ids).numpy()
    print(f"[{units}] loading", flush=True)
    m = CoreMLGemma4(d, units)
    got, times = [], []
    for p, t in enumerate(ids):
        t0 = time.perf_counter()
        h = m.step(host.inputs([t], p))
        lg = m.logits(h[0, -1])
        times.append((time.perf_counter() - t0) * 1000)
        got.append(lg)
    got = np.stack(got)
    print(f"infer: argmax 一致 {(got.argmax(-1) == ref.argmax(-1)).mean():.3f}  max|diff| {np.abs(got - ref).max():.3f}")
    print(f"1 トークン（FFN 3 チャンク＋出力層、Python 経由）: 中央値 {np.median(times[2:]):.1f}ms")
    # prefill（PREFILL トークン一括、詰め物あり）→ 最後のトークンを infer
    m.reset()
    pre = ids[:-1]
    pad = pre + [pre[-1]] * (m.meta["prefill"] - len(pre))
    t0 = time.perf_counter()
    m.step(host.inputs(pad, 0), fn="prefill")
    tp = (time.perf_counter() - t0) * 1000
    h = m.step(host.inputs([ids[-1]], len(ids) - 1))
    lg = m.logits(h[0, -1])
    print(f"prefill({m.meta['prefill']}) {tp:.1f}ms → 最後の位置 argmax 一致 {lg.argmax() == ref[-1].argmax()}  max|diff| {np.abs(lg - ref[-1]).max():.3f}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
