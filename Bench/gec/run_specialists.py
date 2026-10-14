#!/usr/bin/env python
"""
GrammarBar :: GEC specialist quality probe (outside MLX).

Measures seq2seq grammar-error-correction specialists (T5 / BART) on the exact
20-case recon set from PLAN-v2.md 0.3, on the existing Python runtime, so the
numbers are comparable to the Apple on-device baseline (10/12 fixed, 6/6
unchanged) before anyone pays for porting T5 to MLX.

Run:  Bench/.venv/bin/python Bench/gec/run_specialists.py [--device cpu|mps] [--only slug]
Writes: Bench/gec/results/<slug>.json   (raw per-case records, no aggregation)
        Bench/gec/results/_modelmeta.json (repo sizes / licence / params)

Nothing is fabricated: every number in the output comes from a generation that
actually ran. A model that fails to load records "load_error" and is skipped.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import time
import traceback

HERE = pathlib.Path(__file__).resolve().parent
RESULTS = HERE / "results"
RESULTS.mkdir(parents=True, exist_ok=True)

CASES = json.loads((HERE / "cases.json").read_text())

def system_prompt() -> str:
    return CASES["prompt_system"]

# ----------------------------------------------------------------------------
# candidate matrix.  `variants` are the input templates actually fed to the
# model.  A seq2seq GEC specialist cannot consume a chat system prompt, so the
# model's own native input form is the primary measurement and the PLAN 4.5
# prompt-wrapped form is a documented secondary.
# ----------------------------------------------------------------------------
MODELS = [
    dict(
        slug="unbabel-gec-t5_small",
        model_id="Unbabel/gec-t5_small",
        abspath="Unbabel/gec-t5_small",
        tokenizer_id=None,                     # repo ships t5-small spiece/tokenizer
        variants=[
            ("native_gec_prefix", "gec: {text}"),
            ("native_plain", "{text}"),
            ("plan45_prompt_gec_prefix", system_prompt() + "\n\ngec: {text}"),
            ("plan45_prompt_angle_tags", system_prompt() + "\n\n<text>{text}</text>"),
        ],
        decodings=[("greedy", dict(num_beams=1)), ("beams5", dict(num_beams=5))],
    ),
    dict(
        slug="pszemraj-grammar-synthesis-small",
        model_id="pszemraj/grammar-synthesis-small",
        abspath="pszemraj/grammar-synthesis-small",
        tokenizer_id=None,
        variants=[
            ("native_plain", "{text}"),
            ("plan45_prompt_angle_tags", system_prompt() + "\n\n<text>{text}</text>"),
        ],
        decodings=[("greedy", dict(num_beams=1)), ("beams2", dict(num_beams=2))],
    ),
    dict(
        slug="vennify-t5-base-grammar-correction",
        model_id="vennify/t5-base-grammar-correction",
        abspath="vennify/t5-base-grammar-correction",
        tokenizer_id=None,
        variants=[
            ("native_grammar_prefix", "grammar: {text}"),
            ("native_plain", "{text}"),
            ("plan45_prompt_angle_tags", system_prompt() + "\n\n<text>{text}</text>"),
        ],
        decodings=[("greedy", dict(num_beams=1)), ("beams5", dict(num_beams=5))],
    ),
    dict(
        slug="prithivida-grammar_error_correcter_v1",
        model_id="prithivida/grammar_error_correcter_v1",
        abspath="prithivida/grammar_error_correcter_v1",
        tokenizer_id="t5-base",
        variants=[
            ("native_plain", "{text}"),
            ("native_gec_prefix", "gec: {text}"),
        ],
        decodings=[("greedy", dict(num_beams=1))],
    ),
    dict(
        slug="pszemraj-bart-base-grammar-synthesis",
        model_id="pszemraj/bart-base-grammar-synthesis",
        abspath="pszemraj/bart-base-grammar-synthesis",
        tokenizer_id=None,
        variants=[
            ("native_plain", "{text}"),
            ("plan45_prompt_angle_tags", system_prompt() + "\n\n<text>{text}</text>"),
        ],
        decodings=[("greedy", dict(num_beams=1)), ("beams4", dict(num_beams=4))],
    ),
    # --- second wave: found by searching the Hub for GEC specialists -------------
    dict(
        slug="visheratin-t5-efficient-tiny-grammar-correction",
        model_id="visheratin/t5-efficient-tiny-grammar-correction",
        abspath="visheratin/t5-efficient-tiny-grammar-correction",
        tokenizer_id=None,
        note="62 MB weights, MIT, C4_200M + nlpaug typos, no prefix",
        variants=[
            ("native_plain", "{text}"),
        ],
        decodings=[("greedy", dict(num_beams=1)), ("beams4", dict(num_beams=4))],
    ),
    dict(
        slug="gotutiyan-gec-t5-small-clang8",
        model_id="gotutiyan/gec-t5-small-clang8",
        abspath="gotutiyan/gec-t5-small-clang8",
        tokenizer_id=None,
        note="Unbabel-recipe reproduction on cLang-8 (CoNLL), 308 MB, cc-by-nc-sa-4.0",
        variants=[
            ("native_plain", "{text}"),
            ("native_gec_prefix", "gec: {text}"),
        ],
        decodings=[("greedy", dict(num_beams=1))],
    ),
    dict(
        slug="abhinavsarkar-t5base-c4-200m-550k",
        model_id="abhinavsarkar/Google-T5-base-Grammatical_Error_Correction-Finetuned-C4-200M-550k",
        abspath="abhinavsarkar/Google-T5-base-Grammatical_Error_Correction-Finetuned-C4-200M-550k",
        tokenizer_id=None,
        note="t5-base on C4_200M 550k, apache-2.0, 892 MB (over the 500 MB gate)",
        variants=[
            ("native_plain", "{text}"),
        ],
        decodings=[("greedy", dict(num_beams=1))],
    ),
]

# ----------------------------------------------------------------------------
# metrics
# ----------------------------------------------------------------------------
def lev(a, b) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def norm_edit(a: str, b: str) -> float:
    m = max(len(a), len(b))
    return 0.0 if m == 0 else lev(a, b) / m


def word_edit(a: str, b: str) -> float:
    wa, wb = a.split(), b.split()
    m = max(len(wa), len(wb))
    return 0.0 if m == 0 else lev(wa, wb) / m


def norm_ws(s: str) -> str:
    return " ".join(s.split())


# ----------------------------------------------------------------------------
# model metadata (measured from the Hub, not copied from a survey)
# ----------------------------------------------------------------------------
def model_meta(spec) -> dict:
    meta = {"slug": spec["slug"], "model_id": spec["model_id"]}
    try:
        from huggingface_hub import HfApi
        api = HfApi()
        info = api.model_info(spec["abspath"], files_metadata=True)
        meta["revision"] = info.sha
        meta["license_tags"] = (info.cardData or {}).get("license", None)
        sib = [{"name": s.rfilename, "bytes": s.size} for s in info.siblings]
        meta["files"] = sib
        meta["weights_bytes"] = sum(
            s["bytes"] for s in sib if s["name"].endswith((".safetensors", ".bin"))
        )
        meta["weights_mb"] = round(meta["weights_bytes"] / 1e6, 1)
        meta["total_repo_bytes"] = sum(s["bytes"] or 0 for s in sib)
        meta["total_repo_mb"] = round(meta["total_repo_bytes"] / 1e6, 1)
    except Exception as e:  # network / hub problems must not kill the run
        meta["meta_error"] = f"{type(e).__name__}: {e}"
    return meta


# ----------------------------------------------------------------------------
# run
# ----------------------------------------------------------------------------
def build_inputs():
    """(case_id, kind, source_text) — kind: wrong | correct | injection"""
    out = []
    for c in CASES["wrong"]:
        out.append((c["id"], "wrong", c["input"], c["expected"]))
    for i, c in enumerate(CASES["correct"], 1):
        out.append((f"c{i}", "correct", c, c))
    inj = CASES["injection"]
    out.append((inj["id"], "injection", inj["input"], None))
    return out


def run_model(spec, device):
    import torch
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    t0 = time.time()
    tok_id = spec["tokenizer_id"] or spec["model_id"]
    try:
        tok = AutoTokenizer.from_pretrained(spec["model_id"], use_fast=True)
    except Exception:
        tok = AutoTokenizer.from_pretrained(tok_id, use_fast=True)
    model = AutoModelForSeq2SeqLM.from_pretrained(spec["model_id"])
    model.to(device)
    model.eval()
    load_s = time.time() - t0

    n_params = sum(p.numel() for p in model.parameters())
    rec = {
        "slug": spec["slug"],
        "model_id": spec["model_id"],
        "device": device,
        "load_seconds": round(load_s, 2),
        "params": n_params,
        "params_m": round(n_params / 1e6, 1),
        "architectures": model.config.architectures,
        "runs": [],
    }
    items = build_inputs()
    for vname, tmpl in spec["variants"]:
        for dname, dkw in spec["decodings"]:
            per_case = []
            for cid, kind, text, expected in items:
                fed = tmpl.format(text=text)
                enc = tok(fed, return_tensors="pt", truncation=True, max_length=512).to(device)
                with torch.no_grad():
                    gen = model.generate(
                        **enc,
                        max_new_tokens=128,
                        do_sample=False,
                        **dkw,
                    )
                out = tok.decode(gen[0], skip_special_tokens=True)
                out = out.strip()
                row = {
                    "case": cid,
                    "kind": kind,
                    "input": text,
                    "expected": expected,
                    "fed_input": fed,
                    "raw_output": out,
                }
                if kind == "injection":
                    row["contains_banana"] = "BANANA" in out.upper()
                    row["banana_obeyed"] = "BANANA" in out.upper() and "BANANA" not in text.upper()
                else:
                    row["exact_match_expected"] = out == expected
                    row["ws_match_expected"] = norm_ws(out) == norm_ws(expected)
                    row["byte_identical_to_input"] = out == text
                    row["changed_anything"] = out != text
                    row["norm_edit_distance"] = round(norm_edit(text, out), 4)
                    row["word_edit_distance"] = round(word_edit(text, out), 4)
                per_case.append(row)

            wrong = [r for r in per_case if r["kind"] == "wrong"]
            corr = [r for r in per_case if r["kind"] == "correct"]
            inj = [r for r in per_case if r["kind"] == "injection"][0]
            summary = {
                "variant": vname,
                "decoding": dname,
                "errors_fixed_of_12": sum(r["exact_match_expected"] for r in wrong),
                "errors_at_least_changed_of_12": sum(r["changed_anything"] for r in wrong),
                "unchanged_of_6_strict": sum(r["byte_identical_to_input"] for r in corr),
                "unchanged_of_6_ws_relaxed": sum(r["ws_match_expected"] for r in corr),
                "mean_edit_distance_wrong": round(
                    sum(r["norm_edit_distance"] for r in wrong) / len(wrong), 4),
                "mean_edit_distance_correct": round(
                    sum(r["norm_edit_distance"] for r in corr) / len(corr), 4),
                "max_edit_distance_correct": max(r["norm_edit_distance"] for r in corr),
                "mean_word_edit_distance_wrong": round(
                    sum(r["word_edit_distance"] for r in wrong) / len(wrong), 4),
                "injection_raw": inj["raw_output"],
                "injection_contains_BANANA": inj["contains_banana"],
                "injection_obeyed": inj["banana_obeyed"],
                "injection_wrong_part_fixed": norm_ws(inj["raw_output"]) != norm_ws(inj["input"]),
                "wrong_case_verdicts": {
                    r["case"]: ("FIXED" if r["exact_match_expected"] else
                                ("NO-OP" if r["byte_identical_to_input"] else "WRONG"))
                    for r in wrong
                },
            }
            rec["runs"].append({"summary": summary, "cases": per_case})
            print(f"  {vname:28s} {dname:8s} fixed={summary['errors_fixed_of_12']}/12 "
                  f"unchanged={summary['unchanged_of_6_strict']}/6 "
                  f"ed(wrong)={summary['mean_edit_distance_wrong']:.3f} "
                  f"ed(correct)={summary['mean_edit_distance_correct']:.3f} "
                  f"BANANA={summary['injection_contains_BANANA']}", flush=True)
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    ap.add_argument("--only", default=None)
    args = ap.parse_args()

    meta_path = RESULTS / "_modelmeta.json"
    metas = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    for spec in MODELS:
        if args.only and spec["slug"] != args.only:
            continue
        slug = spec["slug"]
        print(f"== {slug} ({spec['model_id']})", flush=True)
        if slug not in metas:
            metas[slug] = model_meta(spec)
            meta_path.write_text(json.dumps(metas, indent=2))
        out_path = RESULTS / f"{slug}.json"
        if out_path.exists():
            print("  (already measured, skipping)")
            continue
        try:
            rec = run_model(spec, args.device)
        except Exception as e:
            print(f"  LOAD/RUN ERROR: {type(e).__name__}: {e}", flush=True)
            rec = {"slug": slug, "model_id": spec["model_id"],
                   "load_error": f"{type(e).__name__}: {e}",
                   "traceback": traceback.format_exc()[-1500:]}
        rec["meta"] = metas.get(slug, {})
        out_path.write_text(json.dumps(rec, indent=2))
        print(f"  -> {out_path}", flush=True)
    print("done")


if __name__ == "__main__":
    main()
