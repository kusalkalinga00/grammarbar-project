# GrammarBar

A macOS menu bar app that corrects grammar, spelling and punctuation in text you
type or paste. **Your text is processed on your Mac and never leaves it.**

```text
┌─ Mac menu bar ───────────────────[ ✓ ]──┐
                              │
                 ┌────────────▼───────────┐
                 │  OUTPUT    (read-only) │  [Copy]
                 │  corrected text        │
                 ├────────────────────────┤
                 │  INPUT     type/paste  │
                 │                [Submit]│  ⌘↩
                 └────────────────────────┘
```

## Status

Early, but the core is real and measured. Built in one session against
macOS 27.0.1 / Apple M5.

**Verified:**

- `swift build` clean · **173 tests passing** (48 core, 125 downloader)
- `xcodebuild` Debug **and** Release succeed
- The bundle carries `LSUIElement=true` and launches as Launch Services
  `type="UIElement"` — a menu bar app with no Dock icon
- Correction quality on the first-party eval set: **17/20 wrong sentences fixed**,
  **18/18 already-correct returned byte-identical**, 0 runs failed,
  **0 outputs that changed the meaning**
- Mean time to first token **~340–380 ms** (target was < 2 s)

**Not yet verified** — see `RUNBOOK.md` §8. The list is deliberate: the XPC
service has never run, entitlements have never been enforced, the model download
has never completed end to end, and there is no UI automation.

## Install

### Homebrew (the intended path)

```sh
brew tap kusalkalinga00/grammarbar https://github.com/kusalkalinga00/grammarbar-project
brew trust --cask kusalkalinga00/grammarbar/grammarbar
brew install --cask grammarbar
```

The `brew trust` line is **required on Homebrew 7+**, not optional — a third-party tap is
untrusted by default and every command refuses with *"Refusing to load cask … from untrusted
tap"* until you consent to it.

The cask lives in this repo at [`Casks/grammarbar.rb`](Casks/grammarbar.rb), so there is no
second repository to keep in sync. Homebrew clones it as `homebrew-grammarbar` even though the
repo is named `grammarbar-project` — the explicit URL makes that work.

Homebrew downloads with `curl`, which does **not** set the macOS quarantine flag, so the ad-hoc
signed build should launch without a Gatekeeper prompt.

It is deliberately **not** in `homebrew/cask`: that repo requires a build that passes
Gatekeeper (i.e. notarized) and clears a notability threshold, neither of which this project
has yet. A personal tap has no such requirements and costs nothing.

### From source

No Apple Developer account, no certificates, nothing to sign:

```sh
git clone https://github.com/kusalkalinga00/grammarbar-project.git
cd grammarbar-project
xcodegen generate
xcodebuild -project GrammarBar.xcodeproj -scheme GrammarBar \
           -configuration Debug -derivedDataPath .build-xcode build
open .build-xcode/Build/Products/Debug/GrammarBar.app
```

`./Scripts/release.sh` does the same in Release and packages `dist/GrammarBar-<version>.zip`
with its checksum — that is the artifact the cask points at.

## Requirements

- macOS 26+ on Apple Silicon
- Xcode 27 for `FoundationModels`
- Apple Intelligence **enabled** for the default engine
- `xcodegen` (`brew install xcodegen`) only to build the `.app` bundle

## Quick start

```sh
git clone https://github.com/kusalkalinga00/grammarbar-project.git && cd grammarbar-project

swift test                                  # 173 tests
swift run GrammarBarEval --label first-party # quality baseline

xcodegen generate                           # -> GrammarBar.xcodeproj
xcodebuild -project GrammarBar.xcodeproj -scheme GrammarBar \
           -configuration Debug -derivedDataPath .build-xcode build
open .build-xcode/Build/Products/Debug/GrammarBar.app
```

**See `RUNBOOK.md`** for the full build/run/test guide, a manual UI checklist
with measured expected outputs, and troubleshooting.

## Design

Two engines behind one protocol. Both drive
`FoundationModels.LanguageModelSession`, because the macOS 27 SDK's
`MLXFoundationModels` adapts an MLX model to the same `LanguageModel` protocol —
so there is one session code path and two model backends.

| Engine | What it is |
|---|---|
| `AppleGrammarEngine` | Apple's on-device system model. Zero bytes shipped. **Default.** |
| `LocalGrammarEngine` | Offline MLX model under 500 MB. Stub — lands in week 5. |

```text
GrammarBar.app (sandboxed, NO network entitlement)
  MenuBarExtra ─ PanelView ─ CorrectionViewModel
                                 │
        CorrectionService ─ Chunker · Sanitizer · Validator · TenseGuard
                                 │
                     EngineRegistry ── AppleGrammarEngine
                                    └── LocalGrammarEngine → ModelStore

GrammarDownloader.xpc (sandboxed, network ON, never sees user text)
```

### Two failure modes this project exists to handle

Both were found by measurement, not review, and both are pinned by tests
(`Tests/GrammarBarCoreTests/ReconRegressionTests.swift`):

1. **The engine over-edits by inventing tense.** `i has a apple` → `I had an
   apple`. Normalized edit distance **0.167** — far under any sane threshold, so
   an edit-distance validator accepts a meaning change as a clean fix.
   `TenseGuard` gates on the *class* of change instead, and only flags a tense
   change that the text's temporal cues don't license.
2. **Instruction-bearing text silently no-ops.** Input containing an imperative
   made the model echo its `<text>` wrapper back and perform **no correction** —
   which the old pipeline reported as "No changes needed". The sanitizer now
   detects the echo, escalates the delimiter, and never claims success on an
   unverified run.

Getting either wrong in the *other* direction is also expensive: an early
`TenseGuard` counted subject-verb agreement as tense and discarded 11 real
corrections out of 12. Measured, then fixed — errors fixed on the full corpus
went 83/200 → 93/200, false flags 23 → 5.

## Privacy

The process that handles your text has **no network entitlement** —
`com.apple.security.network.client` is absent from `GrammarBar.entitlements`
rather than set to `false`, so the capability never existed. Model downloading
(not yet built) runs in a separate XPC helper that never receives user text. v1 stores no history and logs nothing.

## Testing

| Layer | Command | Scale |
|---|---|---|
| Unit | `swift test` | 173 tests |
| Regression pins | `swift test --filter ReconRegressionTests` | the two bugs above |
| Quality baseline | `swift run GrammarBarEval --label first-party` | 48 cases, ~50 s |
| Full corpus eval | `swift run GrammarBarEval` | 260 cases, ~5 min |
| Model benchmark | `Bench/.venv/bin/python Bench/bench.py` | 3 models vs Apple |

The eval is the reason "the engine's behaviour changed" can be a number rather
than an argument. Re-run it after every macOS update; the on-device model is a
moving target, and the raw pass is the drift check.

## Licensing — read this before shipping anything

**No third-party corpus data is committed to this repository, by design.**

- **BEA-2019 / LOCNESS** is non-commercial research and education only, with no
  redistribution to third parties.
- **JFLEG** ships no `LICENSE` file at all.

`Eval/golden.jsonl` and `Eval/results/` are therefore **git-ignored**, as is
`Eval/data/`. What ships is `Eval/golden.first-party.jsonl` — the recon + authored
subset, 48 cases, containing no third-party text — plus the harness and
provenance docs. Rebuild the full set locally with `Eval/build_golden.py` after
fetching the corpora under your own terms.

Full terms: `Eval/LICENSES.md`.

## Layout

```text
├─ PLAN-v2.md            design + every measured finding (read §0 first)
├─ RUNBOOK.md            how to build, run and test
├─ project.yml           XcodeGen source of truth (bundle, entitlements, XPC)
├─ Package.swift         SwiftPM, for the edit/test loop
├─ recon/                the original probe that produced the plan's §0
├─ Sources/
│  ├─ GrammarBarCore/    Engines/ Text/ Models/ — all the logic
│  ├─ GrammarBar/        SwiftUI app
│  ├─ GrammarDownloaderCore/  download core (host allowlist, resume, hashing)
│  ├─ Shared/            XPC protocol (needs -D GRAMMAR_XPC_SERVICE)
│  └─ GrammarBarEval/    eval CLI
├─ Tests/                core + downloader suites
├─ Eval/                 golden sets, harness, licence docs
├─ Bench/                offline-model benchmark
└─ Resources/            entitlements, Info.plist
```

## Open decisions

- **Distribution.** v1 targets a **Homebrew tap**, not the Mac App Store. A personal tap
  needs no Apple Developer account, no notarization and no sandbox, and costs nothing. The
  App Store and a notarized Developer ID build are both deferred, not rejected.
- **Offline engine (v2).** Round 2 found an offline model in Apple's quality band, so this
  is a real choice now rather than a dead end. Options, evidence and the three cheap checks
  that should come first are in [`V2-ENGINE-DECISION.md`](V2-ENGINE-DECISION.md).
- **Detector precision.** The §4.7.4 instruction detector catches direct injections (11/11)
  but **zero** paraphrased ones (0/10), and it fires on ordinary prose such as
  *"Ignore the previous paragraph; the corrected version follows."* Measured in
  `Tests/GrammarBarCoreTests/InjectionCoverageTests.swift`; tightening it is an open task.
