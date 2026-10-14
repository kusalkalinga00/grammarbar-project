# GrammarBar — user guide

A menu bar app that corrects English grammar, spelling, punctuation and capitalization, on your
Mac, without sending anything anywhere.

## Requirements

- An **Apple Silicon** Mac (M1 or later)
- **macOS 26 or later**
- **Apple Intelligence turned on** — System Settings → Apple Intelligence & Siri

Without Apple Intelligence the app opens and tells you so, but cannot correct anything. There is
no fallback engine in this version.

## Install

### Homebrew

```sh
brew tap kusalkalinga00/grammarbar https://github.com/kusalkalinga00/grammarbar-project
brew trust --cask kusalkalinga00/grammarbar/grammarbar
brew install --cask grammarbar
```

The `brew trust` line is required on Homebrew 7: a third-party tap is untrusted until you say
otherwise, and without it every command refuses.

### First launch

macOS will ask you to confirm the app the first time, because it is not notarized. Approve it
once under **System Settings → Privacy & Security**, then it opens normally from then on. This
is expected, not a sign of a bad download. (Building from source avoids it entirely.)

### From source

```sh
git clone https://github.com/kusalkalinga00/grammarbar-project.git
cd grammarbar-project
xcodegen generate
xcodebuild -project GrammarBar.xcodeproj -scheme GrammarBar \
           -configuration Debug -derivedDataPath .build-xcode build
open .build-xcode/Build/Products/Debug/GrammarBar.app
```

## Using it

Click the ✓ icon in the menu bar. A panel opens.

```
[● On-device]  ············  [412 ms]  [clear ⌘K]  [quit ⌘Q]
──────────────────────────────────────────────────────────
Corrected                                    [Copy]
  ...your corrected text streams in here...

──────────────────────────────────────────────────────────
  ...type or paste your text here...
  ⌘↩ to submit                          [Submit]
──────────────────────────────────────────────────────────
☑ Launch at login
```

1. **Type or paste** your text into the lower box.
2. Press **⌘↩** or click **Submit**. The correction streams into the upper box as it is
   generated.
3. Press **Copy** to put the corrected text on the clipboard.

| Control | What it does |
|---|---|
| **⌘↩** / Submit | Starts the correction. Becomes **Cancel** while running. |
| **Esc** | Cancels a running correction. |
| **⌘K** / trash | Empties both boxes and clears the timing readout. |
| **⌘Q** / power | Quits GrammarBar. |
| **● On-device** | Hover for the privacy statement; orange means the engine is unavailable. |
| **Launch at login** | Starts the app automatically when you log in. |

## What it does, and what it deliberately does not

It fixes grammar, spelling, punctuation and capitalization, and **leaves everything else
alone**. It never rephrases, summarises, translates or explains, and it does not "improve" your
writing style. If your text is already correct you get **No changes needed ✓** and the same
text back.

Line breaks, paragraphs, URLs, email addresses and numbers are preserved.

## Known limitations

These are measured, not guesses.

- **Occasional refusals.** Apple's on-device model declines roughly **5% of perfectly ordinary
  sentences** through its safety guardrails, with no pattern you could predict or avoid. When
  that happens GrammarBar keeps your original text for that part and tells you.
- **Long documents take a while.** Text is corrected in chunks of about 800 characters, which is
  the size the engine handles without dropping content. A 15,000-character document takes about
  50 seconds and several dozen model calls. Short text — the usual case — is a single call.
- **It may warn instead of correcting.** If the model's output does not preserve your text's
  shape or content, the app shows a warning and your original rather than a possibly-damaged
  result. The warning is real: check the text yourself.
- **Not every error is caught.** In the project's own test set the engine corrects about 17 of
  20 deliberately-wrong sentences.

## Troubleshooting

**"GrammarBar needs Apple Intelligence."** Turn it on in System Settings → Apple Intelligence &
Siri. The button in the app opens the right pane.

**A warning appears for text that looks fine.** Some ordinary phrases, such as *"ignore the
previous paragraph"*, are treated as possible instructions to the model. The app warns rather
than silently trusting the result. You can usually ignore it.

**Nothing happens when I press Submit.** Check the badge in the header — if it is orange, the
engine is unavailable. Also check the input box is not empty.

**First run feels slow.** The on-device model loads on first use. Warm corrections start in well
under a second.

## Uninstall

```sh
brew uninstall --cask grammarbar
```

That removes the app and its preferences. If you turned on **Launch at login**, switch it off
before uninstalling, or remove GrammarBar from System Settings → General → Login Items.

## Privacy

See [`PRIVACY.md`](PRIVACY.md). Short version: your text is processed on your Mac, never leaves
it, and the app has no networking code at all — verified, not asserted.
