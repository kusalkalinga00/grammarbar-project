import XCTest
@testable import GrammarDownloaderCore

/// "A redirect to any other host must be REJECTED, not followed."
/// These are the tests for the delegate hook's decision function.
final class RedirectRejectionTests: XCTestCase {

    private let allowlist = HostAllowlist(hosts: ["huggingface.co"])
    private let origin = URL(string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/abc/model.safetensors")!

    private func redirect(_ to: String) -> RedirectDecision {
        NetworkPolicy.evaluateRedirect(from: origin, to: URL(string: to)!, allowlist: allowlist)
    }

    // MARK: The headline rule

    func testRejectsRedirectToForeignHost() {
        let result = redirect("https://evil.example.com/model.safetensors")
        XCTAssertFalse(result.isAllowed)
        XCTAssertEqual(result.rejection, .originNotAllowed(origin: "evil.example.com",
                                                           allowedOrigins: ["huggingface.co"]))
    }

    func testRejectsRedirectToHuggingFaceCDN() {
        // The real `huggingface.co/…/resolve/…` endpoint 302s to `cdn-lfs`/`xethub`.
        // Under the single-origin policy this is refused by design — plan v2 §11's
        // mitigation is "own CDN + pinned hashes", not "trust the redirect".
        XCTAssertFalse(redirect("https://cdn-lfs.huggingface.co/blob/main/model.safetensors").isAllowed)
        XCTAssertFalse(redirect("https://cas-bridge.xethub.hf.co/blob/model.safetensors").isAllowed)
    }

    func testRejectsRedirectToSubdomainOfTheSameHost() {
        XCTAssertFalse(redirect("https://mirror.huggingface.co/model.safetensors").isAllowed)
    }

    func testRejectsRedirectToLookalikeSuffixHost() {
        XCTAssertFalse(redirect("https://huggingface.co.attacker.net/model.safetensors").isAllowed)
    }

    func testRejectsRedirectDowngradeToHTTP() {
        XCTAssertEqual(redirect("http://huggingface.co/model.safetensors"),
                       .reject(.schemeNotHTTPS(scheme: "http")))
    }

    func testRejectsRedirectToForeignPort() {
        XCTAssertFalse(redirect("https://huggingface.co:8443/model.safetensors").isAllowed)
    }

    func testRejectsRedirectToNonHTTPScheme() {
        XCTAssertFalse(redirect("file:///etc/passwd").isAllowed)
    }

    func testRejectsRedirectWithCredentials() {
        XCTAssertFalse(redirect("https://user@huggingface.co/model.safetensors").isAllowed)
    }

    // MARK: Allowed cases

    func testAllowsRedirectThatStaysOnTheAllowlistedOrigin() {
        let result = redirect("https://huggingface.co/other/path/model.safetensors")
        XCTAssertTrue(result.isAllowed)
        XCTAssertEqual(result.origin, AllowlistedOrigin(host: "huggingface.co", port: 443))
    }

    func testAllowsSameOriginHTTPSUpgradeOfPath() {
        XCTAssertTrue(redirect("https://huggingface.co/x?y=1").isAllowed)
    }

    func testAllowsRedirectWhenTargetIsExplicitlyAllowlisted() {
        let wider = HostAllowlist(hosts: ["huggingface.co", "cdn-lfs.huggingface.co"])
        let result = NetworkPolicy.evaluateRedirect(from: origin,
                                                    to: URL(string: "https://cdn-lfs.huggingface.co/blob/x")!,
                                                    allowlist: wider)
        XCTAssertTrue(result.isAllowed)
    }

    // MARK: Origin integrity

    func testRejectsRedirectWhenTheOriginalRequestWasItselfNotAllowlisted() {
        let foreign = URL(string: "https://evil.example.com/start")!
        let result = NetworkPolicy.evaluateRedirect(from: foreign,
                                                    to: URL(string: "https://huggingface.co/x")!,
                                                    allowlist: allowlist)
        XCTAssertFalse(result.isAllowed)
    }

    func testCrossHostDetectionIsTrueOnlyAcrossOrigins() {
        XCTAssertTrue(NetworkPolicy.isCrossHostRedirect(from: origin,
                                                        to: URL(string: "https://cdn-lfs.huggingface.co/x")!,
                                                        allowlist: allowlist))
        XCTAssertFalse(NetworkPolicy.isCrossHostRedirect(from: origin,
                                                         to: URL(string: "https://huggingface.co/y")!,
                                                         allowlist: allowlist))
        XCTAssertTrue(NetworkPolicy.isCrossHostRedirect(from: origin,
                                                        to: URL(string: "https://huggingface.co:8443/y")!,
                                                        allowlist: allowlist))
    }

    // MARK: Purity

    func testDecisionIsPureAndRepeatable() {
        let to = URL(string: "https://evil.example.com/x")!
        let first = NetworkPolicy.evaluateRedirect(from: origin, to: to, allowlist: allowlist)
        let second = NetworkPolicy.evaluateRedirect(from: origin, to: to, allowlist: allowlist)
        XCTAssertEqual(first, second)
    }

    func testRedirectDecisionMatchesFirstRequestDecisionForTheSameURL() {
        // A redirect target is not special-cased: same rules as the initial URL.
        let target = URL(string: "https://cdn-lfs.huggingface.co/x")!
        XCTAssertEqual(NetworkPolicy.evaluateRedirect(from: origin, to: target, allowlist: allowlist),
                       NetworkPolicy.evaluate(target, allowlist: allowlist))
    }
}
