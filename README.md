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

- `swift build` clean · **195 tests passing** (70 core, 125 downloader)
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

**Expect a Gatekeeper prompt on first launch.** The app is ad-hoc signed, not notarized, so
macOS asks you to confirm it once — approve it under **System Settings → Privacy & Security**.
Measured on a real install rather than assumed: the download *is* quarantined and `spctl`
rejects the app, so the prompt is expected behaviour, not a misconfiguration. Notarizing needs a
paid Apple Developer account; see `RUNBOOK.md` §11.

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
- Xcode **26 or later** for `FoundationModels`. The project builds against the macOS 26
  SDK, which is the floor every user has — CI runs the macOS 26 / Xcode 26.6 runner
  deliberately, and it caught a macOS-27-only API spelling that would have made the
  project unbuildable for anyone on the current stable Xcode.
- Apple Intelligence **enabled** — the only engine in v1
- `xcodegen` (`brew install xcodegen`) only to build the `.app` bundle

## Quick start

```sh
git clone https://github.com/kusalkalinga00/grammarbar-project.git && cd grammarbar-project

swift test                                  # 195 tests
swift run GrammarBarEval --label first-party # quality baseline

xcodegen generate                           # -> GrammarBar.xcodeproj
xcodebuild -project GrammarBar.xcodeproj -scheme GrammarBar \
           -configuration Debug -derivedDataPath .build-xcode build
open .build-xcode/Build/Products/Debug/GrammarBar.app
```

**See `RUNBOOK.md`** for the full build/run/test guide, a manual UI checklist
with measured expected outputs, and troubleshooting.
**See `USER-GUIDE.md`** for the end-user guide, and **`PRIVACY.md`** for the privacy
statement with its measured evidence. `MANUAL-TEST-PHRASES.md` is a copy-paste sheet for
testing by hand.

## Design

Two engines behind one protocol, both driving
`FoundationModels.LanguageModelSession` — the macOS 27 SDK's `MLXFoundationModels`
adapts an MLX model to the same `LanguageModel` protocol, so there is one session
code path and two model backends.

| Engine | What it is | Status in v1 |
|---|---|---|
| `AppleGrammarEngine` | Apple's on-device system model. Zero bytes shipped. | **the only engine the app offers** |
| `LocalGrammarEngine` | Offline MLX model under 500 MB. | implemented and tested, **not surfaced** |

`LocalGrammarEngine`, `ModelStore` and `ModelCatalog` are written and covered by tests but
deliberately unreachable: nothing can install model weights yet, so offering them would be
offering a dead end. Options and evidence are in `V2-ENGINE-DECISION.md`.

```text
GrammarBar.app   (v1: ad-hoc signed, sandbox NOT enforced — see Privacy)
  MenuBarExtra ─ PanelView ─ CorrectionViewModel
                                 │
        CorrectionService ─ Chunker · Sanitizer · Validator · TenseGuard
                                 │
                     EngineRegistry ── AppleGrammarEngine   <- what v1 runs
                                    └── LocalGrammarEngine → ModelStore

Built in this repo but NOT linked into GrammarBar.app in v1:
  GrammarDownloaderCore   (the only networking code in the project)
  GrammarDownloader.xpc   (planned helper; not in project.yml yet)
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

v1 has **no networking code at all** — verified by inspection, not asserted: no networking
API appears in `Sources/GrammarBar/` or `Sources/GrammarBarCore/`, and the app target links
only `GrammarBarCore`, while the one library in the project containing `URLSession`
(`GrammarDownloaderCore`) is not linked into it. No account, no analytics, no crash
reporting, no update check. It stores no history and logs nothing.

**About the sandbox, precisely.** `Resources/GrammarBar.entitlements` exists and correctly
omits `com.apple.security.network.client` — but it is **not attached to the build**. There is
no `CODE_SIGN_ENTITLEMENTS` on the target and the app is ad-hoc signed, so the sandbox is not
enforced. The protection in v1 is the absence of networking code, not the sandbox. Wiring that
entitlement up is part of the signing work the Developer ID path needs.

Model downloading is not in this build; there is no XPC helper yet.

## Testing

| Layer | Command | Scale |
|---|---|---|
| Unit | `swift test` | 195 tests (70 core, 125 downloader) |
| Regression pins | `swift test --filter ReconRegressionTests` | the two bugs above |
| Quality baseline | `swift run GrammarBarEval --label first-party` | 48 cases, ~50 s |
| Full corpus eval | `swift run GrammarBarEval` | 260 cases, ~5 min |
| Model benchmark | `Bench/.venv/bin/python Bench/bench.py` | 3 models vs Apple |

The eval is the reason "the engine's behaviour changed" can be a number rather
than an argument. Re-run it after every macOS update; the on-device model is a
moving target, and the raw pass is the drift check.

### NFR7, restated

The original requirement — "already-correct input comes back byte-identical in ≥98% of cases" —
cannot be met *or measured* as written. JFLEG as distributed is whitespace-tokenised: its
punctuation arrives as separate tokens with a leading space, so a corrector closing `do n't` to
`don't` is doing its job while a byte comparison scores it as over-editing.

Measured on the full corpus: **70% under a byte comparison, 88% after whitespace
normalisation.** On clean first-party prose: **18 of 18, 100%.**

So the requirement is now defined against the normalised comparison
(`ComparisonNormalisation`, `Tests/GrammarBarCoreTests/ComparisonNormalisationTests.swift`) and
is only meaningful on text that is already well-formed — which makes the first-party set the one
that measures it. The corpora still measure correction quality; they cannot measure this
property. The eval now prints **both** readings, so the distinction can never be quietly lost.

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
├─ project.yml           XcodeGen source of truth (bundle id, plist keys, version)
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
  needs no Apple Developer account, no notarization and no sandbox, and costs nothing — but it
  is **not friction-free**: measured on a real install, the app *is* quarantined and Gatekeeper
  prompts on first launch, so every user approves it once under System Settings → Privacy &
  Security. Removing that friction needs Developer ID + notarization ($99/yr). The App Store is
  deferred, not rejected.
- **FR6, split.** Launch at login is **done and measured**: `SMAppService.mainApp.register()`
  works on an ad-hoc signed build (status `notFound` → `enabled`, confirmed in `sfltool
  dumpbtm`), so it needs no Developer ID. It lives in a panel footer rather than a Settings
  window, since it is the only remaining preference.
- **FR6 panel shortcut — deliberately not done.** `MenuBarExtra` gives no public way to open its
  panel programmatically, so a global hotkey requires replacing the menu bar item with an
  `NSStatusItem` + `NSPopover` — which changes the entire panel presentation, including sizing,
  focus and the ⌘K/⌘Q shortcuts. That is not a change to make without being able to see the
  result, and the current panel is verified working. It should be done in a session where the
  screen is visible, with the app relaunched between attempts.
- **Offline engine (v2).** Round 2 found an offline model in Apple's quality band, so this
  is a real choice now rather than a dead end. Options, evidence and the three cheap checks
  that should come first are in [`V2-ENGINE-DECISION.md`](V2-ENGINE-DECISION.md).
- **Detector precision.** The §4.7.4 instruction detector catches direct injections (11/11)
  but **zero** paraphrased ones (0/10), and it fires on ordinary prose such as
  *"Ignore the previous paragraph; the corrected version follows."* Measured in
  `Tests/GrammarBarCoreTests/InjectionCoverageTests.swift`; tightening it is an open task.
