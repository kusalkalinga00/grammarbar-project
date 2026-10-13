# Third-party data in `golden.jsonl` — provenance and licence

Every line of `golden.jsonl` carries its own provenance in the `source` field,
as `<dataset-tag> | <origin + revision> | <licence + required citation>`.
This file is the same information in prose, plus the one thing a per-line tag
cannot say: **what may be shipped.**

| tag | cases | real published data? |
|---|---|---|
| `recon-apple-baseline` | 20 | No — first-party measurement, `PLAN-v2.md` §0.3 / `recon/AppleEngineProbe.swift` |
| `jfleg-dev` | 110 | **Yes** — JFLEG dev, sentences reused verbatim |
| `bea19-dev` | 102 | **Yes** — BEA-2019 shared task dev (W&I + LOCNESS), sentences reused verbatim |
| `authored` | 28 | No — written for this repo |

## JFLEG (`jfleg-dev`, 99 wrong + 11 correct)

* Origin: `github.com/keisks/jfleg` @ `ee06ff806a208aba815ac45313f4e750a48330a5`,
  `dev/dev.src` → `dev/dev.ref0`.
* Licence: **the repository contains no LICENSE file.** Public and widely used
  for GEC research, but no licence is granted in it, so the default (all rights
  reserved) technically applies. Do not treat it as open source.
* Required citation: Napoles, Sakaguchi, Tetreault. *JFLEG: A Fluency Corpus
  and Benchmark for Grammatical Error Correction.* EACL 2017.
* Shipping: not cleared for redistribution. It is used here the way research
  corpora are normally used — locally, to measure.

## BEA-2019 (`bea19-dev`, 81 wrong + 21 correct)

* Origin: `wi+locness_v2.1.bea19.tar.gz` from
  `cl.cam.ac.uk/research/nl/bea2019st/data/`,
  sha256 `d5cbf68cda3da0c3af69dd672614d07287bfe996b87da0c75051d5349d76c666`,
  `json/{A,B,C,N}.dev.json`.
* Licences: `licence.wi.txt` (Cambridge English Write & Improve) and
  `license.locness.txt` (LOCNESS / CECL, UCLouvain). Both are in
  `data/wi+locness/` after extraction. The terms:
  * **Non-commercial research and educational use only.** `licence.wi.txt` §3–4
    explicitly excludes "any use … for or as part of a product or service which
    is sold, offered for sale, licensed, leased or rented."
  * `licence.wi.txt` §6 permits publishing excerpts of **less than 100 words**
    from the dataset.
  * `license.locness.txt` §3: "No part of the corpus is to be distributed to a
    third party without specific authorization from CECL."
* Required citation: Bryant, Felice, Andersen, Briscoe. *The BEA-2019 Shared
  Task on Grammatical Error Correction.* BEA-2019.

### ⚠️ Action required before this repo is published or the app is sold

GrammarBar is planned for the Mac App Store, which is a commercial product
(`PLAN-v2.md` §9). The W&I terms exclude exactly that, and LOCNESS forbids
redistribution to third parties outright. The 102 `bea19-dev` sentences are
verbatim corpus excerpts living in a product repository, and the 110
`jfleg-dev` sentences have no licence behind them at all.

Concretely, before the repo goes public or a build is submitted:

1. Keep `golden.jsonl` internal, **or** split it: commit the redistributable
   subset (recon + authored + whatever is cleared) and regenerate the rest
   locally from `data/` with `build_golden.py`. `--filter-source` already makes
   this a one-flag change:
   `swift run GrammarBarEval --filter-source recon-apple-baseline --filter-source authored --filter-source jfleg …`
2. If the corpus-derived cases are needed in a shipped smoke test
   (`PLAN-v2.md` §5.3 install-time check), replace them with authored cases
   before shipping, or obtain written authorisation from Cambridge and CECL.
3. If a paper or a public write-up quotes results, the citations above are
   mandatory and the ≤100-word excerpt limit applies.
4. `Eval/data/` is fetch-only and git-ignored by `Eval/.gitignore`, but the
   files may already be **staged** in the index (a plain `.gitignore` does not
   unstage anything). Before committing, run
   `git rm -r --cached Eval/data`.

This is a licensing finding from the fetched licence files, not legal advice.

## `authored` (28 cases)

Written for this repo on 2026-10-13. No third-party terms; reuse freely. These
are *not* JFLEG or BEA data and must never be counted as such — the 8 authored
`wrong` cases, 12 `correct` sentences and 8 `special` probes are originals, kept
in `build_golden.py` as explicit lists so their provenance stays obvious.
