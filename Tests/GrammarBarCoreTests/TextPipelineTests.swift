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
        XCTAssertEqual(chunker.maxCharactersPerChunk, Int(8192 * 0.4) * 4)
        XCTAssertGreaterThan(chunker.maxCharactersPerChunk, Int(4096 * 0.4) * 4)
    }

    func testParagraphBreaksSurviveReassembly() {
        // Must exceed maxCharactersPerChunk (~13,104 at contextSize 8192).
        let paragraph = String(repeating: "This is a sentence about grammar. ", count: 1_200)
        let text = paragraph + "\n\n" + paragraph
        let chunker = Chunker()
        let chunks = chunker.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.map { $0.text }.joined().contains("grammar") )
        XCTAssertTrue(chunks.contains { $0.trailing == "\n\n" }, "paragraph separator must be preserved")
    }

    func testEveryChunkRespectsBudget() {
        let text = String(repeating: "Alpha beta gamma delta epsilon. ", count: 400)
        let chunker = Chunker()
        for chunk in chunker.split(text) {
            XCTAssertLessThanOrEqual(chunk.text.count, chunker.maxCharactersPerChunk)
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
    }

    func testEmptyInput() {
        XCTAssertTrue(Chunker().split("").isEmpty)
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
