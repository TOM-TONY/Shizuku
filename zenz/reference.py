"""Hugging Face の元モデル（PyTorch, fp32）で Zenzai v3 の貪欲変換を行う比較基準。"""
import sys
import torch
from transformers import GPT2LMHeadModel, GPT2TokenizerFast

INPUT_TAG, OUTPUT_TAG, CONTEXT_TAG = "", "", ""


def hira_to_kata(s: str) -> str:
    return "".join(chr(ord(c) + 0x60) if "ぁ" <= c <= "ゖ" else c for c in s)


def build_prompt(reading: str, left_context: str = "") -> str:
    p = ""
    if left_context:
        p += CONTEXT_TAG + left_context[-40:]
    return p + INPUT_TAG + hira_to_kata(reading) + OUTPUT_TAG


def load(model_dir: str):
    tok = GPT2TokenizerFast.from_pretrained(model_dir)
    model = GPT2LMHeadModel.from_pretrained(model_dir, torch_dtype=torch.float32).eval()
    return tok, model


@torch.no_grad()
def greedy(tok, model, prompt: str, eos_ids=(3,), max_new: int = 40):
    # BOS は付けない（GPT-2 系の GGUF では llama.cpp も BOS を付与しない。付けると変換精度が落ちる）
    ids = tok.encode(prompt)
    start = len(ids)
    for _ in range(max_new):
        logits = model(torch.tensor([ids])).logits[0, -1]
        nxt = int(logits.argmax())
        if nxt in eos_ids:
            break
        ids.append(nxt)
    return tok.decode(ids[start:]), ids


if __name__ == "__main__":
    model_dir = sys.argv[1] if len(sys.argv) > 1 else "models/hf/zenz-v3.1-xsmall"
    tok, model = load(model_dir)
    print("special:", tok.bos_token_id, tok.eos_token_id, tok.pad_token_id)
    cases = [("きょうはいしゃにいく", ""), ("わたしはきのうとうきょうでむかしのともだちにあった", ""),
             ("かいぎのしりょうをおくります", "お世話になっております。")]
    for r, ctx in cases:
        out, ids = greedy(tok, model, build_prompt(r, ctx), {tok.eos_token_id})
        print(f"{r} -> {out}   ({len(ids)} tok)")
