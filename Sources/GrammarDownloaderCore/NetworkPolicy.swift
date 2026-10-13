import Foundation

// MARK: - Origin

/// A host + port pair. The downloader is HTTPS-only, so the implicit port is 443.
///
/// Host comparison is deliberately pedantic — lower-cased, trailing dots stripped,
/// no sub-domain wildcards. `cdn.example.com` is **not** the same origin as
/// `example.com`, which is the whole point (plan v2 §5.2: reject cross-host redirects).
public struct AllowlistedOrigin: Sendable, Hashable, CustomStringConvertible {

    public static let defaultPort = 443

    public let host: String
    public let port: Int

    public init(host: String, port: Int = AllowlistedOrigin.defaultPort) {
        self.host = Self.normalizeHost(host)
        self.port = port
    }

    /// Lower-cases, trims whitespace and drops any trailing root dot so
    /// `EXAMPLE.com.` and `example.com` compare equal.
    public static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// `nil` when the URL carries no usable host (malformed, or a non-hierarchical scheme).
    public init?(url: URL) {
        guard let raw = url.host, !raw.isEmpty else { return nil }
        self.init(host: raw, port: url.port ?? Self.defaultPort)
    }

    public var description: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }
}

// MARK: - Decisions

public enum URLRejection: Sendable, Equatable, CustomStringConvertible {
    case malformedURL
    case schemeNotHTTPS(scheme: String?)
    case missingHost
    case credentialsInURL
    case originNotAllowed(origin: String, allowedOrigins: [String])

    public var description: String {
        switch self {
        case .malformedURL:
            return "the URL has no scheme"
        case .schemeNotHTTPS(let scheme):
            return "scheme '\(scheme ?? "none")' is not https"
        case .missingHost:
            return "the URL has no host"
        case .credentialsInURL:
            return "the URL embeds user:password credentials"
        case .originNotAllowed(let origin, let allowed):
            return "origin '\(origin)' is not allowlisted (allowed: \(allowed.joined(separator: ", ")))"
        }
    }
}

public enum URLAccessDecision: Sendable, Equatable {
    case allow(AllowlistedOrigin)
    case reject(URLRejection)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }

    public var origin: AllowlistedOrigin? {
        if case .allow(let origin) = self { return origin }
        return nil
    }

    public var rejection: URLRejection? {
        if case .reject(let reason) = self { return reason }
        return nil
    }
}

/// A redirect is evaluated with exactly the same rules as a first-request URL —
/// there is no "already trusted the connection" shortcut.
public typealias RedirectDecision = URLAccessDecision

// MARK: - Allowlist

public struct HostAllowlist: Sendable, Equatable {

    public let origins: Set<AllowlistedOrigin>

    public init(origins: some Sequence<AllowlistedOrigin>) {
        self.origins = Set(origins)
    }

    public init(hosts: some Sequence<String>, port: Int = AllowlistedOrigin.defaultPort) {
        self.origins = Set(hosts.map { AllowlistedOrigin(host: $0, port: port) })
    }

    /// Plan v2 §5.2 promises the catalog pins **one** host.
    public var isSingleOrigin: Bool { origins.count == 1 }

    public var hostList: [String] { origins.map(\.description).sorted() }

    /// PURE. No I/O, no network, no clock — the same input always yields the same decision.
    public func decision(for url: URL) -> URLAccessDecision {
        guard let scheme = url.scheme, !scheme.isEmpty else {
            return .reject(.malformedURL)
        }
        guard scheme.lowercased() == "https" else {
            return .reject(.schemeNotHTTPS(scheme: scheme))
        }
        // `https://evil.example@allowed.example/` resolves to allowed.example but is
        // not a URL this app ever builds; refuse rather than reason about it.
        if url.user?.isEmpty == false || url.password?.isEmpty == false {
            return .reject(.credentialsInURL)
        }
        guard let origin = AllowlistedOrigin(url: url) else {
            return .reject(.missingHost)
        }
        if origins.contains(origin) { return .allow(origin) }
        return .reject(.originNotAllowed(origin: origin.description, allowedOrigins: hostList))
    }
}

// MARK: - The pure policy entry point

/// Every network decision the downloader makes funnels through here, so the
/// security-critical rules can be unit-tested with no URLSession in sight.
///
/// The only place these functions are bypassed is *nowhere*: `URLSessionFileTransport`
/// calls `evaluate` before it builds a request and `evaluateRedirect` from inside
/// `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`,
/// where returning `nil` means "do not follow" (plan v2 §5.2).
public enum NetworkPolicy {

    /// May a first request be sent to `url`?
    public static func evaluate(_ url: URL, allowlist: HostAllowlist) -> URLAccessDecision {
        allowlist.decision(for: url)
    }

    /// May a redirect received *while fetching `from`* be followed to `to`?
    ///
    /// Rules, in order:
    ///  1. the request that produced the redirect must itself have been allowed;
    ///  2. the target must be HTTPS;
    ///  3. the target origin (host **and** port) must be in the allowlist.
    ///
    /// With today's single-origin catalog allowlist this rejects every cross-host
    /// redirect, including a CDN redirect on the same registrable domain.
    /// See `Sources/Shared/GrammarDownloading.swift` and the report for why that
    /// is intentional and what it means for Hugging Face's `cdn-lfs` redirect.
    public static func evaluateRedirect(from: URL?, to: URL, allowlist: HostAllowlist) -> RedirectDecision {
        if let from {
            guard allowlist.decision(for: from).isAllowed else {
                return .reject(.originNotAllowed(
                    origin: AllowlistedOrigin(url: from)?.description ?? "unknown",
                    allowedOrigins: allowlist.hostList))
            }
        }
        return allowlist.decision(for: to)
    }

    /// Convenience for the common "is this redirect target still ours?" question.
    public static func isCrossHostRedirect(from: URL?, to: URL, allowlist: HostAllowlist) -> Bool {
        guard let from, let fromOrigin = AllowlistedOrigin(url: from),
              let toOrigin = AllowlistedOrigin(url: to) else { return true }
        return fromOrigin != toOrigin
    }
}
