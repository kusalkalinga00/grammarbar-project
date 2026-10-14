import XCTest
@testable import GrammarBarCore

/// Regressions for the two bugs the first full eval run (260 cases) found in the
/// guard layer and the run orchestrator - both in code this project wrote, not
/// in the model.
final class TenseGuardPrecisionTests: XCTestCase {

    /// The first version counted base -> thirdSingular as a tense change and so
    /// discarded 9 legitimate agreement corrections.
    func testAgreementChangeIsNotATenseChange() {
        let v = TenseGuard.check(input: "He make a mistake here.",
                                 output: "He makes a mistake here.")
        XCTAssertFalse(v.isFlagged, v.summary)
        XCTAssertEqual(v.tenseChanges, 0)
        XCTAssertGreaterThanOrEqual(v.agreementChanges, 1)
    }

    func testHaveToHasIsAgreementNotTense() {
        let v = TenseGuard.check(input: "They has a new car.",
                                 output: "They have a new car.")
        XCTAssertFalse(v.isFlagged, v.summary)
        XCTAssertEqual(v.tenseChanges, 0)
    }

    func testDoToDoesIsAgreementNotTense() {
        let v = TenseGuard.check(input: "She do the work every day.",
                                 output: "She does the work every day.")
        XCTAssertFalse(v.isFlagged, v.summary)
        XCTAssertEqual(v.tenseChanges, 0)
    }

    /// "should be protect" -> "should be protected" is governed by the modal.
    func testParticipleRepairUnderModalIsNotATenseChange() {
        let v = TenseGuard.check(input: "The plan should be protect by law.",
                                 output: "The plan should be protected by law.")
        XCTAssertFalse(v.isFlagged, v.summary)
        XCTAssertEqual(v.tenseChanges, 0)
        XCTAssertGreaterThanOrEqual(v.governedRepairs, 1)
    }

    /// Defensive: the precision fix must not disarm Bug A.
    func testGenuineTenseChangeWithNoCueIsStillFlagged() {
        let v = TenseGuard.check(input: "i has a apple", output: "I had an apple.")
        XCTAssertTrue(v.isFlagged, v.summary)
    }

    func testRealReconCasesStillFlagged() {
        let cases = [("i has a apple and she go to school yesterday",
                      "I had an apple and she went to school yesterday."),
                     ("she study hard and allways get good grade",
                      "She studied hard and always got good grades.")]
        for (input, output) in cases {
            XCTAssertTrue(TenseGuard.check(input: input, output: output).isFlagged, input)
        }
    }

    func testCueCounting() {
        XCTAssertEqual(TenseGuard.cueCount(in: "I went to Paris last summer."), 1)
        XCTAssertEqual(TenseGuard.cueCount(in: "She studies hard."), 0)
    }
}

/// Test double: throws for any chunk containing `poison`, corrects otherwise.
private struct ThrowingEngine: GrammarEngine {
    let kind: EngineKind = .apple
    let status: EngineStatus = .ready
    let poison: String
    let replacement: (String, String)

    func prewarm() async {}
    func unload() async {}

    func correct(_ text: String, mode: CorrectionMode, delimiter: TextDelimiter)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if text.contains(poison) {
                // Mirrors the real error surface Apple returns for a guardrail trip.
                continuation.finish(throwing: EngineError.notReady(
                    "Response may contain sensitive or unsafe content"))
            } else {
                continuation.yield(text.replacingOccurrences(of: replacement.0,
                                                             with: replacement.1))
                continuation.finish()
            }
        }
    }
}

final class CorrectionServiceFailureTests: XCTestCase {

    /// Measured: guardrails decline 13/260 innocuous sentences. Before this fix a
    /// single throw finished the entire run as `.failed`.
    func testThrownErrorDoesNotFailTheWholeRun() async throws {
        let engine = ThrowingEngine(poison: "guardrails", replacement: ("teh", "the"))
        let text = "This part is perfectly fine.\n\nThe guardrails decline this part."

        var final: CorrectionResult?
        for try await event in CorrectionService().run(text: text, engine: engine) {
            if case .finished(let result) = event { final = result }
        }

        let result = try XCTUnwrap(final, "the run must complete, not throw")
        guard case .flagged(let message) = result.outcome else {
            return XCTFail("expected .flagged, got \(result.outcome)")
        }
        XCTAssertTrue(message.lowercased().contains("declined"), message)
        XCTAssertTrue(result.text.contains("perfectly fine"), "undamaged text must survive")
        XCTAssertGreaterThanOrEqual(result.attempts, 1)
    }

    /// A declined chunk must not take the other chunks down with it.
    func testOneDeclinedChunkDoesNotFailTheOthers() async throws {
        let engine = ThrowingEngine(poison: "guardrails", replacement: ("teh", "the"))
        // Small context forces multiple chunks.
        let service = CorrectionService(contextSize: 50)
        let good = String(repeating: "I saw teh cat. ", count: 20)
        let text = good + "\n\nThe guardrails decline this part."

        var final: CorrectionResult?
        for try await event in service.run(text: text, engine: engine) {
            if case .finished(let result) = event { final = result }
        }

        let result = try XCTUnwrap(final)
        XCTAssertFalse(result.text.contains("teh "), "undamaged chunks must still be corrected")
        XCTAssertTrue(result.text.contains("the cat"), "the good chunks were corrected")
        XCTAssertTrue(result.text.contains("guardrails"), "the declined chunk is shown unchanged")
    }

    func testCleanRunIsUnaffectedByTheNewCatch() async throws {
        let engine = ThrowingEngine(poison: "\u{FFFF}never", replacement: ("teh", "the"))
        var final: CorrectionResult?
        for try await event in CorrectionService().run(text: "I saw teh cat.", engine: engine) {
            if case .finished(let result) = event { final = result }
        }
        let result = try XCTUnwrap(final)
        XCTAssertEqual(result.text, "I saw the cat.")
        if case .corrected = result.outcome {} else {
            XCTFail("expected .corrected, got \(result.outcome)")
        }
    }

    func testEmptyInputShortCircuits() async throws {
        let engine = ThrowingEngine(poison: "\u{FFFF}never", replacement: ("a", "b"))
        var final: CorrectionResult?
        for try await event in CorrectionService().run(text: "   ", engine: engine) {
            if case .finished(let result) = event { final = result }
        }
        XCTAssertEqual(try XCTUnwrap(final).attempts, 0)
    }

    // MARK: - Document-level integrity

    /// Per-chunk validation cannot see the document. Measured: at a 3,276-character chunk
    /// budget the pipeline dropped 27% of a 58-paragraph document and reported `.corrected`
    /// with no warnings, because each chunk on its own stayed inside the ratio band.
    func testDocumentIntegrityRejectsTheMeasuredSilentLoss() {
        let input = String(repeating: "The archive holds records that span four decades. \n\n",
                           count: 300)
        let output = String(input.dropLast(input.count / 4))
        XCTAssertNotNil(CorrectionService.documentIntegrityFailure(input: input, output: output),
                        "a 25% document loss must not be treated as a clean correction")
    }

    /// A dropped paragraph barely moves the length of a long document, so the ratio band
    /// alone would miss it. The paragraph count is the second net.
    func testDocumentIntegrityCatchesOneLostParagraphInALongDocument() {
        let line = "A sentence that is long enough to matter. \n\n"
        let input = String(repeating: line, count: 300)
        var output = input
        if let r = output.range(of: line) { output.removeSubrange(r) }
        XCTAssertNotNil(CorrectionService.documentIntegrityFailure(input: input, output: output),
                        "a dropped paragraph must be visible even when length barely moves")
    }

    /// 13 -> 16 characters is a 23% change and entirely legitimate; the absolute floor is
    /// what keeps the ratio band from misfiring on short inputs.
    func testDocumentIntegrityAllowsALegitimateShortEdit() {
        XCTAssertNil(CorrectionService.documentIntegrityFailure(
            input: "i has a apple", output: "I have an apple."))
    }

    func testDocumentIntegrityAllowsAnUnchangedDocument() {
        let text = "The cat sat on the mat.\n\nThe cat sat on the mat again."
        XCTAssertNil(CorrectionService.documentIntegrityFailure(input: text, output: text))
    }

    /// Real corrections must never be mistaken for shape changes, or the guard would reject
    /// the app's own good output.
    func testDocumentIntegrityAllowsRealCorrections() {
        let pairs = [
            ("i has a apple and she go to school yesterday",
             "I have an apple and she went to school yesterday."),
            ("The company have three new product that will be launch next month.",
             "The company has three new products that will be launched next month."),
            ("Every one of the students have submit there assignment late.",
             "Every one of the students has submitted their assignment late."),
        ]
        for (input, output) in pairs {
            XCTAssertNil(CorrectionService.documentIntegrityFailure(input: input, output: output),
                         "legitimate correction rejected as a shape change: \(output)")
        }
    }
}
