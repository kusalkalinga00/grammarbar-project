import Foundation
import NaturalLanguage

/// Guards the failure mode edit distance structurally cannot see.
///
/// Recon ("Bug A"): Apple's engine turned
///   "i has a apple and she go to school yesterday" -> "I had an apple and she went to school yesterday."
///   "she study hard and allways get good grade"    -> "She studied hard and always got good grades."
/// at normalized edit distance 0.167 / 0.182 - both far under the 0.5 threshold,
/// so an edit-distance-only validator accepts a meaning change as a clean fix.
///
/// REVISED after the first full eval run (260 cases). The original version
/// classified every form change as a tense change, which swept in subject-verb
/// agreement. It therefore discarded 11 real corrections of which only 2 were
/// genuine over-edits - and one of the discarded outputs was byte-identical to
/// the plan's own recorded reference answer. Agreement changes NUMBER, not
/// tense, and a participle after a modal is governed by that modal.
///
/// Only a crossing of the tense divide, with no temporal cue to license it,
/// is flagged.
public struct TenseGuard: Sendable {

    public enum Bucket: String, Sendable, Equatable {
        case base, thirdSingular, past, gerund, participle

        /// Which side of the *tense* divide this surface form sits on.
        /// Agreement lives entirely inside `.present`, on purpose.
        public var axis: Axis {
            switch self {
            case .base, .thirdSingular: return .present
            case .past:                 return .past
            case .gerund, .participle:  return .nonFinite
            }
        }
    }

    public enum Axis: String, Sendable, Equatable {
        case present, past, nonFinite
    }

    public struct Verb: Sendable, Equatable {
        public let surface: String
        public let form: Bucket
        /// True when a modal, auxiliary or "to" governs this verb, so its form is
        /// fixed by that word rather than carrying the clause's tense:
        /// "should be protect" -> "should be protected" is a participle repair.
        public let governed: Bool
    }

    public struct Verdict: Sendable, Equatable {
        public let tenseChanges: Int
        /// present<->present form changes. Reported, never flagged.
        public let agreementChanges: Int
        /// Non-finite repairs under a governing word. Reported, never flagged.
        public let governedRepairs: Int
        public let temporalCues: Int
        public let changedVerbs: [String]

        public var isFlagged: Bool { tenseChanges > temporalCues }

        public var summary: String {
            guard tenseChanges > 0 else {
                let quiet = agreementChanges + governedRepairs
                return quiet == 0
                    ? "no verb-form changes"
                    : "no tense change (\(agreementChanges) agreement, \(governedRepairs) governed)"
            }
            return "\(tenseChanges) tense change(s) "
                 + "[\(changedVerbs.joined(separator: ", "))] "
                 + "vs \(temporalCues) temporal cue(s)"
        }
    }

    static let temporalCueWords: Set<String> = [
        "yesterday", "today", "tonight", "tomorrow", "last", "next", "ago",
        "soon", "later", "recently", "previously", "formerly", "currently",
        "now", "already", "yet", "since", "earlier",
    ]

    /// A word that makes the verb after it non-finite.
    static let governors: Set<String> = [
        "to", "be", "been", "being", "is", "are", "was", "were", "am",
        "can", "could", "will", "would", "shall", "should", "may", "might",
        "must", "do", "does", "did", "not", "n't",
    ]

    public static func check(input: String, output: String) -> Verdict {
        let before = verbs(in: input)
        let after = verbs(in: output)
        var tense = 0, agreement = 0, governed = 0
        var names: [String] = []

        for lemma in Set(before.keys).union(after.keys).sorted() {
            let x = before[lemma] ?? []
            let y = after[lemma] ?? []
            // A verb appearing or vanishing entirely is an insertion/deletion,
            // not a tense change; the validator's length ratio handles that.
            guard !x.isEmpty, !y.isEmpty else { continue }

            // Reordering is not a change: compare as multisets first.
            let xs = x.map(\.form.rawValue).sorted()
            let ys = y.map(\.form.rawValue).sorted()
            if xs == ys { continue }

            for i in 0..<max(x.count, y.count) {
                guard let xv = i < x.count ? x[i] : nil,
                      let yv = i < y.count ? y[i] : nil,
                      xv.form != yv.form else { continue }

                if xv.form.axis == yv.form.axis {
                    agreement += 1                 // make <-> makes
                } else if xv.governed || yv.governed {
                    governed += 1                  // should be protect <-> protected
                } else {
                    tense += 1
                    names.append(lemma)
                }
            }
        }

        return Verdict(tenseChanges: tense,
                       agreementChanges: agreement,
                       governedRepairs: governed,
                       temporalCues: cueCount(in: input),
                       changedVerbs: names)
    }

    public static func cueCount(in text: String) -> Int {
        var n = 0
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let w = text[range].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if temporalCueWords.contains(w) { n += 1 }
            return true
        }
        return n
    }

    // MARK: - Verb extraction

    static func verbs(in text: String) -> [String: [Verb]] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text

        // Collect every tagged word so a verb can see the word before it.
        var words: [(range: Range<String.Index>, tag: NLTag?, lemma: String?)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            words.append((range, tag, lemma))
            return true
        }

        var out: [String: [Verb]] = [:]
        for (i, word) in words.enumerated() where word.tag == .verb {
            let surface = String(text[word.range])
            let lemma = (word.lemma ?? surface).lowercased()
            var governed = false
            if i > 0 {
                let previous = String(text[words[i - 1].range]).lowercased()
                governed = governors.contains(previous)
            }
            out[lemma, default: []].append(
                Verb(surface: surface,
                     form: bucket(surface: surface, lemma: lemma),
                     governed: governed))
        }
        return out
    }

    /// Surface-form classification. Deliberately coarse: we care that the form
    /// *crossed the tense divide*, not which tense it landed in.
    static func bucket(surface: String, lemma: String) -> Bucket {
        let s = surface.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let l = lemma.lowercased()

        switch s {
        case "is", "am", "are", "\u{2019}s", "'s": return .thirdSingular
        case "was", "were":                      return .past
        case "be":                               return .base
        case "been":                             return .participle
        case "being":                            return .gerund
        default: break
        }

        if s == l { return .base }
        if s.hasSuffix("ing") { return .gerund }
        if s.hasSuffix("ied") { return .past }
        if s.hasSuffix("ed")  { return .past }
        if s.hasSuffix("es") || s.hasSuffix("s") { return .thirdSingular }
        // Irregular past/participle with no usable suffix (had, went, got, gone).
        return .past
    }
}
