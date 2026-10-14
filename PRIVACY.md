# Privacy

GrammarBar corrects English grammar, spelling, punctuation and capitalization. Everything
happens on your Mac.

## The short version

Your text is read by GrammarBar, corrected by Apple's on-device model, and shown back to you.
It is not sent anywhere, stored anywhere, or seen by anyone — including the author of this app.

## What is collected

**Nothing.** There is no account, no analytics, no crash reporting, no usage telemetry and no
update check. The app has no server to send anything to.

## Network access

**None, and it is measured rather than asserted.** Verified on a released build, three ways:

| Check | Result |
|---|---|
| Network sockets held by the app, sampled while idle | **0** |
| Network sockets held while correcting a 15,000-character document | **0** |
| Networking symbols imported by the app binary | **0** |
| CFNetwork / Network.framework linked | **0** |

The app links only its own library and `libSystem`. The reproduction commands are in
`RUNBOOK.md` §12. Corrections work with Wi-Fi switched off.

## What is stored on disk

No history. Nothing you type or correct is written to disk, and the app keeps no log of user
text. Quitting the app discards the text in the panel.

The only thing GrammarBar writes is a small preference — whether "Launch at login" is on —
which macOS itself manages, plus (if you turn the feature on) a login item registered with the
system so the app can start at login.

## What does leave your Mac in normal use

Nothing.

There is one deliberate exception, and it is not in this version: a future release may offer an
optional small offline model that you would download yourself. That download would run in a
**separate helper process** that never receives your text, so the process handling your text
would still have no network access. The helper is not part of this build.

## How your text is treated as data

Text you paste is data, not instructions. The app wraps it in delimiters, instructs the model to
ignore any instructions inside it, and checks the result before showing it to you. If the
correction does not preserve the shape and content of your input, the app shows you a warning
and your original text rather than a possibly-damaged result.

## Accuracy, honestly

GrammarBar is a proofreading tool, not an authority. Known limits, all measured:

- Apple's on-device model declines roughly **5% of perfectly ordinary sentences** through its
  safety guardrails, unpredictably. When that happens the app keeps your original text and says
  so.
- The app corrects about **17 of 20** deliberately-wrong sentences in its own test set.
- Correction never rephrases, summarises, translates or explains. If your text is already
  correct it comes back untouched, and says "No changes needed".

## Third-party components

- **Apple Foundation Models** — the on-device language model, provided by macOS 26. Apple's own
  privacy terms apply to the system model itself; GrammarBar does not add to or intercept that.
- No third-party analytics, advertising or crash-reporting SDKs are included.

## Verifying this yourself

The source is public and the claims above are reproducible:

```sh
APP=/Applications/GrammarBar.app
nm -u "$APP/Contents/MacOS/GrammarBar" | grep -cE 'URLSession|CFNetwork|nw_|socket|connect'
otool -L "$APP/Contents/MacOS/GrammarBar"
```

Disclosure, since a privacy tool should not be coy about its own limits: the app is ad-hoc
signed, so macOS does **not** enforce a kernel-level sandbox on it. The guarantees above are
properties of the code — verified at the socket and symbol level — not of a system restriction.
Enabling the sandbox is part of the signing work a notarized release would require.
