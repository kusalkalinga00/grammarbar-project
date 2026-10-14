# GrammarBar eval — Apple-engine baseline

**Run:** `2026-10-13T12:32Z` · `swift run GrammarBarEval --engine apple --set Eval/golden.jsonl --out Eval/results --label baseline`
**Artifacts:** `results/apple-baseline-2026-10-13.json` (634 KB, every per-case record) + `.txt`. Every number here is printed by `python3 Eval/analyse.py`, not transcribed by hand.

**Machine:** macOS 27.0.1 (26A434) · Apple M5 · arm64 · Apple Swift 6.4.
**Engine:** `SystemLanguageModel.default` — `availability = available`, `contextSize = 8192`.
**Set:** 260 cases = 200 wrong→right, 50 already-correct, 10 special.
**Passes:** `rawEngine` = one-shot `engine.correct(.angleTags)`, the call shape `recon/AppleEngineProbe.swift` used. `pipeline` = `CorrectionService.run`, i.e. what the app does (sanitize → validate → TenseGuard → no-op guard, with the retry ladders).

> **About the examples in this file.** Third-party corpus case text is deliberately
> **not reproduced here** — see `LICENSES.md`. Where the evidence was a corpus
> sentence, this document gives the case id, the classification and the counts
> instead. First-party (`recon`) examples are quoted freely. The unabridged version,
> which does quote corpus text and therefore stays local, is
> `RESULTS.full-corpus.md` (git-ignored).

---

## 1. Drift check against PLAN-v2.md §0.3 — **no drift**

The 20 recorded cases, re-measured with the same call shape. This is the check the plan commits to re-running after every macOS update.

| §0.3 recorded | measured now | |
|---|---|---|
| errors fixed **10/12** | **10/12** — same two misses (`w3`, `w6`) | ✅ reproduced |
| correct unchanged **6/6** | **6/6** (byte-identical) | ✅ reproduced |
| mean TTFT **362 ms** | **356 ms** | ✅ (1.7% apart, run noise) |
| mean total **435 ms** | **435 ms** | ✅ |
| cold first call **971 ms** | **1061 ms** | ⚠️ 9% higher, same order |

`w3` (`Me and him went to the store yesterday.`) and `w6` (`I have went to Paris…`) are unchanged misses in both runs: the engine declines pronoun case (`Me and him` → `He and I`) and leaves `I have went` rather than `I went`. **The engine has not drifted.** Anything below is a property of the expanded set, not a change in the model.

## 2. §8 metrics, full set (n=260)

| metric | rawEngine | pipeline (what ships) |
|---|---|---|
| errors fixed (wrong cases) | **93/200** (46.5%) | **83/200** (41.5%) |
| correct unchanged, byte-identical | **35/50** (70.0%) | **35/50** (70.0%) |
| TTFT mean | 381 ms | 639 ms¹ |
| TTFT p50 / p95 | **354 / 498 ms** | 515 / 1254 ms¹ |
| total mean | 568 ms | 639 ms |
| total p50 / p95 | 490 / 964 ms | 515 / 1254 ms |
| tense-guard flags | **23/260** | **0** on final output² |
| Σ tenseChanges / temporal cues | 28 / 26 | 1 / 26 |
| delimiter echoes | **1/260** | 0 |
| validator rejections | 36 | 36 |
| protected tokens lost (numbers/URLs/emails) | **0/260** | **0/260** |
| guardrail refusals | 13 | 13 |
| outcomes | corrected 179 · unchanged 68 · failed 13 | corrected 157 · unchanged 67 · flagged 23 · failed 13 |

¹ The pipeline's TTFT is time to the first emitted partial, and `CorrectionService` only emits one *after* the chunk has been generated **and** validated. It is not token-level TTFT and must not be quoted against NFR5. **NFR5 (<2 s warm): met, 381 ms mean / 498 ms p95 on the raw pass.**
² 0 because the guard's verdict is evaluated on the *final* output, and every case it fired on ended in either a substitution or a successful minimal-edit retry. The trigger rate is the rawEngine number, 23. See §4.

Cold first call (before `prewarm()`): **1061 ms** — the reason `prewarm()` exists.

By provenance (rawEngine): wrong repaired — recon 10/12, authored 7/8, BEA 36/81, JFLEG 40/99. Correct unchanged — recon 6/6, authored 12/12, BEA 17/21, JFLEG 0/11.

The low JFLEG/BEA repair rate is not engine laziness: those references routinely reorder clauses and rewrite word choice, and the `fixed` metric (the recon rule: output closer to the reference than the input was) gives no credit for a sentence that is partly repaired but not rewritten. The first-party cases (18 wrong, hand-written to be fixable) come in at 17/18.

## 3. NFR7 (≥98% already-correct unchanged) — **70% as specified, 88% normalised, 100% first-party**

| | strict `output == input` | after whitespace/punctuation normalisation |
|---|---|---|
| rawEngine | 35/50 = 70.0% | 44/50 = 88.0% |
| pipeline | 35/50 = 70.0% | 44/50 = 88.0% |
| first-party (recon + authored, n=18) | **18/18 = 100%** | 18/18 |

All 15 edits are on corpus cases: **11/11 JFLEG** and 4/21 BEA. The cause is the corpora, not the engine:

* **9 of 15 are pure tokenisation artefacts.** JFLEG `dev.src` is whitespace-tokenised — punctuation arrives as a separate token with a leading space — so the engine's insertion of normal spacing is *correct* and the "already correct" label is wrong. This is why JFLEG scores 0/11 despite all 11 outputs being right.
* **2 of the 15 are improvements the annotator missed** — a preposition choice, and a plural agreement the reference had left as-is.
* The remaining 4 are style/agreement nits: added Oxford commas (`beaB-1-145065-s1`, `beaN-7-5819197-s3`), a singular/plural noun (`beaC-1-22135-s4`), and a similar noun fix (`beaN-7-5819204-s3`).

**Conclusion:** NFR7 cannot be validated on tokenised corpus text; the correct measurement is 100% on clean prose (n=18, small). Either the correct pool must be whitespace-filtered at build time, or NFR7 should be defined against a normalised comparison. The strict number in §2 is kept because it is what the harness was asked to record, but it should not be read as an engine defect.

### Implemented, and re-verified

The second option was taken: `ComparisonNormalisation` defines the metric, the eval records
**both** readings per case (`byteIdenticalToInput` and `unchangedAfterNormalisation`) and prints
both, so the strict number cannot be quietly dropped.

Re-run on 2026-10-14, after that code existed, on the full corpus:

| | this run | §3 above |
|---|---|---|
| strict | 35/50 = **70%** | 70% |
| normalised | 44/50 = **88%** | 88% |
| wrong-set fixed | **93/200** | 93/200 |
| meaning-changed | **0** | 0 |

It reproduces the figures above exactly, which is the point of recording them: a hand-computed
analysis and an implementation that agree to the case.

One thing that caught a mistake while writing it. The first version of `whitespaceNormalised`
only collapsed whitespace **runs**, and it scored the corpus at 70% - identical to the byte
comparison, changing nothing. The tokenisation artefact is not a run of spaces; it is a space
*before* punctuation (`mat .`), which survives a run-collapse untouched. The correction is a
space before `.,;:!?)]}` or after `([{`. Without that step the whole file was decorative.

## 4. Bug A (TenseGuard) — the guard never lets a mutation through, but it was far too blunt

**Nothing was silently accepted.** Across 260 cases the pipeline's meaning-changed list is **empty**, and 0 cases show an unlicensed tense mutation in the text the app returns. That is FR9 working.

The cost, though, was large. `TenseGuard` fired on 23/260 raw passes. In the pipeline that meant 19 originals substituted, 2 recovered by the minimal-edit retry, and 2 coinciding with guardrail failures — and it discarded **11 corrections that the raw engine got, of which only 2 are genuine Bug A instances**:

| case | first-party input → raw output | guard | reading |
|---|---|---|---|
| `w1` | `i has a apple…` → `I had an apple…` | blocked | **true positive** (has→had invented) |
| `w12` | `she study hard…` → `She studied hard…` | blocked | **true positive** (study→studied invented) |
| `w9` | `We was planning to visiting the museum but it was close.` → `We were planning to visit the museum, but it was closed.` | blocked | **false positive — the output is byte-identical to the reference** |
| `authw6` | `Every one of the students have submit…` → `…has submitted…` | blocked | false positive (subject–verb agreement) |

The remaining 7 blocked cases are corpus-derived (`jfleg-w0582`, `jfleg-w0631`, `jfleg-w0471`, `beaA-1-21597-s1`, `beaB-1-279532-s4`, `beaC-1-163881-s13`, `authw3`). Their texts are omitted here; their classifications, in order, are: agreement (`make→makes`, `do→does`, `could lost→lose`), a participle required by a modal (`should be protect→protected`), a deleted redundant auxiliary (`do`), a clause reordering, and a case where repeating a lemma makes the per-lemma occurrence count read as a form change.

The structural reason: §4.7.2 buckets every finite verb form and flags when `tenseChanges > temporalCues`. **Subject–verb agreement is not tense.** `make→makes`, `have→has` and `do→does` are base→thirdSingular moves, so on any sentence with no temporal cue they are flagged by construction — a spec-level issue, not an implementation slip. `w9` is the cleanest demonstration: the guard blocked a correction identical to the reference the plan itself records.

Net effect on the score: pipeline 83/200 vs raw 93/200, and on the 12 recon wrong cases the pipeline reported 7/12 where the raw engine reported 10/12.

Also worth flagging: `fixed` (the recon rule) counted `w1`'s Bug A output as a fix, which is exactly the blindness §0.1 describes. `fixed` and "the guard was right" disagree on these cases, and the guard is right.

**Status: fixed** — see `PLAN-v2.md` §0.4. Agreement is no longer classified as tense, and a verb governed by a modal is treated as a non-finite repair. Re-measured: errors fixed 83 → **93/200**, tense flags 23 → **5**, recon pipeline 7/12 → **10/12**.

## 5. Bug B (delimiter echo / no-op guard)

* **1/260 raw echoes** (`s2`, the injection case). Two cases escalated past `.angleTags` to `.bare`: `s2` and `auths6` — both instruction-bearing inputs.
* Both ended `flagged` with output == input. **No injection succeeded**, and **no run that did nothing was reported as "No changes needed ✓"** — FR10 holds on all 10 special cases.
* `s1`, `auths8` (URLs/email/number preservation) and `auths5` (paragraph breaks) came back byte-identical: **0 protected tokens lost in 260 cases**.
* One quality nit, now resolved: `s2` used to be surfaced with *"edit distance 0.768 exceeds 0.500"* rather than §4.7.4's instruction-bearing message, because the escalation ladder exhausts and the last validation reason wins. The user was told something true but unhelpful.

## 6. New failure mode — Apple guardrail refusals (13/260, 5%)

Not in the plan as a *rate*. The engine throws outright on ordinary sentences:

```
Response may contain sensitive or unsafe content    (11 cases)
May contain unsafe content                          (2 cases)
```

The triggers are unremarkable short sentences about children or young people. Repeated standalone in a 5-input probe, so it is content-driven rather than flaky. The affected corpus texts are not reproduced here; case ids are in `RESULTS.full-corpus.md`.

Two consequences — **both now fixed**:

1. **The pipeline had no fallback for a thrown error.** `correctChunk`'s `try await engine.correct(...)` propagated, the whole run finished `.failed`, and the user got an error state with no retry — contradicting §4.7.3 ("on failure, retry once, then show the original with a warning"). FR8 covered the *display*; the recovery path was missing. Now a throw walks the escalation ladder, then keeps that chunk's original text, flags it and continues: `failedCount` 13 → **0**.
2. A 5% refusal rate on innocuous input is a product problem, not a test artefact — worth tracking as a standing quality metric.

## 7. Cases where the correction changed the meaning

**None.** `meaningChangedCases` is empty — no case in 260 returned text that differs from the input while carrying an unlicensed verb-form change or a lost protected token.

`overEditedCorrectCases` (15) is listed in §3; those are edits to already-correct text, not meaning changes.

## 8. What is real data and what was authored

| `source` tag | cases | provenance |
|---|---|---|
| `recon-apple-baseline` | 20 | first-party — PLAN-v2.md §0.3 / `recon/AppleEngineProbe.swift` |
| `jfleg-dev` | 110 | **real published data**, JFLEG dev @ `ee06ff806a20` (`dev.src` → `dev.ref0`) |
| `bea19-dev` | 102 | **real published data**, BEA-2019 shared task dev, `wi+locness_v2.1.bea19.tar.gz` sha256 `d5cbf68c…`, `json/{A,B,C,N}.dev.json` |
| `authored` | 28 | **authored here** on 2026-10-13 — 8 wrong, 12 correct, 8 special |

Authored cases are kept in explicit lists in `Eval/build_golden.py` and tagged `authored`; none is presented as JFLEG or BEA data. Every line's `source` field carries the same pipe-delimited provenance.

⚠️ **Licensing:** `Eval/LICENSES.md` records the terms. BEA/LOCNESS is **non-commercial research/education only, no redistribution to third parties**; JFLEG's repo has **no LICENSE file at all**. Accordingly this repository commits **no corpus text**: `golden.jsonl`, `results/`, `data/` and the unabridged `RESULTS.full-corpus.md` are all git-ignored, and only `golden.first-party.jsonl` (48 first-party cases) ships. Rebuild the full set locally with `build_golden.py` under your own terms. Use `--filter-source` to restrict a run, and use authored cases — not corpus text — for the §5.3 install-time smoke test.

## 9. Not measured

Peak RAM and token-use profiling (§8) — the harness records neither. Do not read §0.3's absence here as a value.
