"""Core ML 版 zenz（ANE, fp16）を元の Hugging Face モデル（fp32）と比較する。

  1. 貪欲変換の結果が一致するか（テスト文ごと）
  2. 元モデルの出力列に沿った各位置で argmax が一致するか、ロジットの最大誤差
  3. 1 回の forward の応答時間

使い方:
  python zenz/verify.py --hf models/hf/zenz-v3.1-xsmall --coreml models/zenz-v3.1-xsmall-s128-native.mlpackage
"""
import argparse
import sys
import time
from typing import Optional
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).parent))
from reference import build_prompt, greedy, load  # noqa: E402

PAD = 1
EOS = 3

CASES = [
    ("にほんご", ""),
    ("きょうはいしゃにいく", ""),
    ("かいぎのしりょうをおくります", "お世話になっております。"),
    ("わたしはきのうとうきょうでむかしのともだちにあった", ""),
    ("あしたはあめがふるらしい", ""),
    ("しょうひぜいのけいさんをまちがえた", ""),
    ("このけんについてごかくにんください", "お疲れ様です。"),
    ("じんこうちのうのけんきゅうがすすんでいる", ""),
    ("きしゃのきしゃがきしゃできしゃした", ""),
    ("はしのはしをはしでつまむ", ""),
    ("こうえんでこうえんをきく", ""),
    ("でんしゃがおくれているのでちこくします", ""),
    ("しんかんせんのきっぷをよやくした", ""),
    ("らいしゅうのよていをおしえてください", ""),
    ("ぷろぐらみんぐげんごをべんきょうする", ""),
    ("にゅーらるえんじんでうごかす", ""),
    ("さくらがまんかいになった", ""),
    ("いしゃにいしゃりょうをはらう", ""),
    ("せいこうするかどうかはわからない", ""),
    ("きのうのばんごはんはかれーだった", ""),
    ("ほんじつはごらいてんいただきありがとうございます", ""),
    ("しようしゃのいけんをはんえいする", ""),
    ("かいしゃのけっさんほうこくをよむ", ""),
    ("ちょっとまって", ""),
    ("よろしくおねがいいたします", "ご検討のほど"),
    ("とうきょうとっきょきょかきょく", ""),
    ("こうしんりょうをいれる", ""),
    ("にわにはにわにわとりがいる", ""),
    ("かがくとかがく", ""),
    ("せいかくなじょうほうをつたえる", ""),
]


class CoreMLZenz:
    def __init__(self, path: str, units: ct.ComputeUnit, function: "Optional[str]" = None):
        if function:
            # マルチファンクションモデル（関数名 s<系列長>）
            self.model = ct.models.MLModel(path, compute_units=units, function_name=function)
            self.seq = int(function[1:])
        else:
            self.model = ct.models.MLModel(path, compute_units=units)
            self.seq = self.model.get_spec().description.input[0].type.multiArrayType.shape[1]

    def logits(self, ids):  # -> (len(ids), V) float32
        assert len(ids) <= self.seq, f"{len(ids)} > {self.seq}"
        x = np.full((1, self.seq), PAD, dtype=np.int32)
        x[0, : len(ids)] = ids
        out = self.model.predict({"input_ids": x})["logits"]  # (1, V, 1, S)
        return out[0, :, 0, : len(ids)].T.astype(np.float32)

    def greedy(self, prompt_ids, max_new=40):
        ids = list(prompt_ids)
        start = len(ids)
        while len(ids) - start < max_new and len(ids) < self.seq:
            nxt = int(self.logits(ids)[-1].argmax())
            if nxt == EOS:
                break
            ids.append(nxt)
        return ids[start:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hf", required=True)
    ap.add_argument("--coreml", required=True)
    ap.add_argument("--units", default="CPU_AND_NE", choices=["CPU_AND_NE", "CPU_AND_GPU", "CPU_ONLY", "ALL"])
    ap.add_argument("--function", help="マルチファンクションモデルの関数名（例: s512）")
    ap.add_argument("--long", action="store_true", help="テスト文を連結した長文ケースで検証する")
    args = ap.parse_args()

    tok, hf = load(args.hf)
    cm = CoreMLZenz(args.coreml, getattr(ct.ComputeUnit, args.units), args.function)
    cases = CASES
    if args.long:
        # 11 文ずつ連結した長い読み（左文脈付き）。プロンプト＋出力で 256 トークン超になる
        readings = [r for r, _ in CASES]
        cases = [("".join(readings[i:i + 11]), "お世話になっております。先日の件でご連絡いたしました。")
                 for i in range(0, len(readings), 11)]

    n_match = 0
    pos_total = pos_agree = 0
    max_diff = 0.0
    for reading, ctx in cases:
        prompt = build_prompt(reading, ctx)
        ref_text, ref_ids = greedy(tok, hf, prompt, max_new=200)
        p_ids = tok.encode(prompt)
        got_text = tok.decode(cm.greedy(p_ids, max_new=200))
        ok = ref_text == got_text
        n_match += ok
        # 元モデルの出力列に沿って、出力部分の各位置を比較
        with torch.no_grad():
            ref_logits = hf(torch.tensor([ref_ids])).logits[0].numpy()
        got_logits = cm.logits(ref_ids)
        sl = slice(len(p_ids) - 1, len(ref_ids))
        pos_total += sl.stop - sl.start
        pos_agree += int((ref_logits[sl].argmax(-1) == got_logits[sl].argmax(-1)).sum())
        max_diff = max(max_diff, float(np.abs(ref_logits[sl] - got_logits[sl]).max()))
        mark = "✓" if ok else "✗"
        print(f"{mark} [{len(ref_ids)} tok] {reading} -> {ref_text}" + ("" if ok else f"   [coreml: {got_text}]"))

    print(f"\n貪欲変換の一致: {n_match}/{len(cases)}")
    print(f"出力位置の argmax 一致: {pos_agree}/{pos_total}  ロジット最大誤差: {max_diff:.3f}")

    x = np.full((1, cm.seq), PAD, dtype=np.int32)
    for _ in range(10):
        cm.model.predict({"input_ids": x})
    ts = []
    for _ in range(200):
        t0 = time.perf_counter()
        cm.model.predict({"input_ids": x})
        ts.append((time.perf_counter() - t0) * 1000)
    print(f"forward 1 回 ({args.units}, S={cm.seq}): p50={np.percentile(ts, 50):.2f}ms p95={np.percentile(ts, 95):.2f}ms")


if __name__ == "__main__":
    main()
