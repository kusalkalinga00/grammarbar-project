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

                    var finalOutcome: CorrectionOutcome
                    if let declined = declinedReasons.first {
                        finalOutcome = .flagged("The system model declined part of this text "
                            + "(\(declined)). That part is shown unchanged.")
                    } else if substitutedOriginal {
                        finalOutcome = .flagged(warnings.first
                            ?? "The model's output didn't pass validation, so your original text is shown unchanged.")
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

                    let result = CorrectionResult(
                        text: assembled,
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

    static let instructionPatterns: [String] = [
        "ignore all previous", "ignore the previous", "ignore previous",
        "disregard all", "disregard the", "forget all", "forget the previous",
        "system prompt", "you are now", "as an ai", "new instructions",
        "output the word", "just say", "reply with only",
    ]

    public static func looksInstructionBearing(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return instructionPatterns.contains { lowered.contains($0) }
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
