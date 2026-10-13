import XCTest
@testable import GrammarDownloaderCore

/// Plan construction is where "exactly one allowlisted HTTPS host" and
/// "catalog names are not trusted as path components" are enforced.
final class DownloadPlanTests: XCTestCase {

    private func item(_ name: String,
                      host: String = "huggingface.co",
                      scheme: String = "https",
                      size: Int64 = 10,
                      pin: String = "") -> DownloadItem {
        DownloadItem(name: name,
                     url: URL(string: "\(scheme)://\(host)/m/\(name)")!,
                     size: size,
                     sha256: pin)
    }

    // MARK: Happy path

    func testPlanDerivesASingleOriginAllowlist() throws {
        let plan = try DownloadPlan(modelID: "qwen3-0.6b-4bit", revision: "73e3e38d9813", files: [
            item("model.safetensors", size: 335_500_000),
            item("tokenizer.json", size: 11_400_000),
            item("vocab.json", size: 2_800_000),
            item("config.json", size: 1_000),
        ])
        XCTAssertTrue(plan.allowlist.isSingleOrigin)
        XCTAssertEqual(plan.allowlist.hostList, ["huggingface.co"])
        XCTAssertEqual(plan.allowlistedHost, "huggingface.co")
        XCTAssertEqual(plan.totalBytes, 349_701_000)
        XCTAssertEqual(plan.pinnedFileCount, 0, "the shipped catalog has no digests pinned yet")
    }

    func testPinnedFileCountCountsRealDigests() throws {
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [
            item("a.bin", pin: String(repeating: "a", count: 64)),
            item("b.bin", pin: ""),
        ])
        XCTAssertEqual(plan.pinnedFileCount, 1)
    }

    // MARK: Host rules

    func testPlanRejectsTwoHosts() {
        XCTAssertThrowsError(try DownloadPlan(modelID: "m", revision: "r", files: [
            item("a.bin"), item("b.bin", host: "cdn-lfs.huggingface.co"),
        ])) { error in
            XCTAssertEqual(error as? DownloadPlan.ValidationError,
                           .multipleHosts(["cdn-lfs.huggingface.co", "huggingface.co"]))
        }
    }

    func testPlanRejectsPlainHTTP() {
        XCTAssertThrowsError(try DownloadPlan(modelID: "m", revision: "r", files: [
            item("a.bin", scheme: "http"),
        ]))
    }

    func testPlanAcceptsTheSameHostOnADifferentPath() throws {
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [
            DownloadItem(name: "a.bin", url: URL(string: "https://huggingface.co/one/a.bin")!, size: 1, sha256: ""),
            DownloadItem(name: "b.bin", url: URL(string: "https://huggingface.co/two/b.bin")!, size: 1, sha256: ""),
        ])
        XCTAssertEqual(plan.files.count, 2)
    }

    func testPlanRejectsAnEmptyFileList() {
        XCTAssertThrowsError(try DownloadPlan(modelID: "m", revision: "r", files: [])) { error in
            XCTAssertEqual(error as? DownloadPlan.ValidationError, .emptyPlan)
        }
    }

    func testPlanRejectsInvalidURL() {
        let bad = DownloadItem(name: "a.bin", url: URL(string: "https://")!, size: 1, sha256: "")
        XCTAssertThrowsError(try DownloadPlan(modelID: "m", revision: "r", files: [bad])) { error in
            XCTAssertEqual(error as? DownloadPlan.ValidationError, .invalidURL(name: "a.bin", reason: .missingHost))
        }
    }

    // MARK: File-name safety

    func testUnsafeFileNamesAreRejected() {
        for name in ["../escape.bin", "a/b.bin", "..", ".", "", ".hidden", "x.partial", "back\\slash.bin"] {
            XCTAssertThrowsError(try DownloadPlan(modelID: "m", revision: "r", files: [item(name)]),
                                 "'\(name)' must be rejected") { error in
                guard case .unsafeFileName? = error as? DownloadPlan.ValidationError else {
                    return XCTFail("unexpected error for '\(name)': \(error)")
                }
            }
        }
    }

    func testOrdinaryCatalogNamesAreAccepted() {
        for name in ["model.safetensors", "tokenizer.json", "vocab.json", "config.json",
                     "tokenizer_config.json", "special_tokens_map.json", "generation_config.json",
                     "chat_template.jinja", "model-00001-of-00002.safetensors"] {
            XCTAssertTrue(FileNamePolicy.isSafe(name), "'\(name)' should be accepted")
        }
    }

    func testNamePolicyGivesAReason() {
        XCTAssertEqual(FileNamePolicy.rejectionReason(for: "../evil"), "path separator in file name")
        XCTAssertNil(FileNamePolicy.rejectionReason(for: "model.safetensors"))
    }

    // MARK: Containment

    func testContainmentCheckRejectsEscapes() {
        let work = URL(fileURLWithPath: "/tmp/a/work")
        XCTAssertTrue(FileNamePolicy.isContained(work.appendingPathComponent("model.safetensors"), in: work))
        XCTAssertFalse(FileNamePolicy.isContained(work.appendingPathComponent("../evil"), in: work))
        XCTAssertFalse(FileNamePolicy.isContained(URL(fileURLWithPath: "/tmp/a/evil"), in: work))
        XCTAssertFalse(FileNamePolicy.isContained(URL(fileURLWithPath: "/tmp/awsome/x"), in: work),
                       "a shared path prefix must not count as containment")
    }

    // MARK: Item details

    func testPartialNameDerivesFromTheCatalogName() {
        XCTAssertEqual(item("model.safetensors").partialFileName, "model.safetensors.partial")
    }

    func testHasPinnedDigestDistinguishesEmptyPin() {
        XCTAssertTrue(item("a.bin", pin: "abc").hasPinnedDigest)
        XCTAssertFalse(item("a.bin", pin: "").hasPinnedDigest)
    }
}
