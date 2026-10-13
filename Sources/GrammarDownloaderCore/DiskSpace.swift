import Foundation

/// Pre-flight disk-space arithmetic.
///
/// Plan v2 §5.3 / the download requirements: refuse to start unless the volume
/// holding the working directory has at least **2×** the total download size free.
/// The multiplication and the comparison are pure; only `availableBytes(at:)`
/// touches the file system, and that one is injectable in the engine.
public enum DiskSpaceDecision: Sendable, Equatable {
    case sufficient(requiredBytes: Int64, availableBytes: Int64)
    case insufficient(requiredBytes: Int64, availableBytes: Int64, shortfallBytes: Int64)
    case capacityUnknown(requiredBytes: Int64)

    public var isSufficient: Bool {
        if case .sufficient = self { return true }
        return false
    }

    public var requiredBytes: Int64 {
        switch self {
        case .sufficient(let required, _): return required
        case .insufficient(let required, _, _): return required
        case .capacityUnknown(let required): return required
        }
    }
}

public enum DiskSpacePolicy {

    /// "at least 2x the total download size" — the multiplier is a named constant,
    /// not a literal buried in a call site.
    public static let requiredMultiplier: Int64 = 2

    /// Saturates at `Int64.max` instead of trapping on overflow, so a nonsense
    /// catalog entry can only ever make the check *more* conservative.
    public static func requiredBytes(forTotalDownloadBytes total: Int64,
                                     multiplier: Int64 = DiskSpacePolicy.requiredMultiplier) -> Int64 {
        let bytes = max(0, total)
        let factor = max(1, multiplier)
        let (product, overflow) = bytes.multipliedReportingOverflow(by: factor)
        return overflow ? Int64.max : product
    }

    /// PURE. `availableBytes == nil` means "the volume did not report a capacity",
    /// which is reported as `.capacityUnknown` rather than guessed at.
    public static func decision(availableBytes: Int64?,
                                totalDownloadBytes: Int64,
                                multiplier: Int64 = DiskSpacePolicy.requiredMultiplier) -> DiskSpaceDecision {
        let required = requiredBytes(forTotalDownloadBytes: totalDownloadBytes, multiplier: multiplier)
        guard let available = availableBytes, available >= 0 else {
            return .capacityUnknown(requiredBytes: required)
        }
        if available >= required {
            return .sufficient(requiredBytes: required, availableBytes: available)
        }
        return .insufficient(requiredBytes: required, availableBytes: available,
                             shortfallBytes: required - available)
    }

    /// The only I/O in this file. Prefers `volumeAvailableCapacityForImportantUsage`,
    /// which is the figure that accounts for purgeable space; falls back to the
    /// plain volume capacity when the first is unavailable.
    public static func availableBytes(at url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return nil
    }
}
