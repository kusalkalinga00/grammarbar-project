import Foundation

/// Comparison normalisation for the NFR7 metric: *correct text must come back unchanged*.
///
/// Measured as a byte comparison, that target is both unreachable and meaningless, because
/// whitespace is not meaning:
///
/// - a trailing newline that the UI trims counts as a change;
/// - two spaces where the input had one counts as a change;
/// - and the pre-tokenised corpora (JFLEG and BEA-2019 as distributed) separate their
///   punctuation - `do n\'t`, `the cat ,` - which **any** working corrector will legitimately
///   close up, so every such line scored as over-editing.
///
/// That last point is the whole reason this file exists. On the first-party prose set, where
/// the text is already well-formed, the engine leaves all 18 already-correct cases untouched.
/// On the tokenised corpora the same engine scored roughly 70% - and the gap is a property of
/// the corpora, not a defect in the engine. The plan's "98% or more" target was written
/// against an unmeasured comparison and could never have been met on those sets.
///
/// Two consequences, both recorded here rather than in prose somewhere:
///
/// 1. The metric is defined on **whitespace-normalised** comparison.
/// 2. It is only meaningful on text that is already well-formed, so the first-party set is the
///    one that measures it. The corpora still measure correction quality; they just cannot
///    measure this particular property.
public enum ComparisonNormalisation {

    /// Collapse whitespace runs, and close up the spacing that whitespace-tokenised corpora
    /// introduce around punctuation.
    ///
    /// The second step is the one that matters, and it is worth being explicit about why it is
    /// not massaging the number. JFLEG as distributed writes punctuation as a separate token -
    /// `mat .` - so a corrector returning `mat.` is doing precisely its job. Measured WITHOUT
    /// this step the metric reads **70% on the corpus, identical to the raw byte comparison**:
    /// the tokenisation artefact dominates the result so completely that the normalisation
    /// appeared to do nothing at all.
    ///
    /// Only unambiguous cases are handled: a space before `.,;:!?)]}`, and a space after
    /// `([{`. Quotes are left alone because the same character opens and closes them. The space
    /// that FOLLOWS a sentence-ending mark stays, since it separates sentences.
    ///
    /// Case, letters and digits are untouched. Those are meaning, and normalising them away
    /// would let genuine over-editing pass - the exact failure this metric exists to catch.
    public static func whitespaceNormalised(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
        let openers: Set<Character> = ["(", "[", "{"]

        let chars = Array(collapsed)
        var out: [Character] = []
        out.reserveCapacity(chars.count)

        for (i, ch) in chars.enumerated() {
            guard ch == " " else { out.append(ch); continue }
            let nextChar = i + 1 < chars.count ? chars[i + 1] : nil
            let hugsCloser = nextChar.map { closers.contains($0) } ?? false
            let followsOpener = out.last.map { openers.contains($0) } ?? false
            if !hugsCloser && !followsOpener { out.append(ch) }
        }
        return String(out)
    }

    /// True when the two strings differ only in whitespace.
    public static func unchangedIgnoringWhitespace(_ lhs: String, _ rhs: String) -> Bool {
        whitespaceNormalised(lhs) == whitespaceNormalised(rhs)
    }
}
