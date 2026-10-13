import Foundation

public struct TextChunk: Sendable, Equatable {
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
public struct Chunker: Sendable {

    /// Measured on the baseline machine. Read the live value when you have a model.
    public static let appleMeasuredContext = 8192

    public let contextSize: Int
    public let inputFraction: Double
    public let approximateCharactersPerToken: Int

    public var maxCharactersPerChunk: Int {
        max(200, Int(Double(contextSize) * inputFraction) * approximateCharactersPerToken)
    }

    public init(contextSize: Int = Chunker.appleMeasuredContext,
                inputFraction: Double = 0.4,
                approximateCharactersPerToken: Int = 4) {
        self.contextSize = contextSize
        self.inputFraction = inputFraction
        self.approximateCharactersPerToken = approximateCharactersPerToken
    }

    public func split(_ text: String) -> [TextChunk] {
        guard !text.isEmpty else { return [] }
        if text.count <= maxCharactersPerChunk {
            return [TextChunk(text: text, trailing: "")]
        }

        var chunks: [TextChunk] = []
        var buffer = ""

        for segment in Self.segments(of: text) {
            var piece = segment.text

            // A single sentence longer than the budget: hard-wrap it.
            while piece.count > maxCharactersPerChunk {
                let cut = piece.index(piece.startIndex, offsetBy: maxCharactersPerChunk)
                if !buffer.isEmpty {
                    chunks.append(TextChunk(text: buffer, trailing: ""))
                    buffer = ""
                }
                chunks.append(TextChunk(text: String(piece[piece.startIndex..<cut]), trailing: ""))
                piece = String(piece[cut...])
            }

            if !buffer.isEmpty, buffer.count + piece.count > maxCharactersPerChunk {
                chunks.append(TextChunk(text: buffer, trailing: ""))
                buffer = ""
            }

            buffer += piece

            if !segment.trailing.isEmpty {
                chunks.append(TextChunk(text: buffer, trailing: segment.trailing))
                buffer = ""
            }
        }

        if !buffer.isEmpty { chunks.append(TextChunk(text: buffer, trailing: "")) }
        return chunks
    }

    public func chunks(_ text: String) -> [String] { split(text).map(\.text) }

    public func reassemble(_ parts: [String]) -> String {
        zip(parts, split(parts.joined())).map { $0 + $1.trailing }.joined()
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
