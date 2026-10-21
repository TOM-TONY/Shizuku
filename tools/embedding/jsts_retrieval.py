"""公開データ（JGLUE の JSTS）で、文の埋め込みのモデル（ModelCatalog の形のフォルダ、または .mlpackage）を比べる。

- STS: 2 文のコサイン類似度と人手の点（0〜5）の Spearman 順位相関
- 検索: 点が min_label 以上の組の sentence1 を問いにし、全部の sentence2（重複なし）から相手を探す。Recall@1/5・MRR
  - BM25: PersonalCorpus と同じ式（文字の 2-gram、空白を除く、文の中の回数は 1、k1 = 1.2・b = 0.75、同点は新しい方）
  - 意味だけ: 内積の順
  - RRF: PersonalCorpus.fused と同じ（k = 60、それぞれ上位 200、意味の重み w）。BM25 に意味を足して良くなるかを見る
- 1 文の時間（Core ML の predict。Python からの呼び出しを含む目安）

使い方（-I で。ダウンロードしたフォルダの中のものを import しないように）:
  build/.venv-convert/bin/python -I tools/embedding/jsts_retrieval.py <out.json> <jsts.json>... --model name=<フォルダ or .mlpackage>[,tokenizer=<tokenizer.json>,length=64,query=..,document=..,sts=..] ...
"""
import argparse
import json
import math
import time

import coremltools as ct
import numpy as np
from tokenizers import Tokenizer

FUSION_K = 60.0
FUSION_DEPTH = 200


def load_pairs(paths):
    pairs = []
    for path in paths:
        with open(path) as f:
            for line in f:
                row = json.loads(line)
                pairs.append((row["sentence1"], row["sentence2"], float(row["label"])))
    return pairs


class Embedder:
    def __init__(self, spec, units):
        fields = dict(item.split("=", 1) for item in spec.split(","))
        self.name = fields.pop("name")
        path = fields.pop("path")
        info = {}
        if not path.endswith(".mlpackage"):
            info = json.load(open(path + "/embedding.json"))
            model_path = path + "/embedder.mlmodelc"
            fields.setdefault("tokenizer", path + "/tokenizer.json")
        else:
            model_path = path
        self.length = int(fields.get("length", info.get("length", 64)))
        self.query = fields.get("query", info.get("queryPrefix", ""))
        self.document = fields.get("document", info.get("documentPrefix", ""))
        self.sts = fields.get("sts", "")
        self.tokenizer = Tokenizer.from_file(fields["tokenizer"])
        if model_path.endswith(".mlmodelc"):
            self.model = ct.models.CompiledMLModel(model_path, compute_units=units)
        else:
            self.model = ct.models.MLModel(model_path, compute_units=units)
        self.truncated = 0

    def embed(self, text):
        ids = self.tokenizer.encode(text).ids
        if len(ids) > self.length:
            self.truncated += 1
            ids = ids[: self.length]
        mask = [1] * len(ids) + [0] * (self.length - len(ids))
        ids = ids + [0] * (self.length - len(ids))
        out = self.model.predict({"input_ids": np.array([ids], np.int32), "attention_mask": np.array([mask], np.int32)})
        return np.asarray(out["embedding"][0], dtype=np.float32)


def spearman(a, b):
    def ranks(x):
        order = np.argsort(x, kind="stable")
        r = np.empty(len(x))
        r[order] = np.arange(len(x))
        # 同順位は平均の順位
        values = np.asarray(x)[order]
        start = 0
        for i in range(1, len(x) + 1):
            if i == len(x) or values[i] != values[start]:
                r[order[start:i]] = (start + i - 1) / 2
                start = i
        return r
    ra, rb = ranks(np.asarray(a)), ranks(np.asarray(b))
    return float(np.corrcoef(ra, rb)[0, 1])


def bigrams(text):
    chars = [c for c in text if not c.isspace()]
    if len(chars) < 2:
        return chars
    return [chars[i] + chars[i + 1] for i in range(len(chars) - 1)]


class BM25:
    def __init__(self, docs, k1=1.2, b=0.75):
        self.index = {}
        self.lengths = [len(d) for d in docs]
        self.average = sum(self.lengths) / len(docs)
        self.total = len(docs)
        self.k1, self.b = k1, b
        for i, d in enumerate(docs):
            for g in set(bigrams(d)):
                self.index.setdefault(g, []).append(i)

    def rank(self, query):
        scores = {}
        for g in sorted(set(bigrams(query))):
            postings = self.index.get(g)
            if not postings:
                continue
            idf = math.log(1 + (self.total - len(postings) + 0.5) / (len(postings) + 0.5))
            for i in postings:
                scores[i] = scores.get(i, 0) + idf * (self.k1 + 1) / (1 + self.k1 * ((1 - self.b) + self.b * self.lengths[i] / self.average))
        return [i for i, _ in sorted(scores.items(), key=lambda kv: (-kv[1], -kv[0]))]


def fused(bm25, semantic, weight):
    scores, bm25_rank = {}, {}
    for rank, i in enumerate(bm25[:FUSION_DEPTH]):
        scores[i] = scores.get(i, 0) + 1 / (FUSION_K + rank + 1)
        bm25_rank[i] = rank
    for rank, i in enumerate(semantic[:FUSION_DEPTH]):
        scores[i] = scores.get(i, 0) + weight / (FUSION_K + rank + 1)
    order = sorted(scores, key=lambda i: (-scores[i], bm25_rank.get(i, 1 << 30), i))
    seen = set(order)
    return order + [i for i in bm25[FUSION_DEPTH:] if i not in seen]


def retrieval_metrics(rankings, golds):
    r1 = r5 = mrr = 0.0
    per_item = []
    for ranking, gold in zip(rankings, golds):
        try:
            position = ranking.index(gold)
        except ValueError:
            position = None
        hit1 = position == 0
        hit5 = position is not None and position < 5
        rr = 0.0 if position is None else 1 / (position + 1)
        r1 += hit1
        r5 += hit5
        mrr += rr
        per_item.append(rr)
    n = len(golds)
    return {"recall@1": r1 / n, "recall@5": r5 / n, "mrr": mrr / n, "count": n}, per_item


def bootstrap_diff(a, b, seed=42, resamples=2000):
    """項目ごとの差（b − a）の平均と 95% 区間（項目単位の復元抽出）"""
    diff = np.asarray(b) - np.asarray(a)
    rng = np.random.default_rng(seed)
    means = np.sort([diff[rng.integers(0, len(diff), len(diff))].mean() for _ in range(resamples)])
    return {"mean": float(diff.mean()), "lower": float(means[int(resamples * 0.025)]), "upper": float(means[int(resamples * 0.975)])}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("jsts", nargs="+")
    parser.add_argument("--model", action="append", required=True)
    parser.add_argument("--units", default="cpu_and_ne", choices=["cpu_and_ne", "cpu_and_gpu", "cpu_only", "all"])
    parser.add_argument("--min-label", type=float, default=4.0)
    parser.add_argument("--weights", default="0.5,1,2")
    args = parser.parse_args()
    units = {"cpu_and_ne": ct.ComputeUnit.CPU_AND_NE, "cpu_and_gpu": ct.ComputeUnit.CPU_AND_GPU,
             "cpu_only": ct.ComputeUnit.CPU_ONLY, "all": ct.ComputeUnit.ALL}[args.units]
    pairs = load_pairs(args.jsts)
    docs = sorted({s2 for _, s2, _ in pairs})
    doc_index = {d: i for i, d in enumerate(docs)}
    queries = [(s1, doc_index[s2]) for s1, s2, label in pairs if label >= args.min_label]
    bm25 = BM25(docs)
    bm25_rankings = [bm25.rank(q) for q, _ in queries]
    golds = [g for _, g in queries]
    result = {"pairs": len(pairs), "documents": len(docs), "queries": len(queries), "min_label": args.min_label,
              "units": args.units, "bm25": retrieval_metrics(bm25_rankings, golds)[0], "models": {}}
    _, bm25_items = retrieval_metrics(bm25_rankings, golds)
    print(f"BM25: {result['bm25']}")
    for spec in args.model:
        embedder = Embedder(spec, units)
        start = time.perf_counter()
        doc_vectors = np.stack([embedder.embed(embedder.document + d) for d in docs])
        doc_seconds = time.perf_counter() - start
        query_vectors = np.stack([embedder.embed(embedder.query + q) for q, _ in queries])
        sims = query_vectors @ doc_vectors.T
        semantic_rankings = [list(np.lexsort((-np.arange(len(docs)), -row))) for row in sims]
        semantic, semantic_items = retrieval_metrics(semantic_rankings, golds)
        entry = {"semantic": semantic, "semantic_vs_bm25_mrr": bootstrap_diff(bm25_items, semantic_items), "fused": {}}
        for w in [float(x) for x in args.weights.split(",")]:
            fused_rankings = [fused(b, s, w) for b, s in zip(bm25_rankings, semantic_rankings)]
            metrics, items = retrieval_metrics(fused_rankings, golds)
            metrics["mrr_vs_bm25"] = bootstrap_diff(bm25_items, items)
            entry["fused"][str(w)] = metrics
        # STS（対称の接頭辞）
        cache = {}
        def sts_vec(t):
            if t not in cache:
                cache[t] = embedder.embed(embedder.sts + t)
            return cache[t]
        cos = [float(sts_vec(a) @ sts_vec(b)) for a, b, _ in pairs]
        entry["sts_spearman"] = spearman(cos, [l for _, _, l in pairs])
        entry["ms_per_sentence"] = doc_seconds * 1000 / len(docs)
        entry["truncated"] = embedder.truncated
        entry["prefixes"] = {"query": embedder.query, "document": embedder.document, "sts": embedder.sts}
        entry["semantic_items_rr"] = semantic_items
        result["models"][embedder.name] = entry
        print(embedder.name, json.dumps({k: v for k, v in entry.items() if k != "semantic_items_rr"}, ensure_ascii=False))
    result["bm25_items_rr"] = bm25_items
    json.dump(result, open(args.out, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
