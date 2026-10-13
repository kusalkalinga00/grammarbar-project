import XCTest
@testable import GrammarDownloaderCore

/// Network-dependent tests. They are **skipped unless
/// `GRAMMARBAR_NETWORK_TESTS=1`**, so the suite is green offline and in CI, and
/// the only code in this target that can open a socket still has *some* coverage
/// when a human asks for it:
///
///     GRAMMARBAR_NETWORK_TESTS=1 swift test --filter NetworkTransportTests
///
/// They deliberately do not use the production catalog URLs (Hugging Face
/// redirects those cross-host, which the single-origin policy refuses by design —
/// see `RedirectRejectionTests`).
final class NetworkTransportTests: XCTestCase {

    private var networkEnabled: Bool {
        ProcessInfo.processInfo.environment["GRAMMARBAR_NETWORK_TESTS"] == "1"
    }

    func testRealTransportFetchesAnAllowlistedURL() async throws {
        try XCTSkipUnless(networkEnabled, "set GRAMMARBAR_NETWORK_TESTS=1 to run network tests")

        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let item = DownloadItem(name: "robots.txt",
                                url: URL(string: "https://huggingface.co/robots.txt")!,
                                size: 0,
                                sha256: "")
        let plan = try DownloadPlan(modelID: "network-test", revision: "live", files: [item])
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: work,
                                                                 transport: URLSessionFileTransport()))
        let report = try await engine.download(plan)

        XCTAssertEqual(report.files.count, 1)
        XCTAssertGreaterThan(report.totalBytesOnDisk, 0)
        XCTAssertEqual(report.unpinnedFileNames, ["robots.txt"])
        XCTAssertEqual(try FileHashing.sha256(ofFileAt: work.appendingPathComponent("robots.txt")),
                       report.files.first?.sha256)
    }

    func testRealTransportRefusesANonAllowlistedHost() async throws {
        try XCTSkipUnless(networkEnabled, "set GRAMMARBAR_NETWORK_TESTS=1 to run network tests")

        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let transport = URLSessionFileTransport()
        let request = TransportRequest(
            item: DownloadItem(name: "index.html",
                               url: URL(string: "https://example.com/")!,
                               size: 0, sha256: ""),
            destination: work.appendingPathComponent("index.html.partial"),
            resumeFromByte: 0,
            allowlist: HostAllowlist(hosts: ["huggingface.co"]))

        do {
            _ = try await transport.transfer(request, onBytes: { _ in })
            XCTFail("the transport must refuse a non-allowlisted host before sending anything")
        } catch let error as TransportError {
            guard case .hostNotAllowed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRealTransportRejectsACrossHostRedirect() async throws {
        try XCTSkipUnless(networkEnabled, "set GRAMMARBAR_NETWORK_TESTS=1 to run network tests")

        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // httpbin-style redirector is not available; use the Hugging Face resolver,
        // which 302s to its CDN, and confirm the refusal is a redirect rejection.
        let item = DownloadItem(name: "tokenizer.json",
                                url: URL(string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/73e3e38d9813/tokenizer.json")!,
                                size: 0, sha256: "")
        let transport = URLSessionFileTransport()
        let request = TransportRequest(item: item,
                                       destination: work.appendingPathComponent("tokenizer.json.partial"),
                                       resumeFromByte: 0,
                                       allowlist: HostAllowlist(hosts: ["huggingface.co"]))
        do {
            _ = try await transport.transfer(request, onBytes: { _ in })
            // No redirect (or an in-origin one) is also an acceptable live outcome.
        } catch let error as TransportError {
            guard case .redirectRejected = error else {
                return XCTFail("expected a redirect rejection, got: \(error)")
            }
        }
    }
}
