# Eval — GrammarBar correction regression harness

Plan v2 §8. Everything here exists so that "the engine's behaviour changed" is a
number, not an argument — the plan commits to re-running this after **every**
macOS update (§0 is proof that engine behaviour is a moving target).

## Files

| Path | What it is |
|---|---|
| `golden.jsonl` | The golden set. One JSON object per line, keys exactly `id, kind, input, expected, source`. 260 cases. |
| `build_golden.py` | Rebuilds `golden.jsonl` from `data/`. Deterministic (fixed seed, sorted candidates). |
| `data/` | Downloaded source corpora. Not needed to *run* the eval. |
| `results/` | Run output: `<engine>-<label>-<YYYY-MM-DD>.json` (raw per-case records) + `.txt` (human report). |
| `RESULTS.md` | The curated summary of the latest run. |
| `LICENSES.md` | Exact licence terms of every imported corpus. **Read before shipping.** |

## Running it

```sh
cd /Users/kusalkalinga/Developer/personal/GrammarBar
swift run GrammarBarEval --engine apple --set Eval/golden.jsonl --out Eval/results/
```

Options: `--engine apple|local` · `--set <path>` (repeatable) · `--out <dir>` ·
`--label <name>` · `--mode both|pipeline|raw` · `--limit n` ·
`--filter-source <prefix>` (repeatable) · `--quiet`.

Useful subsets:

```sh
# the 20 measured recon cases only — the apples-to-apples drift check
swift run GrammarBarEval --filter-source recon-apple-baseline --label recon

# skip the non-redistributable BEA/LOCNESS cases
swift run GrammarBarEval --set Eval/golden.jsonl --out Eval/results \
  --filter-source recon-apple-baseline --filter-source authored --filter-source jfleg
```

## Two passes, deliberately

Each case is run twice and both results are stored:

* **`pipeline`** — through `CorrectionService.run`, i.e. exactly what the app
  does: chunk → generate → sanitize → validate → TenseGuard → no-op guard, with
  the delimiter-escalation and minimal-edit retry ladders. This is the pass that
  answers "does the app behave correctly".
  Caveat: its `ttftMs` is the time to the first emitted `.partial`, and the
  service only emits a partial *after* the chunk has been generated **and**
  validated — so it is not comparable to token-level TTFT.
* **`rawEngine`** — one-shot `engine.correct(text, mode: .normal, delimiter:
  .angleTags)` with no guard, no retry, no escalation. This is the call shape
  `recon/AppleEngineProbe.swift` used, so this is the pass comparable to the
  numbers recorded in PLAN-v2.md §0.3 (10/12 fixed, 6/6 unchanged, 362 ms mean
  TTFT). If `rawEngine` disagrees with §0.3, the engine drifted.

## Metric definitions (so two runs are comparable)

* `fixed` (kind `wrong` only) — `normalized(output, expected) <
  normalized(input, expected)`. This is the recon rule, kept verbatim so the
  12-case baseline stays comparable. It is a *movement* test, not a correctness
  test: it counted recon's Bug A output (`I had an apple…`) as a fix.
* `correctUnchanged` (kind `correct` only) — `output == input`, byte-identical.
  The ≥98% NFR7 target is computed over exactly this.
* `tenseFlagged` — `TenseGuard.check(input:output:)`, i.e. verb-form changes >
  temporal cues. Computed on the **final** output in the pipeline pass.
* `delimiterEchoCount` — the sanitizer found `<text>`/`«»` in the raw model
  output (recon Bug B evidence). Reported from the `rawEngine` pass, because the
  pipeline's own flag reflects only its *last* attempt (a successful escalation
  clears it).
* `meaningChanged` — `output != input` **and** (`tenseFlagged` **or** a protected
  number/URL/email from the input is missing from the output). An operational
  proxy, not a semantic judgement; it is the set a human should read.
* Latency percentiles are nearest-rank on the per-case arrays.

## Rebuilding `golden.jsonl`

`build_golden.py` reads `data/` and rewrites `golden.jsonl`. Same inputs +
same seed → identical file. To refetch the inputs, see the URLs in
`build_golden.py` and in `source` of each line; the two commands are:

```sh
curl -sSL -o Eval/data/jfleg-dev.src.txt  https://raw.githubusercontent.com/keisks/jfleg/master/dev/dev.src
curl -sSL -o Eval/data/jfleg-dev.ref0.txt https://raw.githubusercontent.com/keisks/jfleg/master/dev/dev.ref0
curl -sSL -o Eval/data/wi+locness_v2.1.bea19.tar.gz \
  https://www.cl.cam.ac.uk/research/nl/bea2019st/data/wi+locness_v2.1.bea19.tar.gz
tar xzf Eval/data/wi+locness_v2.1.bea19.tar.gz -C Eval/data/
```

### Filters applied to imported pairs

Documented because they shape the set: sentences 20–250 chars, ≥5 words, no
embedded newlines, and (for wrong→right pairs) reference edit distance in
`0.02…0.60`. The upper bound excludes full rewrites, which are not the
product's job; the lower bound excludes whitespace-only diffs. `expected` is
always stored, so a different filter can be applied downstream without
re-downloading anything. BEA pairs are only accepted where the annotator's
char-level edits preserve the sentence count, so original and corrected
sentences line up 1:1.
