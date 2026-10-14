import XCTest
@testable import GrammarBarCore

final class SanitizerTests: XCTestCase {

    func testStripsPreamble() {
        let raw = "Here is the corrected text:\nThe cat sat on the mat."
        let result = OutputSanitizer.sanitize(raw, delimiter: .angleTags)
        XCTAssertEqual(result.text, "The cat sat on the mat.")
        XCTAssertNotNil(result.strippedPreamble)
    }

    func testStripsMarkdownFence() {
        let raw = "```\nThe cat sat.\n```"
        let result = OutputSanitizer.sanitize(raw, delimiter: .angleTags)
        XCTAssertEqual(result.text, "The cat sat.")
        XCTAssertTrue(result.strippedFence)
    }

    func testStripsWrappingQuotes() {
        let raw = "\u{201C}The cat sat.\u{201D}"
        let result = OutputSanitizer.sanitize(raw, delimiter: .angleTags)
        XCTAssertEqual(result.text, "The cat sat.")
    }

    func testNoEchoForCleanOutput() {
        let result = OutputSanitizer.sanitize("The cat sat.", delimiter: .angleTags)
        XCTAssertFalse(result.delimiterEchoed)
        XCTAssertFalse(result.didStripAnything)
    }

    func testBareDelimiterNeverReportsEcho() {
        let result = OutputSanitizer.sanitize("anything <text> here", delimiter: .bare)
        XCTAssertFalse(result.delimiterEchoed)
    }
}

final class ValidatorTests: XCTestCase {

    private func validate(_ input: String, _ output: String, kind: EngineKind = .apple) -> ValidationResult {
        Validator(kind: kind).validate(
            input: input,
            sanitized: SanitizationResult(text: output, delimiterEchoed: false,
                                          strippedPreamble: nil, strippedFence: false),
            kind: kind)
    }

    func testAcceptsAGoodCorrection() {
        let r = validate("Their are alot of problems with this aproach.",
                         "There are a lot of problems with this approach.")
        XCTAssertTrue(r.accepted, "\(r.reasons)")
    }

    func testRejectsLostURL() {
        let r = validate("Visit https://example.com/docs for details.",
                         "Visit the documentation for details.")
        XCTAssertFalse(r.accepted)
        XCTAssertTrue(r.reasons.contains { $0.contains("protected") }, "\(r.reasons)")
    }

    func testRejectsLostEmail() {
        let r = validate("Email alice@example.com about the 2024 report.",
                         "Email the team about the report.")
        XCTAssertFalse(r.accepted)
    }

    func testPreservedNumbersAndURLsPass() {
        let text = "Contact me at alice@example.com or visit https://example.com/docs/v2 for the 2024 release notes."
        let r = validate(text, text)
        XCTAssertTrue(r.accepted, "\(r.reasons)")
    }

    func testRejectsRunawayExpansion() {
        let r = validate("The cat sat.", "The cat sat. " + String(repeating: "Furthermore, ", count: 40))
        XCTAssertFalse(r.accepted)
        XCTAssertTrue(r.reasons.contains { $0.contains("length ratio") }, "\(r.reasons)")
    }

    func testLocalEngineIsStricterOnEditDistance() {
        // Synthetic pair sitting squarely between the two thresholds:
        // equal length, 40% of characters changed.
        let input = String(repeating: "a", count: 100)
        let output = String(repeating: "a", count: 60) + String(repeating: "b", count: 40)
        let d = EditDistance.normalized(input, output)
        XCTAssertEqual(d, 0.4, accuracy: 0.001)
        XCTAssertTrue(validate(input, output, kind: .apple).accepted, "0.4 is inside Apple's 0.5 budget")
        XCTAssertFalse(validate(input, output, kind: .local).accepted, "0.4 is outside the local 0.35 budget")
    }

    func testLocalEngineRequiresSentenceCountMatch() {
        let r = validate("The cat sat. The dog ran.", "The cat sat and the dog ran.", kind: .local)
        XCTAssertFalse(r.accepted)
    }
}

final class ChunkerTests: XCTestCase {

    func testShortTextIsOneChunk() {
        let chunks = Chunker().split("The cat sat on the mat.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "The cat sat on the mat.")
    }

    func testMeasuredContextIs8192Not4096() {
        // Recon: SystemLanguageModel.default.contextSize == 8192 on macOS 27.0.1.
        // v1's plan hardcoded 4096; this pins the measured value.
        XCTAssertEqual(Chunker.appleMeasuredContext, 8192)
        let chunker = Chunker()
        // The fit figure still comes from the measured context...
        XCTAssertEqual(chunker.contextDerivedChunkCharacters, Int(8192 * 0.4) * 4)
        // ...but the budget actually used is capped by measured fidelity, which is lower.
        XCTAssertEqual(chunker.maxCharactersPerChunk, Chunker.fidelityCharactersPerChunk)
        XCTAssertLessThan(chunker.maxCharactersPerChunk, chunker.contextDerivedChunkCharacters)
        // And the fidelity cap is not a magic number: it must sit under the budget that was
        // measured to drop content (3,276) and at or above the one measured intact (1,636).
        XCTAssertLessThanOrEqual(Chunker.fidelityCharactersPerChunk, 3_276)
        XCTAssertGreaterThanOrEqual(Chunker.fidelityCharactersPerChunk, 816)
        // The measured-clean budget, not a rounded-off guess at it.
        XCTAssertEqual(Chunker.fidelityCharactersPerChunk, 816)
    }

    /// The invariant the service depends on: nothing dropped, duplicated or reordered.
    /// No test asserted this before, which is how the accumulation bug below survived -
    /// the old paragraph test only checked that a "\n\n" survived *somewhere*.
    func testExactRoundTripAcrossManyParagraphs() {
        let text = Self.manyParagraphs(200)   // 22,488 chars: over the 13,104 budget
        let chunks = Chunker().split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map { $0.text + $0.trailing }.joined(), text,
                       "chunking must be lossless")
    }

    /// REGRESSION PIN. The chunker used to close a chunk on every paragraph's trailing
    /// whitespace, so it never accumulated. A 15,188-character document that fits in TWO
    /// chunks of the 13,104 budget produced **59** - one per paragraph - and made 59 engine
    /// calls, measured at 55 seconds.
    ///
    /// The old budget test could not catch it: its input was 12,800 characters, *below* the
    /// budget, so `split` returned a single chunk and the accumulation loop never ran.
    func testManyParagraphsAccumulateIntoFewChunks() {
        let chunker = Chunker()
        let chunks = chunker.split(Self.manyParagraphs(200))
        XCTAssertGreaterThan(chunks.count, 1, "200 paragraphs must not fit in one chunk")
        // The bug this pins produced one chunk PER PARAGRAPH (200). Correct accumulation
        // gives 50 here, because the paragraph-break-fill rule takes a boundary at half a
        // budget and these paragraphs are small. 100 sits clear of both.
        XCTAssertLessThan(chunks.count, 100,
                          "chunks are not accumulating - this is one engine call per paragraph")
    }

    func testParagraphBreaksSurviveReassembly() {
        // Must exceed maxCharactersPerChunk (~13,104 at contextSize 8192).
        let paragraph = String(repeating: "This is a sentence about grammar. ", count: 1_200)
        let text = paragraph + "\n\n" + paragraph
        let chunker = Chunker()
        let chunks = chunker.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map { $0.text + $0.trailing }.joined(), text)
        XCTAssertTrue(chunks.map { $0.text + $0.trailing }.joined().contains("\n\n"),
                      "paragraph separator must be preserved")
    }

    func testEveryChunkRespectsBudget() {
        // NOTE: this input must exceed maxCharactersPerChunk or the test only ever inspects
        // a single chunk and proves nothing. It used to be 12,800 characters - under the
        // 13,104 budget - which is exactly the hole the regression above fell through.
        let text = String(repeating: "Alpha beta gamma delta epsilon. ", count: 900)  // 32,400
        let chunker = Chunker()
        let chunks = chunker.split(text)
        XCTAssertGreaterThan(chunks.count, 1, "input must be over budget for this to mean anything")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, chunker.maxCharactersPerChunk)
        }
    }

    /// Chunk text is what the engine is asked to correct, so it should end on a visible
    /// character; whitespace rides in `trailing` and is restored verbatim.
    func testChunkTextNeverEndsInWhitespace() {
        for chunk in Chunker().split(Self.manyParagraphs(40)) {
            XCTAssertFalse(chunk.text.last?.isWhitespace ?? false,
                           "chunk text ends in whitespace: \(chunk.text.suffix(24).debugDescription)")
        }
    }

    func testHardSplitsAnOverlongSentence() {
        let text = String(repeating: "x", count: 40_000)
        let chunker = Chunker()
        let chunks = chunker.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, chunker.maxCharactersPerChunk)
        }
        XCTAssertEqual(chunks.map { $0.text + $0.trailing }.joined(), text)
    }

    func testEmptyInput() {
        XCTAssertTrue(Chunker().split("").isEmpty)
    }

    // MARK: - Fixtures

    /// A document of `n` short paragraphs - together far over the budget, individually well
    /// under it. This is the shape that exposed the bug; one enormous paragraph does not.
    private static func manyParagraphs(_ n: Int) -> String {
        let sentence = "The archive holds records that span a little over four decades. "
        return (0..<n).map { "\(sentence)Paragraph number \($0) exists only for this test." }
                      .joined(separator: "\n\n")
    }
}

final class CatalogTests: XCTestCase {

    func testPrimaryPickFitsTheSizeGate() {
        let model = ModelCatalog.qwen3_0_6b_4bit
        XCTAssertTrue(model.fitsSizeGate(), "measured \(model.totalBytes) bytes")
        XCTAssertEqual(model.license, "Apache-2.0")
        XCTAssertNotEqual(model.revision, "main", "revision must be a pinned hash")
    }

    func testNoCatalogEntryViolatesOurOwnGate() {
        for model in ModelCatalog.all {
            XCTAssertTrue(model.fitsSizeGate(), "\(model.id) is \(model.totalBytes) bytes")
        }
    }

    func testOversizeEntriesAreRecordedAsRejected() {
        // Qwen3-0.6B-8bit measured 649.4 MB - over the 500 MB promise.
        let eightBit = ModelCatalog.rejectedOversize.first { $0.0.contains("8bit") }
        XCTAssertNotNil(eightBit)
        XCTAssertGreaterThan(eightBit!.1, ModelStore.sizeGateBytes)
    }

    func testCatalogHasNoBlankHashesPretendingToBePins() {
        // An empty hash is honest (computed at pin time); a fake one is not.
        for model in ModelCatalog.all {
            for file in model.files where !file.sha256.isEmpty {
                XCTAssertEqual(file.sha256.count, 64, "\(file.name) is not a sha256 hex digest")
            }
        }
    }
}

final class ModelStoreTests: XCTestCase {

    private func makeTempStore() throws -> (ModelStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gbstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ModelStore(root: root), root)
    }

    func testMissingRequiredFilesIsRejected() throws {
        let (store, root) = try makeTempStore()
        let temp = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: temp.appendingPathComponent("config.json"))
        // tokenizer.json and a .safetensors are absent
        XCTAssertThrowsError(try store.install(fromTemporaryDirectory: temp,
                                              catalog: ModelCatalog.qwen3_0_6b_4bit)) { error in
            guard case ModelStoreError.missingFiles(let missing) = error else {
                return XCTFail("expected missingFiles, got \(error)")
            }
            XCTAssertTrue(missing.contains("tokenizer.json"))
            XCTAssertTrue(missing.contains { $0.contains("safetensors") })
        }
    }

    func testEmptyStoreHasNoInstalledModel() throws {
        let (store, _) = try makeTempStore()
        XCTAssertNil(store.installedManifest())
    }

    func testHashMismatchIsRejected() throws {
        let (store, root) = try makeTempStore()
        let temp = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: temp.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: temp.appendingPathComponent("tokenizer.json"))
        try Data("weights".utf8).write(to: temp.appendingPathComponent("model.safetensors"))

        let catalog = CatalogModel(
            id: "test", displayName: "Test", license: "Apache-2.0", revision: "abc123",
            files: [CatalogFile(name: "model.safetensors",
                                url: URL(string: "https://example.com/model.safetensors")!,
                                size: 7,
                                sha256: String(repeating: "0", count: 64))])

        XCTAssertThrowsError(try store.install(fromTemporaryDirectory: temp, catalog: catalog)) { error in
            guard case ModelStoreError.hashMismatch = error else {
                return XCTFail("expected hashMismatch, got \(error)")
            }
        }
    }

    func testGoodInstallWritesManifest() throws {
        let (store, root) = try makeTempStore()
        let temp = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: temp.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: temp.appendingPathComponent("tokenizer.json"))
        try Data("weights".utf8).write(to: temp.appendingPathComponent("model.safetensors"))

        let catalog = CatalogModel(
            id: "test", displayName: "Test Model", license: "Apache-2.0", revision: "abc123",
            files: [CatalogFile(name: "model.safetensors",
                                url: URL(string: "https://example.com/model.safetensors")!,
                                size: 7, sha256: "")])

        let manifest = try store.install(fromTemporaryDirectory: temp, catalog: catalog)
        XCTAssertEqual(manifest.id, "test")
        XCTAssertEqual(manifest.revision, "abc123")

        let reloaded = store.installedManifest()
        XCTAssertEqual(reloaded?.id, "test")
        XCTAssertEqual(reloaded?.files.first?.name, "model.safetensors")

        try store.remove(id: "test", revision: "abc123")
        XCTAssertNil(store.installedManifest())
    }
}
