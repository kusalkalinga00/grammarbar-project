#!/usr/bin/env python3
"""
GrammarBar model survey -- candidate enumeration and EXACT size/licence lookup.

This is the survey tool (one-off, 2026-10-14). It does NOT benchmark; it answers
"what exists, how big is it exactly, what licence is it actually under".

Sizes come from the Hugging Face API with ?blobs=true (per-file byte counts),
never from an estimate. The sum reported is:

    weights_bytes  = sum of *.safetensors / *.gguf / *.bin files
    download_bytes = sum of ALL files in the repo except .gitattributes
                     (what the app would actually have to fetch)

Run:
    Bench/.venv/bin/python Bench/survey_candidates.py --fetch     # query HF API
    Bench/.venv/bin/python Bench/survey_candidates.py --report    # print table

Writes Bench/survey/candidates.json.
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
SURVEY_DIR = BENCH_DIR / "survey"
OUT = SURVEY_DIR / "candidates.json"

HF_API = "https://huggingface.co/api/models/"

# ---------------------------------------------------------------------------
# Seeds. Every family the brief named, plus the things a keyword sweep turns up.
# ---------------------------------------------------------------------------

# A. Grammar-error-correction SPECIALISTS (the gap in round 1)
SPECIALISTS = [
    # --- T5 / FLAN-T5 grammar-synthesis line ---------------------------------
    "vennify/t5-base-grammar-correction",
    "pszemraj/flan-t5-large-grammar-synthesis",
    "pszemraj/flan-t5-base-grammar-synthesis",
    "pszemraj/flan-t5-small-grammar-synthesis",
    "pszemraj/grammar-synthesis-small",
    "pszemraj/grammar-synthesis-base",
    "pszemraj/flan-t5-base-grammar-synthesis-2m",
    "grammarly/coedit-large",
    "grammarly/coedit-base",
    "grammarly/coedit-small",
    "prithivida/grammar_error_correcter_v1",
    "bharathkumarsm/grammar_correction_using_t5",
    "Ateeqq/Text-Rewriter-Paraphraser",
    "seduerr/grammar-error-corrector",
    "Unbabel/gec-t5_small",
    "Unbabel/gec-t5_base",
    "Unbabel/gec-t5-large",
    "team-watchdog/t5-base-grammar-correction",
    # --- BART-based ----------------------------------------------------------
    "facebook/bart-base",
    "pszemraj/bart-base-grammar-synthesis",
    "Rajkumar/punctuation_and_grammar_correction",
    # --- spelling / punctuation ---------------------------------------------
    "oliverguhr/spelling-correction-english-base",
    "oliverguhr/spelling-correction-multilingual-base",
    "oliverguhr/fullstop-punctuation-multilang-base",
    "felflare/bert-restore-punctuation",
    # --- BERT-class taggers (GECToR-style sequence tagging) -----------------
    "bert-base-uncased",
    "distilbert-base-uncased",
    "google/electra-small-discriminator",
]

# B. Small instruction-tuned models whose 4-bit conversion may fit < 500 MB
SMALL_LLM = [
    "mlx-community/Qwen3-0.6B-4bit",
    "mlx-community/Qwen3-0.6B-4bit-DWQ",
    "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
    "mlx-community/Qwen2.5-0.5B-Instruct-4bit-DWQ",
    "mlx-community/Qwen2-0.5B-Instruct-4bit",
    "mlx-community/Qwen1.5-0.5B-Chat-4bit",
    "mlx-community/gemma-3-270m-it-4bit",
    "mlx-community/gemma-3-270m-it-qat-4bit",
    "mlx-community/SmolLM2-360M-Instruct-4bit",
    "mlx-community/SmolLM2-135M-Instruct-4bit",
    "mlx-community/SmolLM-135M-Instruct-4bit",
    "mlx-community/LFM2-350M-4bit",
    "mlx-community/LFM2-700M-4bit",
    "mlx-community/Llama-3.2-1B-Instruct-4bit",
    "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit",
    "mlx-community/Phi-3.5-mini-instruct-4bit",
    "mlx-community/phi-2-4bit",
    "mlx-community/Hunyuan-0.5B-Instruct-4bit",
    "mlx-community/granite-3.0-1b-a400m-instruct-4bit",
    "mlx-community/Qwen3-0.6B-8bit",
    "HuggingFaceTB/SmolLM2-360M-Instruct",
    "Qwen/Qwen2.5-0.5B-Instruct",
]

# C. Keyword sweeps run against the HF search API
SEARCHES = [
    "grammar correction",
    "grammatical error correction",
    "gec",
    "grammar synthesis",
    "proofreading",
    "spelling correction",
    "mlx grammar",
    "gguf grammar",
    "mlx t5",
]

WEIGHT_SUFFIXES = (".safetensors", ".gguf", ".bin", ".h5", ".msgpack", ".onnx")
SKIP_FILES = (".gitattributes",)


def get_json(url: str, tries: int = 4):
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "GrammarBar-survey/1.0"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code in (401, 403, 404):
                return {"_http_error": e.code}
            last = e
        except Exception as e:  # noqa: BLE001
            last = e
        time.sleep(1.5 * (i + 1))
    return {"_error": repr(last)}


def model_info(model_id: str) -> dict:
    j = get_json(HF_API + model_id + "?blobs=true")
    if "_http_error" in j:
        return {"model_id": model_id, "error": f"HTTP {j['_http_error']}"}
    if "_error" in j:
        return {"model_id": model_id, "error": j["_error"]}

    siblings = j.get("siblings") or []
    files = []
    weights = 0
    download = 0
    for s in siblings:
        name = s.get("rfilename")
        size = s.get("size")
        if size is None:
            size = 0
        files.append({"name": name, "size": size})
        if any(name.endswith(x) for x in WEIGHT_SUFFIXES):
            weights += size
        if not any(name.endswith(x) for x in SKIP_FILES):
            download += size

    tags = j.get("tags") or []
    lic = [t.split(":", 1)[1] for t in tags if t.startswith("license:")]
    base = [t.split(":", 1)[1] for t in tags if t.startswith("base_model:")]
    quants = [t for t in tags if t.endswith("-bit")]

    return {
        "model_id": model_id,
        "sha": j.get("sha"),
        "last_modified": j.get("lastModified"),
        "gated": j.get("gated"),
        "disabled": j.get("disabled"),
        "private": j.get("private"),
        "pipeline_tag": j.get("pipeline_tag"),
        "library_name": j.get("library_name"),
        "license_tags": lic,
        "base_model_tags": base,
        "quant_tags": quants,
        "downloads": j.get("downloads"),
        "likes": j.get("likes"),
        "download_bytes": download,
        "download_mb": round(download / (1024 * 1024), 1),
        "weights_bytes": weights,
        "weights_mb": round(weights / (1024 * 1024), 1),
        "file_count": len(files),
        "files": sorted(files, key=lambda f: -f["size"])[:12],
        "under_500mb_download": download <= 500 * 1024 * 1024,
        "url": "https://huggingface.co/" + model_id,
    }


def search(query: str, limit: int = 40) -> list[dict]:
    j = get_json(
        f"https://huggingface.co/api/models?search={urllib.parse.quote(query)}"
        f"&limit={limit}&full=false&sort=downloads&direction=-1")
    if isinstance(j, dict):
        return []
    out = []
    for m in j:
        tags = m.get("tags") or []
        lic = [t.split(":", 1)[1] for t in tags if t.startswith("license:")]
        out.append({
            "model_id": m.get("modelId") or m.get("id"),
            "pipeline_tag": m.get("pipeline_tag"),
            "library_name": m.get("libraryName"),
            "license_tags": lic,
            "downloads": m.get("downloads"),
            "likes": m.get("likes"),
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--searches", action="store_true")
    args = ap.parse_args()

    SURVEY_DIR.mkdir(parents=True, exist_ok=True)
    data = {}
    if OUT.exists():
        data = json.loads(OUT.read_text())

    if args.fetch or args.searches:
        seeds = sorted(set(SPECIALISTS + SMALL_LLM))
        data.setdefault("models", {})
        for i, mid in enumerate(seeds, 1):
            print(f"[{i}/{len(seeds)}] {mid}", flush=True)
            data["models"][mid] = model_info(mid)
            time.sleep(0.3)
        if args.searches:
            data.setdefault("searches", {})
            for q in SEARCHES:
                print(f"search: {q}", flush=True)
                data["searches"][q] = search(q)
                time.sleep(0.5)
        OUT.write_text(json.dumps(data, indent=2, ensure_ascii=False))
        print(f"wrote {OUT}")

    if args.report:
        ms = data.get("models", {})
        rows = [m for m in ms.values() if "error" not in m]
        rows.sort(key=lambda m: m["download_mb"])
        print(f"{'model':58s} {'MB':>8s} {'weights MB':>10s}  {'<500':5s} license")
        for m in rows:
            print(f"{m['model_id'][:58]:58s} {m['download_mb']:>8.1f} "
                  f"{m['weights_mb']:>10.1f}  "
                  f"{'YES' if m['under_500mb_download'] else 'no ':5s} "
                  f"{','.join(m['license_tags']) or '(none)'}")
        print("\n-- errors --")
        for m in ms.values():
            if "error" in m:
                print(f"  {m['model_id']}: {m['error']}")
        print(f"\n{len(rows)} models resolved with exact sizes")
    return 0


if __name__ == "__main__":
    import sys
    import urllib.parse  # noqa: F401  (used by search)
    sys.exit(main())
