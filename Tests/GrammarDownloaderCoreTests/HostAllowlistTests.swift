import XCTest
@testable import GrammarDownloaderCore

/// The single most important behaviour in this target: exactly one allowlisted
/// HTTPS host, decided by a pure function with no network involved.
final class HostAllowlistTests: XCTestCase {

    private let allowlist = HostAllowlist(hosts: ["huggingface.co"])

    private func decision(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> URLAccessDecision {
        guard let url = URL(string: string) else {
            XCTFail("could not build URL from \(string)", file: file, line: line)
            return .reject(.malformedURL)
        }
        return allowlist.decision(for: url)
    }

    // MARK: Acceptance

    func testAcceptsAllowlistedHTTPSURL() {
        XCTAssertTrue(decision("https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/73e3e38d9813/model.safetensors").isAllowed)
    }

    func testAcceptsExplicitDefaultPort() {
        XCTAssertTrue(decision("https://huggingface.co:443/model.safetensors").isAllowed)
    }

    func testAcceptsURLWithQueryAndFragment() {
        XCTAssertTrue(decision("https://huggingface.co/file?download=true#fragment").isAllowed)
    }

    func testAllowedDecisionCarriesTheNormalisedOrigin() {
        let allowed = decision("https://huggingface.co/model.safetensors")
        XCTAssertEqual(allowed.origin, AllowlistedOrigin(host: "huggingface.co", port: 443))
    }

    // MARK: Rejection

    func testRejectsHostNotInAllowlist() {
        XCTAssertEqual(decision("https://evil.example.com/model.safetensors"), .reject(.originNotAllowed(
            origin: "evil.example.com", allowedOrigins: ["huggingface.co"])))
    }

    func testRejectsSubdomainOfAllowlistedHost() {
        // No wildcard matching: a compromised CDN subdomain must not be reachable.
        let result = decision("https://cdn-lfs.huggingface.co/model.safetensors")
        XCTAssertFalse(result.isAllowed)
        XCTAssertNotNil(result.rejection)
    }

    func testRejectsLookalikeSuffixHost() {
        XCTAssertFalse(decision("https://huggingface.co.evil.com/model.safetensors").isAllowed)
    }

    func testRejectsLookalikePrefixHost() {
        XCTAssertFalse(decision("https://nothuggingface.co/model.safetensors").isAllowed)
    }

    func testRejectsUnexpectedPort() {
        XCTAssertEqual(decision("https://huggingface.co:8443/model.safetensors"),
                       .reject(.originNotAllowed(origin: "huggingface.co:8443",
                                                 allowedOrigins: ["huggingface.co"])))
    }

    func testRejectsPlainHTTP() {
        XCTAssertEqual(decision("http://huggingface.co/model.safetensors"),
                       .reject(.schemeNotHTTPS(scheme: "http")))
    }

    func testRejectsNonHTTPSchemes() {
        XCTAssertEqual(decision("ftp://huggingface.co/model.safetensors"),
                       .reject(.schemeNotHTTPS(scheme: "ftp")))
        XCTAssertEqual(decision("file:///etc/passwd"),
                       .reject(.schemeNotHTTPS(scheme: "file")))
    }

    func testRejectsSchemelessURL() {
        XCTAssertEqual(decision("huggingface.co/model.safetensors"), .reject(.malformedURL))
    }

    func testRejectsURLWithoutHost() {
        XCTAssertEqual(decision("https://"), .reject(.missingHost))
    }

    func testRejectsCredentialsInURL() {
        XCTAssertEqual(decision("https://user:pass@huggingface.co/model.safetensors"),
                       .reject(.credentialsInURL))
    }

    // MARK: Normalisation

    func testHostComparisonIsCaseInsensitive() {
        // Foundation does not lower-case the host for us: URL.host of
        // "HTTPS://HuggingFace.CO/x" is still "HuggingFace.CO".
        XCTAssertTrue(decision("HTTPS://HuggingFace.CO/model.safetensors").isAllowed)
    }

    func testTrailingRootDotIsIgnored() {
        XCTAssertTrue(decision("https://huggingface.co./model.safetensors").isAllowed)
    }

    func testNormalizeHostStripsDotsAndCase() {
        XCTAssertEqual(AllowlistedOrigin.normalizeHost("  HUGGINGFACE.CO. "), "huggingface.co")
        XCTAssertEqual(AllowlistedOrigin.normalizeHost("a.b..."), "a.b")
    }

    // MARK: Allowlist shape

    func testSingleOriginAllowlistIsReported() {
        XCTAssertTrue(allowlist.isSingleOrigin)
        XCTAssertEqual(allowlist.hostList, ["huggingface.co"])
    }

    func testMultiOriginAllowlistRejectsTheSecondHostOnlyWhenNotListed() {
        let wider = HostAllowlist(hosts: ["huggingface.co", "cdn-lfs.huggingface.co"])
        XCTAssertFalse(wider.isSingleOrigin)
        XCTAssertEqual(wider.hostList, ["cdn-lfs.huggingface.co", "huggingface.co"])
        XCTAssertTrue(wider.decision(for: URL(string: "https://cdn-lfs.huggingface.co/x")!).isAllowed)
        XCTAssertFalse(wider.decision(for: URL(string: "https://other.example.com/x")!).isAllowed)
    }

    func testPolicyEntryPointAgreesWithAllowlist() {
        let url = URL(string: "https://huggingface.co/x")!
        XCTAssertEqual(NetworkPolicy.evaluate(url, allowlist: allowlist), allowlist.decision(for: url))
    }
}
