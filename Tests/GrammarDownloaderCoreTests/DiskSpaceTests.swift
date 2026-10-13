import XCTest
@testable import GrammarDownloaderCore

/// The pre-flight arithmetic: "at least 2x the total download size".
final class DiskSpaceTests: XCTestCase {

    // MARK: Multiplier

    func testRequiresTwiceTheTotal() {
        XCTAssertEqual(DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: 100), 200)
        XCTAssertEqual(DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: 0), 0)
    }

    func testRequiredBytesUsesTheDocumentedDefaultMultiplier() {
        XCTAssertEqual(DiskSpacePolicy.requiredMultiplier, 2)
    }

    func testRequiredBytesHonoursACustomMultiplier() {
        XCTAssertEqual(DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: 100, multiplier: 3), 300)
        XCTAssertEqual(DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: 100, multiplier: 0), 100,
                       "a nonsense multiplier must not make the check weaker than 1x")
    }

    func testNegativeTotalIsTreatedAsZero() {
        XCTAssertEqual(DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: -5), 0)
    }

    func testOverflowSaturatesInsteadOfTrapping() {
        XCTAssertEqual(DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: .max), .max)
        XCTAssertEqual(DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: .max, multiplier: .max), .max)
    }

    // MARK: Decision

    func testExactBoundaryIsSufficient() {
        let decision = DiskSpacePolicy.decision(availableBytes: 200, totalDownloadBytes: 100)
        XCTAssertEqual(decision, .sufficient(requiredBytes: 200, availableBytes: 200))
        XCTAssertTrue(decision.isSufficient)
    }

    func testOneByteShortIsInsufficient() {
        let decision = DiskSpacePolicy.decision(availableBytes: 199, totalDownloadBytes: 100)
        XCTAssertEqual(decision, .insufficient(requiredBytes: 200, availableBytes: 199, shortfallBytes: 1))
        XCTAssertFalse(decision.isSufficient)
    }

    func testShortfallIsReported() {
        guard case .insufficient(let required, let available, let shortfall) =
                DiskSpacePolicy.decision(availableBytes: 100, totalDownloadBytes: 1_000) else {
            return XCTFail("expected insufficient")
        }
        XCTAssertEqual(required, 2_000)
        XCTAssertEqual(available, 100)
        XCTAssertEqual(shortfall, 1_900)
    }

    func testUnknownCapacityIsReportedNotGuessed() {
        XCTAssertEqual(DiskSpacePolicy.decision(availableBytes: nil, totalDownloadBytes: 100),
                       .capacityUnknown(requiredBytes: 200))
        XCTAssertEqual(DiskSpacePolicy.decision(availableBytes: -1, totalDownloadBytes: 100),
                       .capacityUnknown(requiredBytes: 200))
    }

    func testZeroBytePlanAlwaysFits() {
        XCTAssertTrue(DiskSpacePolicy.decision(availableBytes: 0, totalDownloadBytes: 0).isSufficient)
    }

    // MARK: Real catalog numbers

    func testQwen3PrimaryPickNeedsAboutSevenHundredMegabytes() {
        // 351.4 MB measured for Qwen3-0.6B-4bit (plan v2 §5.4) => ~702.8 MB of headroom.
        let total: Int64 = 351_400_000
        let required = DiskSpacePolicy.requiredBytes(forTotalDownloadBytes: total)
        XCTAssertEqual(required, 702_800_000)
        XCTAssertTrue(DiskSpacePolicy.decision(availableBytes: 702_800_000, totalDownloadBytes: total).isSufficient)
        XCTAssertFalse(DiskSpacePolicy.decision(availableBytes: 702_799_999, totalDownloadBytes: total).isSufficient)
    }

    func testRealVolumeReportsACapacity() throws {
        // The only I/O in this file; runs against the scratch directory.
        let directory = TempDirectory()
        defer { directory.remove() }
        let capacity = DiskSpacePolicy.availableBytes(at: directory.url)
        // A nil here is legitimate (unusual volume), but on a normal boot volume
        // we expect a positive figure.
        if let capacity {
            XCTAssertGreaterThan(capacity, 0)
        }
    }
}
