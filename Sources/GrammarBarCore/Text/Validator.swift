import Foundation

public struct ValidationResult: Sendable, Equatable {
    public let accepted: Bool
    public let editDistance: Double
    public let lengthRatio: Double
    public let tense: TenseGuard.Verdict
    public let delimiterEchoed: Bool
    public let reasons: [String]

    /// True when the only problem was over-editing, i.e. worth one retry with
    /// the "make the smallest possible change" prompt.
    public var suggestsMinimalEditRetry: Bool {
        tense.isFlagged || editDistance > 0.5
    }
}

public struct Validator: Sendable {

    public struct Options: Sendable {
        /// Recon: local models over-edit more, so they get a tighter budget.
        public var maxEditDistance: Double
        public var minLengthRatio: Double
        public var maxLengthRatio: Double
        public var requireSentenceCountMatch: Bool

        public init(kind: EngineKind) {
            switch kind {
            case .apple:
                self.maxEditDistance = 0.5
                self.minLengthRatio = 0.6
                self.maxLengthRatio = 1.6
                self.requireSentenceCountMatch = false
            case .local:
                self.maxEditDistance = 0.35
                self.minLengthRatio = 0.6
                self.maxLengthRatio = 1.6
                self.requireSentenceCountMatch = true
            }
        }
    }

    public let options: Options

    public init(kind: EngineKind) {
        self.options = Options(kind: kind)
    }

    public func validate(input: String,
                         sanitized: SanitizationResult,
                         kind: EngineKind) -> ValidationResult {
        let output = sanitized.text
        var reasons: [String] = []

        let d = EditDistance.normalized(input, output)
        let ratio = input.isEmpty ? 1 : Double(output.count) / Double(input.count)
        let tense = TenseGuard.check(input: input, output: output)

        if d > options.maxEditDistance {
            reasons.append("edit distance \(fmt(d)) exceeds \(fmt(options.maxEditDistance))")
        }
        if ratio < options.minLengthRatio || ratio > options.maxLengthRatio {
            reasons.append("length ratio \(fmt(ratio)) outside "
                         + "\(fmt(options.minLengthRatio))...\(fmt(options.maxLengthRatio))")
        }

        // Protected tokens must survive untouched.
        let missing = protectedTokensMissing(input: input, output: output)
        if !missing.isEmpty {
            reasons.append("lost protected token(s): \(missing.joined(separator: ", "))")
        }

        if options.requireSentenceCountMatch, sentenceCount(input) != sentenceCount(output) {
            reasons.append("sentence count changed "
                         + "(\(sentenceCount(input)) -> \(sentenceCount(output)))")
        }

        // Recon Bug A.
        if tense.isFlagged {
            reasons.append("unlicensed verb tense change: \(tense.summary)")
        }

        // Recon Bug B: an echoed delimiter means no correction was attempted.
        if sanitized.delimiterEchoed {
            reasons.append("model echoed the input delimiter instead of correcting")
        }

        return ValidationResult(accepted: reasons.isEmpty,
                                editDistance: d,
                                lengthRatio: ratio,
                                tense: tense,
                                delimiterEchoed: sanitized.delimiterEchoed,
                                reasons: reasons)
    }

    // MARK: - Helpers

    func protectedTokensMissing(input: String, output: String) -> [String] {
        var found: [String] = []
        for t in Self.protectedTokens(in: input) where !output.contains(t) {
            found.append(t)
        }
        return found
    }

    static let numberRegex   = try! NSRegularExpression(pattern: "\\b\\d[\\d.,:/-]*\\b")
    static let urlRegex      = try! NSRegularExpression(pattern: "https?://\\S+")
    static let emailRegex    = try! NSRegularExpression(pattern: "[\\w.+-]+@[\\w-]+\\.[\\w.]+")

    static func protectedTokens(in text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        for re in [urlRegex, emailRegex, numberRegex] {
            for m in re.matches(in: text, range: range) {
                out.append(ns.substring(with: m.range))
            }
        }
        return out
    }

    func sentenceCount(_ text: String) -> Int {
        var n = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return max(n, text.isEmpty ? 0 : 1)
    }

    func fmt(_ d: Double) -> String { String(format: "%.3f", d) }
}
