import Foundation

public struct TextChunk: Sendable, Equatable {
    /// The text handed to the engine. Never ends in whitespace - see `flush`.
    public let text: String
    /// Whitespace that followed this chunk in the source. Re-emit verbatim so
    /// paragraph breaks survive the round trip (plan v2 §4.6).
    public let trailing: String
}

/// Splits text to fit the engine's context window.
///
/// The context size is a *parameter with a measured default*, never a baked-in
/// constant. Recon measured `SystemLanguageModel.default.contextSize == 8192`
/// on macOS 27.0.1; Apple's own property is `@backDeployed(before: macOS 26.4)`
/// and returns a hardcoded 4096 on 26.0-26.3, which is where the v1 plan's
/// "about 4,096" figure came from.
///
/// The invariant this type owes its callers is the **exact round trip**:
///
///     split(t).map { $0.text + $0.trailing }.joined() == t
///
/// Nothing may be dropped, duplicated or reordered, because the service rebuilds the
/// user's document by concatenating the corrected chunk texts with their trailing
/// whitespace. Chunk boundaries are an implementation detail the user must never see.
public struct Chunker: Sendable {

    /// Measured on the baseline machine. Read the live value when you have a model.
    public static let appleMeasuredContext = 8192

    public let contextSize: Int
    public let inputFraction: Double
    public let approximateCharactersPerToken: Int

    /// The largest chunk that **fits** the context window, from the measured context size.
    public var contextDerivedChunkCharacters: Int {
        max(200, Int(Double(contextSize) * inputFraction) * approximateCharactersPerToken)
    }

    /// What the on-device model can correct *faithfully*, measured — 2026-10-14.
    ///
    /// The budget was originally 40% of the context window, which reasons about how much
    /// text FITS. That turned out not to be the binding constraint. Swept over a
    /// 15,188-character, 58-paragraph document, keeping track of how many paragraph
    /// separators and filler paragraphs survived:
    ///
    /// | budget | chunks | separators kept | errors left | warnings | outcome             |
    /// |--------|--------|-----------------|-------------|----------|---------------------|
    /// | 13,104 |      2 |       56 / 58   |   0 / 7     |        2 | dropped content     |
    /// |  6,552 |      3 |       50 / 58   |   2 / 7     |        1 | dropped content     |
    /// |  3,276 |      5 |       44 / 58   |   0 / 7     |        0 | dropped, NOT flagged|
    /// |  1,636 |     10 |       58 / 58   |   1 / 7     |        1 | intact but flagged  |
    /// |    816 |     19 |       58 / 58   |   0 / 7     |        0 | clean               |
    ///
    /// Only the smallest budget is clean end to end. Note how 3,276 is the most dangerous
    /// row and not the middle one: it loses 14 of 58 paragraphs and reports success with no
    /// warning at all. Larger chunks are cheaper — fewer engine calls — and the price is
    /// content the user is never told went missing.
    ///
    /// So the effective budget is the smaller of the two constraints: what fits, and what
    /// survives correction.
    public static let fidelityCharactersPerChunk = 816

    /// The smaller of the context limit and the measured fidelity limit.
    public var maxCharactersPerChunk: Int {
        min(contextDerivedChunkCharacters, Self.fidelityCharactersPerChunk)
    }

    /// How full a run must be before a paragraph boundary is worth taking.
    ///
    /// Two failure modes sit either side of this. Closing on *every* paragraph boundary made
    /// a chunk per paragraph (the measured 59). Never closing on one means a chunk spans
    /// paragraphs, so a chunk the engine declines or the validator rejects takes unrelated,
    /// perfectly good text down with it and the user sees that text uncorrected.
    ///
    /// Half the budget is the compromise: still far fewer chunks than paragraphs, and breaks
    /// land on sentence or paragraph edges rather than mid-thought.
    static let paragraphBreakFill = 0.5

    public init(contextSize: Int = Chunker.appleMeasuredContext,
                inputFraction: Double = 0.4,
                approximateCharactersPerToken: Int = 4) {
        self.contextSize = contextSize
        self.inputFraction = inputFraction
        self.approximateCharactersPerToken = approximateCharactersPerToken
    }

    public func split(_ text: String) -> [TextChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [TextChunk] = []
        var buffer = ""

        // A document that already fits is the common case, and it still goes through
        // `flush` so the "chunk text ends on a visible character" rule holds everywhere.
        if text.count <= maxCharactersPerChunk {
            buffer = text
            Self.flush(&buffer, into: &chunks)
            return chunks
        }

        for segment in Self.segments(of: text) {
            var piece = segment.text

            // A single sentence longer than the budget: hard-wrap it.
            while piece.count > maxCharactersPerChunk {
                let cut = piece.index(piece.startIndex, offsetBy: maxCharactersPerChunk)
                Self.flush(&buffer, into: &chunks)
                // Via flush as well, so the rule "chunk text ends on a visible character"
                // holds here too - a hard cut can land in the middle of a space run.
                var head = String(piece[piece.startIndex..<cut])
                Self.flush(&head, into: &chunks)
                piece = String(piece[cut...])
            }

            // Accumulate until the next piece would overflow. The whitespace is carried
            // INTO the buffer rather than flushing on sight: an earlier version closed the
            // chunk on every paragraph's trailing whitespace, so a document of N paragraphs
            // became N engine calls. Measured on a 15,188-character document that fits in
            // two chunks of the 13,104 budget, it produced **59** - one per paragraph -
            // and took 55 seconds.
            if !buffer.isEmpty, buffer.count + piece.count > maxCharactersPerChunk {
                Self.flush(&buffer, into: &chunks)
            }

            buffer += piece + segment.trailing

            // Take a paragraph break only once the run is substantial. `flush` peels the
            // whitespace off into `trailing`, so it stays attached to the chunk that ends
            // the paragraph - which is what keeps the round trip exact.
            if !segment.trailing.isEmpty,
               Double(buffer.count - segment.trailing.count)
                   >= Double(maxCharactersPerChunk) * Self.paragraphBreakFill {
                Self.flush(&buffer, into: &chunks)
            }
        }

        Self.flush(&buffer, into: &chunks)
        return chunks
    }

    public func chunks(_ text: String) -> [String] { split(text).map(\.text) }

    /// Close the accumulated run.
    ///
    /// Trailing whitespace is peeled off into `trailing` so the engine is never asked to
    /// "correct" a run of newlines, and so the whitespace is restored byte-for-byte on
    /// reassembly no matter what the engine returns. Interior whitespace stays in the
    /// text, because a chunk that spans a paragraph boundary has to show the engine that
    /// boundary for the model to preserve it.
    private static func flush(_ buffer: inout String, into chunks: inout [TextChunk]) {
        guard !buffer.isEmpty else { return }
        var text = buffer
        var trailing = ""
        while let last = text.last, last.isWhitespace {
            trailing.insert(last, at: trailing.startIndex)
            text.removeLast()
        }
        chunks.append(TextChunk(text: text, trailing: trailing))
        buffer = ""
    }

    // MARK: - Segmentation

    struct Segment { let text: String; let trailing: String }

    static func segments(of text: String) -> [Segment] {
        var out: [Segment] = []
        let paragraphs = text.components(separatedBy: "\n\n")

        for (pi, paragraph) in paragraphs.enumerated() {
            let paragraphTrailing = pi < paragraphs.count - 1 ? "\n\n" : ""

            var sentences: [String] = []
            paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex,
                                          options: [.bySentences]) { sub, _, _, _ in
                if let sub { sentences.append(sub) }
            }
            if sentences.isEmpty { sentences = [paragraph] }

            for (si, sentence) in sentences.enumerated() {
                let isLast = si == sentences.count - 1
                out.append(Segment(text: sentence, trailing: isLast ? paragraphTrailing : ""))
            }
        }
        return out
    }
}
