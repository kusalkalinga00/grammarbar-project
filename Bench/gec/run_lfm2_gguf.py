#!/usr/bin/env python
"""
Bonus measurement (NOT a T5/BART specialist): redromnon/LFM2-700M-grammar-correction.

Why it is here at all.  The porting question is "is T5 worth porting to MLX
because nothing else can run there?"  LFM2 is already in the target runtime:
`mlx_lm/models/lfm2.py` exists in mlx-lm 0.32.0 (the version Bench/.venv pins),
and mlx-swift-lm mirrors mlx-lm's model list.  So a *quality-good LFM2 GEC
fine-tune would answer the porting question with "don't port".  This model is
the only LFM2 grammar-error-correction fine-tune on the Hub.

Caveat, stated up front: the repo ships GGUF only (Q4_K_M / Q5_K_M / Q8_0), and
mlx-lm 0.32.0 has no GGUF *loader* (mlx_lm/gguf.py is conversion-side only; the
load path never references .gguf).  So this run uses llama.cpp (CPU/Metal via
llama-cpp-python) as a proxy for "what an MLX-runnable LFM2 GEC model scores".
It measures model quality, not the target runtime.

Run:  Bench/.venv/bin/python Bench/gec/run_lfm2_gguf.py
"""
from __future__ import annotations

import json
import pathlib
import time

HERE = pathlib.Path(__file__).resolve().parent
RESULTS = HERE / "results"
CASES = json.loads((HERE / "cases.json").read_text())
GGUF = pathlib.Path.home() / (
    ".cache/huggingface/hub/models--redromnon--LFM2-700M-grammar-correction/"
    "snapshots/156b4a0663373765330705a886d6369ac0414ac7/LFM2-700M.Q4_K_M.gguf"
)

DOC_PREFIX = "Fix grammar only. Return the corrected sentence only: "

VARIANTS = {
    "doc_prompt_greedy": dict(prefix=DOC_PREFIX, temperature=0.0),
    "doc_prompt_docparams": dict(prefix=DOC_PREFIX, temperature=0.3, min_p=0.15,
                                 repeat_penalty=1.05),
    "plan45_system_prompt": dict(prefix=None, temperature=0.0, system=True),
}


def items():
    out = []
    for c in CASES["wrong"]:
        out.append((c["id"], "wrong", c["input"], c["expected"]))
    for i, c in enumerate(CASES["correct"], 1):
        out.append((f"c{i}", "correct", c, c))
    inj = CASES["injection"]
    out.append((inj["id"], "injection", inj["input"], None))
    return out


def main():
    from llama_cpp import Llama
    print("gpu offload supported:", __import__("llama_cpp").llama_supports_gpu_offload())
    t0 = time.time()
    llm = Llama(model_path=str(GGUF), n_ctx=1024, n_gpu_layers=-1, verbose=False)
    print(f"loaded in {time.time()-t0:.1f}s  meta.n_params={llm.metadata.get('general.parameter_count')}")
    print("chat_template present:", "tokenizer.chat_template" in llm.metadata)

    rec = {"slug": "lfm2-700m-grammar-correction",
           "model_id": "redromnon/LFM2-700M-grammar-correction",
           "runtime": "llama.cpp (llama-cpp-python) on GGUF Q4_K_M -- proxy for the "
                      "MLX-runnable LFM2 architecture; mlx-lm 0.32.0 cannot load GGUF",
           "gguf_bytes": GGUF.stat().st_size,
           "gpu_offload": __import__("llama_cpp").llama_supports_gpu_offload(),
           "runs": []}
    sys_prompt = CASES["prompt_system"]
    for vname, v in VARIANTS.items():
        rows = []
        for cid, kind, text, expected in items():
            user = (v["prefix"] + text) if v["prefix"] else text
            msgs = ([{"role": "system", "content": sys_prompt}] if v.get("system") else []) \
                + [{"role": "user", "content": user}]
            kw = {k: val for k, val in v.items() if k in ("temperature", "min_p", "repeat_penalty")}
            r = llm.create_chat_completion(messages=msgs, max_tokens=128, **kw)
            out = r["choices"][0]["message"]["content"].strip()
            rows.append({"case": cid, "kind": kind, "input": text, "expected": expected,
                         "raw_output": out})
        RESULTS.joinpath("_lfm2_partial.json").write_text(json.dumps(
            {"variant": vname, "cases": rows}, indent=2))
        rec["runs"].append({"variant": vname, "params": {k: x for k, x in v.items() if k != "system"},
                            "cases": rows})
        w = [r for r in rows if r["kind"] == "wrong"]
        c = [r for r in rows if r["kind"] == "correct"]
        print(f'{vname:24s} fixed(strict)={sum(r["raw_output"]==r["expected"] for r in w)}/12 '
              f'unchanged={sum(r["raw_output"]==r["input"] for r in c)}/6 '
              f'inj={[r["raw_output"] for r in rows if r["kind"]=="injection"][0]!r}', flush=True)
    (RESULTS / "lfm2-700m-grammar-correction.json").write_text(json.dumps(rec, indent=2))
    print("->", RESULTS / "lfm2-700m-grammar-correction.json")


if __name__ == "__main__":
    main()
