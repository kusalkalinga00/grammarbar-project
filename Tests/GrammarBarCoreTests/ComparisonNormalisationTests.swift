import XCTest
@testable import GrammarBarCore

/// Pins the NFR7 metric. The requirement is "correct text comes back unchanged"; the question
/// this file settles is *unchanged by what comparison*.
final class ComparisonNormalisationTests: XCTestCase {

    func testTrailingNewlineIsNotAChange() {
        XCTAssertTrue(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "The cat sat on the mat.\n", "The cat sat on the mat."))
    }

    func testCollapsedSpacesAreNotAChange() {
        XCTAssertTrue(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "one  two", "one two"))
    }

    func testParagraphBreaksAreNotAChange() {
        // A newline and a space are both just whitespace for this metric.
        XCTAssertTrue(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "First.\n\nSecond.", "First. Second."))
    }

    /// The property that keeps the metric honest: punctuation and case ARE meaning, so they
    /// must not be normalised away, or genuine over-editing would slip through.
    func testPunctuationAndCaseAreStillChanges() {
        XCTAssertFalse(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "The cat sat on the mat.", "The cat sat on the mat"))
        XCTAssertFalse(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "Its important", "It's important"))
        XCTAssertFalse(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "the cat sat", "The cat sat"))
    }

    func testRealEditsAreStillChanges() {
        XCTAssertFalse(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "i has a apple", "I have an apple."))
    }

    /// Whitespace-only normalisation must not merge two different sentences into one.
    func testDifferentWordsAreStillChanges() {
        XCTAssertFalse(ComparisonNormalisation.unchangedIgnoringWhitespace(
            "The cat sat on the mat.", "The cat sat on the hat."))
    }
}
