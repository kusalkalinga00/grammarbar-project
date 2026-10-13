import Foundation

/// What a transport is asked to do. The engine owns resume bookkeeping and
/// hashing; the transport only writes bytes to `destination` (appending when
/// `resumeFromByte > 0`) and reports how much it wrote.
public struct TransportRequest: Sendable, Equatable {
    public let item: DownloadItem
    /// Destination file — always `<workingDirectory>/<name>.partial`.
    public let destination: URL
    /// Offset already on disk that the server must continue from. `0` means a fresh GET.
    public let resumeFromByte: Int64
    /// Enforced by the transport, not by the caller: pre-flight and at every redirect.
    public let allowlist: HostAllowlist

    public init(item: DownloadItem, destination: URL, resumeFromByte: Int64, allowlist: HostAllowlist) {
        self.item = item
        self.destination = destination
        self.resumeFromByte = resumeFromByte
        self.allowlist = allowlist
    }
}

public struct TransportOutcome: Sendable, Equatable {
    /// Bytes appended by *this* transfer, not counting what was already on disk.
    public let bytesWrittenInSession: Int64
    /// True when the server ignored our `Range` header and the file was truncated back to zero.
    public let restartedFromZero: Bool

    public init(bytesWrittenInSession: Int64, restartedFromZero: Bool = false) {
        self.bytesWrittenInSession = bytesWrittenInSession
        self.restartedFromZero = restartedFromZero
    }
}

/// Transport seam. `URLSessionFileTransport` is the production implementation;
/// tests substitute a scripted transport so the whole engine — resume, retry,
/// cancellation, hashing, cleanup — runs with no network access.
public protocol DownloadTransport: Sendable {

    /// Appends to `request.destination`. `onBytes` is called as data lands with the
    /// cumulative byte count written *in this session* (starting at 0), so the
    /// caller can add `resumeFromByte` for an absolute figure.
    ///
    /// The closure is `@escaping` on purpose: implementations store it on a
    /// delegate that outlives the call.
    func transfer(_ request: TransportRequest,
                  onBytes: @escaping @Sendable (Int64) -> Void) async throws -> TransportOutcome
}
