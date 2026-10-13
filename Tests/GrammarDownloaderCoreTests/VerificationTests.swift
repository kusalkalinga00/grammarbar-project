import XCTest
@testable import GrammarDownloaderCore

/// SHA-256 handling, including the case the catalog is actually in today:
/// **no pins at all**. An empty pin must record the digest and refuse to claim
/// verification — neither a silent pass nor a failure.
final class VerificationTests: XCTestCase {

    // The canonical vector for "abc" (FIPS 180-2 / RFC 6234 test vector).
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: The empty-pin rule

    func testEmptyPinIsRecordedNotVerified() {
        let result = Verifier.classify(expectedPinnedDigest: "", computed: abcDigest)
        XCTAssertEqual(result, .recordedUnpinned(digest: abcDigest))
        XCTAssertFalse(result.isVerified, "an unpinned file must never be reported as verified")
        XCTAssertFalse(result.isPinnedButWrong, "an unpinned file is not a mismatch either")
    }

    func testWhitespaceOnlyPinIsTreatedAsUnpinned() {
        XCTAssertEqual(Verifier.classify(expectedPinnedDigest: "   ", computed: abcDigest),
                       .recordedUnpinned(digest: abcDigest))
    }

    func testRecordedDigestIsNormalisedToLowerCase() {
        XCTAssertEqual(Verifier.classify(expectedPinnedDigest: "", computed: abcDigest.uppercased()),
                       .recordedUnpinned(digest: abcDigest))
    }

    // MARK: Pinned digests

    func testMatchingPinIsVerified() {
        let result = Verifier.classify(expectedPinnedDigest: abcDigest, computed: abcDigest)
        XCTAssertEqual(result, .verified(digest: abcDigest))
        XCTAssertTrue(result.isVerified)
    }

    func testPinComparisonIgnoresCase() {
        XCTAssertEqual(Verifier.classify(expectedPinnedDigest: abcDigest.uppercased(), computed: abcDigest),
                       .verified(digest: abcDigest))
    }

    func testMismatchedPinIsReportedWithBothDigests() {
        let other = String(repeating: "a", count: 64)
        let result = Verifier.classify(expectedPinnedDigest: other, computed: abcDigest)
        XCTAssertEqual(result, .mismatch(expected: other, actual: abcDigest))
        XCTAssertTrue(result.isPinnedButWrong)
        XCTAssertFalse(result.isVerified)
    }

    // MARK: Digest format

    func testDigestFormatValidation() {
        XCTAssertTrue(FileDigestFormat.isValid(abcDigest))
        XCTAssertTrue(FileDigestFormat.isValid(abcDigest.uppercased()))
        XCTAssertFalse(FileDigestFormat.isValid(""))
        XCTAssertFalse(FileDigestFormat.isValid(String(repeating: "a", count: 63)))
        XCTAssertFalse(FileDigestFormat.isValid(String(repeating: "a", count: 65)))
        XCTAssertFalse(FileDigestFormat.isValid(String(repeating: "z", count: 64)))
        XCTAssertTrue(FileDigestFormat.isValid("  " + abcDigest + "\n"), "whitespace is trimmed")
    }

    // MARK: Hashing

    func testKnownVectorForInMemoryHashing() {
        XCTAssertEqual(FileHashing.sha256(of: Payload.text("abc")), abcDigest)
    }

    func testKnownVectorForEmptyInput() {
        XCTAssertEqual(FileHashing.sha256(of: Data()), emptyDigest)
    }

    func testFileHashingMatchesInMemoryHashing() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("config.json")
        let data = Payload.text("{\"model_type\": \"qwen3\"}")
        try data.write(to: url)
        XCTAssertEqual(try FileHashing.sha256(ofFileAt: url), FileHashing.sha256(of: data))
    }

    func testFileHashingMatchesInMemoryHashingAcrossChunkBoundaries() throws {
        // One and a bit chunks, so the streaming loop is exercised.
        let directory = TempDirectory()
        defer { directory.remove() }
        let url = directory.url.appendingPathComponent("model.safetensors")
        let data = Payload.bytes(FileHashing.chunkSize + 3)
        try data.write(to: url)
        XCTAssertEqual(try FileHashing.sha256(ofFileAt: url), FileHashing.sha256(of: data))
    }

    func testHashingAMissingFileThrows() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString)")
        XCTAssertThrowsError(try FileHashing.sha256(ofFileAt: missing))
    }
}
