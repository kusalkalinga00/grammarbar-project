import Foundation

public enum CorrectionOutcome: Sendable, Equatable {
    case corrected
    case unchanged
    /// Text is shown, but with a banner the user should read.
    case flagged(String)
    case failed(String)
}

public struct CorrectionResult: Sendable {
    public let text: String
    public let outcome: CorrectionOutcome
    public let validation: ValidationResult
    public let delimiter: TextDelimiter
    public let attempts: Int
    public let warnings: [String]
}

public enum CorrectionEvent: Sendable {
    case partial(String)
    case finished(CorrectionResult)
}

/// Orchestrates chunk -> generate -> sanitize -> validate, with the two
/// escalation ladders recon showed were necessary:
///
///  * Bug A (over-editing, e.g. invented tense) -> retry once with
///    `Prompts.minimalEdit`, then show the original with a warning.
///  * Bug B (echoed `<text>` wrapper, no correction attempted) -> step the
///    delimiter down the `TextDelimiter` ladder.
///
/// A run is only ever reported as "No changes needed" when we have positive
/// evidence the model actually tried (plan v2 FR10).
public struct CorrectionService: Sendable {

    public let chunker: Chunker
    public let maxAttempts: Int

    public init(contextSize: Int = Chunker.appleMeasuredContext, maxAttempts: Int = 4) {
        self.chunker = Chunker(contextSize: contextSize)
        self.maxAttempts = maxAttempts
    }

    public func run(text: String,
                    engine: any GrammarEngine) -> AsyncThrowingStream<CorrectionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.yield(.finished(Self.emptyResult(text: text)))
                        continuation.finish()
                        return
                    }

                    let chunks = chunker.split(text)
                    let validator = Validator(kind: engine.kind)

                    var assembled = ""
                    var attempts = 0
                    var warnings: [String] = []
                    var lastValidation: ValidationResult?
                    var delimiter: TextDelimiter = .angleTags
                    var substitutedOriginal = false
                    var declinedReasons: [String] = []

                    for chunk in chunks {
                        try Task.checkCancellation()
                        let outcome = try await correctChunk(chunk.text,
                                                             engine: engine,
                                                             validator: validator)
                        attempts += outcome.attempts
                        lastValidation = outcome.validation
                        delimiter = outcome.delimiter
                        warnings.append(contentsOf: outcome.validation.reasons)
                        if outcome.usedOriginal { substitutedOriginal = true }
                        if let reason = outcome.declinedReason { declinedReasons.append(reason) }
                        assembled += outcome.text + chunk.trailing
                        continuation.yield(.partial(assembled))
                    }

                    let trimmedIn = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedOut = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
                    let noChange = trimmedIn == trimmedOut
                    let integrityFailure = Self.documentIntegrityFailure(input: trimmedIn,
                                                                        output: trimmedOut)

                    var finalOutcome: CorrectionOutcome
                    if let declined = declinedReasons.first {
                        finalOutcome = .flagged("The system model declined part of this text "
                            + "(\(declined)). That part is shown unchanged.")
                    } else if substitutedOriginal {
                        finalOutcome = .flagged(warnings.first
                            ?? "The model's output didn't pass validation, so your original text is shown unchanged.")
                    } else if let integrityFailure {
                        // Per-chunk validation cannot see the document, and is measurably too
                        // loose to substitute for it: at a 3,276-character budget the pipeline
                        // dropped 27% of a 58-paragraph document and still reported .corrected
                        // with no warnings, because every individual chunk stayed inside the
                        // length-ratio band. The document is the unit the user cares about.
                        finalOutcome = .flagged("The output no longer has the same shape as "
                            + "your input (\(integrityFailure)), so it isn't shown as a "
                            + "verified correction.")
                    } else if noChange {
                        // Bug B: never claim success when the input looked like
                        // it could have hijacked the run.
                        if Self.looksInstructionBearing(text) {
                            finalOutcome = .flagged("The model returned your text unedited. "
                                + "It may have been affected by instructions inside the text, "
                                + "so this run couldn't be verified.")
                        } else {
                            finalOutcome = .unchanged
                        }
                    } else {
                        finalOutcome = .corrected
                    }

                    // A document-level integrity failure means the assembled text is not
                    // trustworthy at all, so the original is what gets shown - the same
                    // principle as an individual chunk that fails validation.
                    let shownText = integrityFailure == nil ? assembled : text

                    let result = CorrectionResult(
                        text: shownText,
                        outcome: finalOutcome,
                        validation: lastValidation ?? validator.validate(
                            input: text,
                            sanitized: SanitizationResult(text: trimmedOut,
                                                          delimiterEchoed: false,
                                                          strippedPreamble: nil,
                                                          strippedFence: false),
                            kind: engine.kind),
                        delimiter: delimiter,
                        attempts: attempts,
                        warnings: warnings)

                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Per-chunk escalation

    struct ChunkOutcome {
        let text: String
        let validation: ValidationResult
        let delimiter: TextDelimiter
        let attempts: Int
        let usedOriginal: Bool
        /// Set when the engine THREW rather than returning a usable completion.
        let declinedReason: String?
    }

    func correctChunk(_ chunk: String,
                      engine: any GrammarEngine,
                      validator: Validator) async throws -> ChunkOutcome {
        var delimiter: TextDelimiter = .angleTags
        var mode: CorrectionMode = .normal
        var attempt = 0
        var last: ValidationResult?
        var declined: String?

        while attempt < maxAttempts {
            attempt += 1
            var raw = ""
            do {
                for try await snapshot in engine.correct(chunk, mode: mode, delimiter: delimiter) {
                    raw = snapshot
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A thrown error is NOT a validation failure. Measured on the full
                // eval set: Apple's guardrails decline ~5% of innocuous sentences
                // (13/260, on unremarkable short sentences about children or young people).
                // Walk the ladder,
                // then keep the rest of the document alive - one declined chunk
                // must never fail an entire run (plan v2 §4.7.3).
                declined = error.localizedDescription
                if let next = delimiter.escalation {
                    delimiter = next
                    mode = .minimalEdit
                    continue
                }
                break
            }

            let sanitized = OutputSanitizer.sanitize(raw, delimiter: delimiter)
            let validation = validator.validate(input: chunk,
                                                sanitized: sanitized,
                                                kind: engine.kind)
            last = validation

            if validation.accepted {
                return ChunkOutcome(text: sanitized.text, validation: validation,
                                    delimiter: delimiter, attempts: attempt,
                                    usedOriginal: false, declinedReason: nil)
            }

            // Bug B first: an echoed delimiter means we learned nothing about
            // quality, so change the wrapper before changing the prompt.
            if sanitized.delimiterEchoed, let next = delimiter.escalation {
                delimiter = next
                continue
            }

            // Bug A: over-editing -> tighten the prompt once.
            if validation.suggestsMinimalEditRetry, mode == .normal {
                mode = .minimalEdit
                continue
            }

            break
        }

        let fallback = last ?? validator.validate(
            input: chunk,
            sanitized: SanitizationResult(text: chunk, delimiterEchoed: false,
                                          strippedPreamble: nil, strippedFence: false),
            kind: engine.kind)
        return ChunkOutcome(text: chunk, validation: fallback,
                            delimiter: delimiter, attempts: attempt,
                            usedOriginal: true, declinedReason: declined)
    }

    // MARK: - Helpers

    /// Verbs that redirect a reader's or model's behaviour.
    static let redirectVerbs: [String] = [
        "ignore", "disregard", "forget", "set aside",
        "override", "overriding", "overridden",
    ]

    /// Objects that make a redirect be *about instructions*.
    ///
    /// Deliberately excludes content nouns - paragraph, sentence, section, line, text,
    /// comment, passage. "Ignore the previous paragraph" is something a person writes
    /// about their own draft; "ignore the previous instructions" is not. Requiring the
    /// object is what removes the false positive, and it is also what catches paraphrases
    /// the old flat list missed ("set aside the earlier directions").
    static let instructionTargets: [String] = [
        "instruction", "direction", "rule", "guidance", "prompt",
        "everything you were told", "everything above", "everything before",
        "the above", "your task", "your role",
    ]

    /// Command forms. These are instructions by construction, so they need no redirect
    /// verb to justify flagging them.
    ///
    /// Kept deliberately short. Several tempting phrases were left out because they occur
    /// in ordinary English and a false positive shows the user their own uncorrected text
    /// with a warning, which is the worse failure of the two:
    ///
    /// - "act as a"  -> "she will act as a liaison"
    /// - "from now on" -> "from now on the team meets on Mondays"
    /// - "and nothing else" -> "I want coffee and nothing else"
    /// - "you are now a" -> "you are now a registered user" (and, before the tokeniser
    ///   below, it also matched inside "you are now **a**ble to...")
    ///
    /// The cost of each is recorded in `InjectionCoverageTests` rather than hidden.
    static let commandPatterns: [String] = [
        "system prompt", "your new task",
        "output the word", "reply with only", "reply with just", "respond only",
        "just say", "return the single word", "copy it verbatim",
        "do not correct", "print the secret",
    ]

    /// Clause headers that are instructions only when a command follows them.
    ///
    /// "New instructions: translate this." is an injection. "New instructions will be
    /// issued next week by the committee." is a line from a memo. The difference is
    /// structural - an imperative follows the header - so it is decided structurally
    /// instead of by adding the whole sentence to a phrase list.
    static let headerPatterns: [String] = ["as an ai", "new instructions"]

    /// Verbs that make a preceding header an instruction rather than a topic.
    static let imperativeVerbs: Set<String> = [
        "output", "reply", "respond", "say", "translate", "answer", "return",
        "print", "reveal", "copy", "ignore", "disregard", "forget", "emit",
        "write", "give", "produce", "act", "render", "repeat",
    ]

    // MARK: Token matching

    /// Split into lowercased word tokens. Matching on tokens rather than substrings is
    /// what keeps "you are now a" out of "you are now able to": raw `contains` found it,
    /// which is exactly the class of bug this detector was rewritten to remove.
    static func wordTokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Does `text` contain `phrase` as a whole-word token sequence? Allows a trailing
    /// "s"/"es" so "instruction" also matches "instructions".
    static func containsPhrase(_ phrase: String, inTokens have: [String]) -> Bool {
        let want = wordTokens(phrase)
        guard !want.isEmpty, have.count >= want.count else { return false }
        for start in 0...(have.count - want.count) {
            var matched = true
            for (offset, w) in want.enumerated() {
                let token = have[start + offset]
                if token != w && token != w + "s" && token != w + "es" {
                    matched = false
                    break
                }
            }
            if matched { return true }
        }
        return false
    }

    /// Does `phrase` occur with an imperative verb within `within` tokens after it?
    ///
    /// This is the structural half of the detector: it separates "New instructions:
    /// translate this" from "New instructions will be issued next week".
    static func followedByImperative(_ phrase: String, inTokens have: [String],
                                     within: Int = 2) -> Bool {
        let want = wordTokens(phrase)
        guard !want.isEmpty, have.count > want.count else { return false }
        for start in 0...(have.count - want.count) {
            var matched = true
            for (offset, w) in want.enumerated() {
                let token = have[start + offset]
                if token != w && token != w + "s" && token != w + "es" {
                    matched = false
                    break
                }
            }
            guard matched else { continue }
            let from = start + want.count
            for k in from..<min(from + within + 1, have.count) where imperativeVerbs.contains(have[k]) {
                return true
            }
        }
        return false
    }

    /// Does this text try to redirect the correction rather than be corrected?
    ///
    /// Two shapes count. A redirect needs both a verb and an instruction-shaped object:
    /// matching the verb alone produced false positives on ordinary prose, and matching a
    /// flat phrase list missed the paraphrased injections. Command forms stand alone.
    ///
    /// Measured coverage is asserted and printed in `InjectionCoverageTests`.
    public static func looksInstructionBearing(_ text: String) -> Bool {
        let have = wordTokens(text)

        let hasRedirect = redirectVerbs.contains { containsPhrase($0, inTokens: have) }
        if hasRedirect, instructionTargets.contains(where: { containsPhrase($0, inTokens: have) }) {
            return true
        }

        if commandPatterns.contains(where: { containsPhrase($0, inTokens: have) }) {
            return true
        }

        // A header alone is a topic; a header followed by a command is an instruction.
        return headerPatterns.contains { followedByImperative($0, inTokens: have) }
    }

    /// Whole-document integrity, which per-chunk validation structurally cannot provide.
    ///
    /// A correction may change characters freely but must not change the document's SHAPE.
    /// A chunk-level check compares a chunk against itself and is blind to a run of text that
    /// went missing between two chunks. The user is not.
    ///
    /// Tolerance is a ratio band plus an absolute floor, because a ratio alone misfires on
    /// short inputs: "i has a apple" (13 chars) -> "I have an apple." (16) is a 23% change and
    /// completely legitimate.
    static func documentIntegrityFailure(input: String, output: String) -> String? {
        guard !input.isEmpty else { return nil }

        let delta = output.count - input.count
        if abs(delta) > 40 {
            let ratio = Double(output.count) / Double(input.count)
            if ratio < 0.97 || ratio > 1.03 {
                let percent = Int((ratio * 100).rounded())
                return delta < 0
                    ? "it is missing \(abs(delta)) characters (\(percent)% of the original length)"
                    : "it gained \(delta) characters (\(percent)% of the original length)"
            }
        }

        let inParagraphs = input.components(separatedBy: "\n\n").count
        let outParagraphs = output.components(separatedBy: "\n\n").count
        if inParagraphs >= 2, outParagraphs < inParagraphs {
            return "\(inParagraphs) paragraphs became \(outParagraphs)"
        }

        return nil
    }

    static func emptyResult(text: String) -> CorrectionResult {
        CorrectionResult(
            text: text,
            outcome: .unchanged,
            validation: ValidationResult(accepted: true, editDistance: 0, lengthRatio: 1,
                                         tense: TenseGuard.Verdict(tenseChanges: 0,
                                                                   agreementChanges: 0,
                                                                   governedRepairs: 0,
                                                                   temporalCues: 0,
                                                                   changedVerbs: []),
                                         delimiterEchoed: false, reasons: []),
            delimiter: .angleTags,
            attempts: 0,
            warnings: [])
    }
}
