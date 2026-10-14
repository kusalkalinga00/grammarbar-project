#!/usr/bin/env python
"""
Extra probe (NOT part of the 20-case contract): tense / meaning invariance.

PLAN-v2.md 0.1 (Bug A) is the failure that motivated TenseGuard: Apple's on-device
engine rewrote "i has a apple" -> "I had an apple" and "she study hard" ->
"She studied hard", i.e. it *invented a past tense* on an already-ambiguous
sentence.  The 6 already-correct cases in the main set are too easy to catch
that, so this probe asks the same question of the specialists with sentences
whose tense is deliberate and where a tense shift would be a meaning change.

A model that returns all eight byte-identical has demonstrated tense
preservation on inputs that contain no error to correct.  A model that shifts
one has demonstrated Bug A.

Run: Bench/.venv/bin/python Bench/gec/run_tense_probe.py
"""
from __future__ import annotations

import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
RESULTS = HERE / "results"

PROBES = [
    ("t1", "I have lived in Berlin for three years."),
    ("t2", "She had already left when I called."),
    ("t3", "We will be launching the beta next week."),
    ("t4", "He was reading when the phone rang."),
    ("t5", "They have been waiting since noon."),
    ("t6", "If I were you, I would have gone earlier."),
    ("t7", "The committee meets on Tuesdays."),
    ("t8", "He is more experienced than his brother."),
]

CANDIDATES = [
    ("Unbabel/gec-t5_small", "gec: {text}", "greedy"),
    ("vennify/t5-base-grammar-correction", "grammar: {text}", "greedy"),
    ("pszemraj/grammar-synthesis-small", "{text}", "greedy"),
    ("visheratin/t5-efficient-tiny-grammar-correction", "{text}", "greedy"),
    ("gotutiyan/gec-t5-small-clang8", "{text}", "greedy"),
    ("abhinavsarkar/Google-T5-base-Grammatical_Error_Correction-Finetuned-C4-200M-550k", "{text}", "greedy"),
]


def main():
    import torch
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    out_all = {}
    for mid, tmpl, dec in CANDIDATES:
        try:
            tok = AutoTokenizer.from_pretrained(mid)
            model = AutoModelForSeq2SeqLM.from_pretrained(mid)
            model.eval()
        except Exception as e:
            print(f"{mid}: LOAD ERROR {type(e).__name__}: {e}")
            out_all[mid] = {"load_error": f"{type(e).__name__}: {e}"}
            continue
        rows = []
        for pid, text in PROBES:
            enc = tok(tmpl.format(text=text), return_tensors="pt",
                      truncation=True, max_length=512)
            with torch.no_grad():
                gen = model.generate(**enc, max_new_tokens=128, do_sample=False, num_beams=1)
            o = tok.decode(gen[0], skip_special_tokens=True).strip()
            rows.append({"probe": pid, "input": text, "output": o,
                         "unchanged": o == text})
        ident = sum(r["unchanged"] for r in rows)
        out_all[mid] = {"template": tmpl, "decoding": dec,
                        "unchanged_of_8": ident, "cases": rows}
        print(f"{mid:52s} tense-preserved {ident}/8")
        for r in rows:
            if not r["unchanged"]:
                print(f"    {r['probe']} {r['input']!r} -> {r['output']!r}")
    (RESULTS / "tense_probe.json").write_text(json.dumps(out_all, indent=2))
    print("->", RESULTS / "tense_probe.json")


if __name__ == "__main__":
    main()
