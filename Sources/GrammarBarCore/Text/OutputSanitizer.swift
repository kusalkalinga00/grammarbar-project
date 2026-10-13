import Foundation

public struct SanitizationResult: Sendable, Equatable {
    public let text: String
    /// True when the raw output still carried the input delimiter. That is
    /// evidence the model echoed the wrapper rather than editing (recon Bug B),
    /// NOT evidence that the text was already correct.
    public let delimiterEchoed: Bool
    public let strippedPreamble: String?
    public let strippedFence: Bool

    public var didStripAnything: Bool {
        strippedPreamble != nil || strippedFence || delimiterEchoed
    }
}

public enum OutputSanitizer {

    static let preamblePatterns: [String] = [
        "here is the corrected text:",
        "here is the corrected version:",
        "here's the corrected text:",
        "corrected text:",
        "corrected version:",
        "sure, here is",
        "sure! here is",
        "certainly, here is",
    ]

    public static func sanitize(_ raw: String, delimiter: TextDelimiter) -> SanitizationResult {
        let echoed = delimiter.appearsInOutput(raw)

        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Markdown fences.
        var strippedFence = false
        if text.hasPrefix("```") {
            strippedFence = true
            text = text.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Wrapper tags. Strip them wherever they appear; a model that emitted
        //    them has already told us it did not do the job.
        if let (open, close) = delimiterTags(delimiter) {
            text = text.replacingOccurrences(of: open, with: "")
            text = text.replacingOccurrences(of: close, with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Preamble lines.
        var strippedPreamble: String? = nil
        let lines = text.components(separatedBy: .newlines)
        if let first = lines.first {
            let probe = first.lowercased().trimmingCharacters(in: .whitespaces)
            for p in preamblePatterns where probe.hasPrefix(p) || probe == p {
                strippedPreamble = first
                text = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 4. Balanced wrapping quotes.
        let quotePairs: [(String, String)] = [
            ("\"", "\""), ("'", "'"),
            ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
            ("\u{00AB}", "\u{00BB}"),
        ]
        for (open, close) in quotePairs {
            if text.count >= 2, text.hasPrefix(open), text.hasSuffix(close) {
                text = String(text.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return SanitizationResult(text: text,
                                  delimiterEchoed: echoed,
                                  strippedPreamble: strippedPreamble,
                                  strippedFence: strippedFence)
    }

    static func delimiterTags(_ d: TextDelimiter) -> (String, String)? {
        switch d {
        case .angleTags:  return ("<text>", "</text>")
        case .guillemets: return ("\u{00AB}", "\u{00BB}")
        case .bare:       return nil
        }
    }
}
