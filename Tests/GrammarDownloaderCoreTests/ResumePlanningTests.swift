import XCTest
@testable import GrammarDownloaderCore

/// Resume bookkeeping: what to do with whatever partial file is found on disk,
/// and what the server's response means for it. All pure, no network.
final class ResumePlanningTests: XCTestCase {

    private let item = DownloadItem(name: "model.safetensors",
                                    url: URL(string: "https://huggingface.co/m/model.safetensors")!,
                                    size: 1_000,
                                    sha256: "")

    // MARK: plan(partialByteCount:expectedTotal:)

    func testNoPartialStartsFresh() {
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 0, expectedTotal: 1_000), .startFresh)
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: -10, expectedTotal: 1_000), .startFresh)
    }

    func testPartialResumesFromItsExactSize() {
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 400, expectedTotal: 1_000),
                       .append(fromByte: 400))
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 400, expectedTotal: 1_000).resumableByteCount, 400)
    }

    func testOneBytePartialResumes() {
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 1, expectedTotal: 1_000), .append(fromByte: 1))
    }

    func testCompletePartialIsVerifiedNotRefetched() {
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 1_000, expectedTotal: 1_000),
                       .verifyExisting(byteCount: 1_000))
    }

    func testOversizedPartialIsDiscarded() {
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 1_001, expectedTotal: 1_000),
                       .discardCorrupt(byteCount: 1_001))
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 1_001, expectedTotal: 1_000).resumableByteCount, 0)
    }

    func testUnknownExpectedTotalDiscardsRatherThanAppends() {
        XCTAssertEqual(ResumePlanner.plan(partialByteCount: 400, expectedTotal: 0),
                       .discardCorrupt(byteCount: 400))
    }

    // MARK: Range header

    func testRangeHeaderIsBuiltFromTheResumeOffset() {
        // The engine passes this straight into `TransportRequest.resumeFromByte`;
        // the transport turns it into `bytes=<offset>-`.
        let plan = ResumePlanner.plan(partialByteCount: 12_345, expectedTotal: 100_000)
        XCTAssertEqual("bytes=\(plan.resumableByteCount)-", "bytes=12345-")
    }

    // MARK: reconcile(statusCode:requestedFromByte:)

    func testPartialContentConfirmsAppend() {
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 206, requestedFromByte: 400), .appendConfirmed)
    }

    func testTwoHundredWithARangeRequestMeansTheServerIgnoredIt() {
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 200, requestedFromByte: 400), .serverIgnoredRange)
    }

    func testTwoHundredWithoutARangeRequestIsAFreshBody() {
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 200, requestedFromByte: 0), .fresh)
    }

    func testRangeNotSatisfiableRestarts() {
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 416, requestedFromByte: 400), .rangeNotSatisfiable)
    }

    func testUnsolicitedPartialContentRestarts() {
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 206, requestedFromByte: 0), .unexpectedPartialContent)
    }

    func testErrorStatusesAreReported() {
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 404, requestedFromByte: 0), .httpError(404))
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 401, requestedFromByte: 0), .httpError(401))
        XCTAssertEqual(ResumePlanner.reconcile(statusCode: 500, requestedFromByte: 400), .httpError(500))
    }

    // MARK: Partial file naming and measurement

    func testPartialNameIsDerivedFromTheCatalogName() {
        XCTAssertEqual(PartialFiles.partialURL(for: item, in: URL(fileURLWithPath: "/tmp/work")).lastPathComponent,
                       "model.safetensors.partial")
        XCTAssertEqual(PartialFiles.finalURL(for: item, in: URL(fileURLWithPath: "/tmp/work")).lastPathComponent,
                       "model.safetensors")
    }

    func testByteCountReadsWhatIsActuallyOnDisk() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let partial = directory.url.appendingPathComponent("model.safetensors.partial")
        XCTAssertEqual(PartialFiles.byteCount(at: partial), 0, "missing files measure zero, not an error")
        try Payload.bytes(777).write(to: partial)
        XCTAssertEqual(PartialFiles.byteCount(at: partial), 777)
    }

    func testPrepareForAppendCreatesAndTruncates() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let partial = directory.url.appendingPathComponent("tokenizer.json.partial")

        try PartialFiles.prepareForAppend(at: partial, byteCount: 300)
        XCTAssertEqual(PartialFiles.byteCount(at: partial), 300)

        // A stale longer file is cut back to the resume offset, never appended to.
        try Payload.bytes(1_000).write(to: partial)
        try PartialFiles.prepareForAppend(at: partial, byteCount: 300)
        XCTAssertEqual(PartialFiles.byteCount(at: partial), 300)

        // Idempotent when the size already matches.
        try PartialFiles.prepareForAppend(at: partial, byteCount: 300)
        XCTAssertEqual(PartialFiles.byteCount(at: partial), 300)
    }

    func testRemainingPartialNamesListsOnlyPartials() throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let other = DownloadItem(name: "config.json",
                                 url: URL(string: "https://huggingface.co/m/config.json")!,
                                 size: 10, sha256: "")
        try Payload.bytes(10).write(to: PartialFiles.partialURL(for: item, in: directory.url))
        try Payload.bytes(10).write(to: PartialFiles.finalURL(for: other, in: directory.url))

        let remaining = PartialFiles.remainingPartialNames(for: [item, other], in: directory.url)
        XCTAssertEqual(remaining, ["model.safetensors.partial"])
    }
}
