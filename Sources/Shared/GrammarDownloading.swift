import Foundation

// ============================================================================
//  XPC contract: GrammarBar.app  <->  GrammarDownloader.xpc
// ============================================================================
//
//  Why this file exists
//  --------------------
//  The app's privacy claim (plan v2 §7) is that the process handling user text
//  has **no network access**. Downloading needs `network.client`, so it lives in
//  a separate XPC service: the app has the entitlement off, the service has it on,
//  and the service is only ever handed a model id and a list of URLs. No user text
//  crosses this boundary in either direction — there is no field for it.
//
//  How the temp folder is handed back
//  ----------------------------------
//  `GDDownloadReply.workingDirectoryURL` is the handover point. On success the
//  service has downloaded every file into one directory, verified each SHA-256,
//  and renamed `<name>.partial` -> `<name>` so the directory contains only final
//  files. The app takes that URL and calls:
//
//      ModelStore.install(fromTemporaryDirectory: reply.workingDirectoryURL,
//                         catalog: catalogModel,
//                         licenseText: licenseText)
//
//  which re-does the required-file check, the 500 MB gate, the hashing, the
//  atomic move and the manifest write. The reply is advisory; the bytes on disk
//  are the source of truth, and `ModelStore` deletes the directory as it moves
//  it into place.
//
//  NOTE for the `.xcodeproj` workstream (cannot be verified without it): the app
//  is sandboxed, so it cannot read the XPC service's private container. The
//  handover directory must therefore live in a container both processes can see,
//  i.e. an application-group container such as `group.<team-id>.GrammarBar`
//  (`GDDownloadRequest.workingDirectoryPath` carries it). That needs
//  `com.apple.security.application-groups` on both targets — deliberately NOT
//  written into the entitlements plists, because plan v2 §6 specifies a narrower
//  set and adding entitlements silently would be worse than flagging it.
//
//  This file is compiled into the XPC bundle target (see project.yml) together
//  with Sources/GrammarDownloaderCore. It is Foundation-only on purpose: the
//  service must not link GrammarBarCore, which owns model installation.
// ============================================================================

/// `NSXPCConnection` cannot carry Swift structs or enums, so every payload is an
/// `NSSecureCoding` class of primitives.
@objc(GDDownloadFile)
public final class GDDownloadFile: NSObject, NSSecureCoding {

    public let name: String
    public let urlString: String
    public let size: Int64
    /// Empty means "not pinned yet" — see `GDDownloadedFile.wasVerified`.
    public let sha256: String

    public init(name: String, urlString: String, size: Int64, sha256: String) {
        self.name = name
        self.urlString = urlString
        self.size = size
        self.sha256 = sha256
        super.init()
    }

    public var url: URL? { URL(string: urlString) }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(name, forKey: Key.name)
        coder.encode(urlString, forKey: Key.urlString)
        coder.encode(size, forKey: Key.size)
        coder.encode(sha256, forKey: Key.sha256)
    }

    public required init?(coder: NSCoder) {
        guard let name = coder.decodeObject(of: NSString.self, forKey: Key.name) as String?,
              let urlString = coder.decodeObject(of: NSString.self, forKey: Key.urlString) as String?,
              let sha256 = coder.decodeObject(of: NSString.self, forKey: Key.sha256) as String?
        else { return nil }
        self.name = name
        self.urlString = urlString
        self.size = coder.decodeInt64(forKey: Key.size)
        self.sha256 = sha256
        super.init()
    }

    private enum Key {
        static let name = "name"
        static let urlString = "urlString"
        static let size = "size"
        static let sha256 = "sha256"
    }
}

/// Everything the service needs, and nothing else. There is no text field here,
/// by construction.
@objc(GDDownloadRequest)
public final class GDDownloadRequest: NSObject, NSSecureCoding {

    public let requestID: String
    public let modelID: String
    public let displayName: String
    public let license: String
    public let revision: String
    /// Where the service may write, and the directory handed back on success.
    /// Must be a container the sandboxed app can read (see the header).
    public let workingDirectoryPath: String
    public let files: [GDDownloadFile]
    /// If true the service re-verifies and returns the manifest without network
    /// access — used by "the model is already downloaded, is it still intact?".
    public let verifyOnly: Bool

    public init(requestID: String = UUID().uuidString,
                modelID: String,
                displayName: String,
                license: String,
                revision: String,
                workingDirectoryPath: String,
                files: [GDDownloadFile],
                verifyOnly: Bool = false) {
        self.requestID = requestID
        self.modelID = modelID
        self.displayName = displayName
        self.license = license
        self.revision = revision
        self.workingDirectoryPath = workingDirectoryPath
        self.files = files
        self.verifyOnly = verifyOnly
        super.init()
    }

    public var workingDirectoryURL: URL { URL(fileURLWithPath: workingDirectoryPath, isDirectory: true) }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID, forKey: Key.requestID)
        coder.encode(modelID, forKey: Key.modelID)
        coder.encode(displayName, forKey: Key.displayName)
        coder.encode(license, forKey: Key.license)
        coder.encode(revision, forKey: Key.revision)
        coder.encode(workingDirectoryPath, forKey: Key.workingDirectoryPath)
        coder.encode(files as NSArray, forKey: Key.files)
        coder.encode(verifyOnly, forKey: Key.verifyOnly)
    }

    public required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: Key.requestID) as String?,
              let modelID = coder.decodeObject(of: NSString.self, forKey: Key.modelID) as String?,
              let displayName = coder.decodeObject(of: NSString.self, forKey: Key.displayName) as String?,
              let license = coder.decodeObject(of: NSString.self, forKey: Key.license) as String?,
              let revision = coder.decodeObject(of: NSString.self, forKey: Key.revision) as String?,
              let workingDirectoryPath = coder.decodeObject(of: NSString.self, forKey: Key.workingDirectoryPath) as String?,
              let files = coder.decodeObject(of: [NSArray.self, GDDownloadFile.self], forKey: Key.files) as? [GDDownloadFile]
        else { return nil }
        self.requestID = requestID
        self.modelID = modelID
        self.displayName = displayName
        self.license = license
        self.revision = revision
        self.workingDirectoryPath = workingDirectoryPath
        self.files = files
        self.verifyOnly = coder.decodeBool(forKey: Key.verifyOnly)
        super.init()
    }

    private enum Key {
        static let requestID = "requestID"
        static let modelID = "modelID"
        static let displayName = "displayName"
        static let license = "license"
        static let revision = "revision"
        static let workingDirectoryPath = "workingDirectoryPath"
        static let files = "files"
        static let verifyOnly = "verifyOnly"
    }
}

/// Sent many times, app-ward, over the app's `GrammarDownloadProgressReporting` proxy.
@objc(GDDownloadProgress)
public final class GDDownloadProgress: NSObject, NSSecureCoding {

    public let requestID: String
    public let fileName: String
    public let fileIndex: Int
    public let fileCount: Int
    public let bytesReceivedForFile: Int64
    public let bytesTotalForFile: Int64
    public let bytesReceivedOverall: Int64
    public let bytesTotalOverall: Int64

    public init(requestID: String, fileName: String, fileIndex: Int, fileCount: Int,
                bytesReceivedForFile: Int64, bytesTotalForFile: Int64,
                bytesReceivedOverall: Int64, bytesTotalOverall: Int64) {
        self.requestID = requestID
        self.fileName = fileName
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.bytesReceivedForFile = bytesReceivedForFile
        self.bytesTotalForFile = bytesTotalForFile
        self.bytesReceivedOverall = bytesReceivedOverall
        self.bytesTotalOverall = bytesTotalOverall
        super.init()
    }

    public var overallFraction: Double {
        guard bytesTotalOverall > 0 else { return 0 }
        return min(1, max(0, Double(bytesReceivedOverall) / Double(bytesTotalOverall)))
    }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID, forKey: Key.requestID)
        coder.encode(fileName, forKey: Key.fileName)
        coder.encode(fileIndex, forKey: Key.fileIndex)
        coder.encode(fileCount, forKey: Key.fileCount)
        coder.encode(bytesReceivedForFile, forKey: Key.bytesReceivedForFile)
        coder.encode(bytesTotalForFile, forKey: Key.bytesTotalForFile)
        coder.encode(bytesReceivedOverall, forKey: Key.bytesReceivedOverall)
        coder.encode(bytesTotalOverall, forKey: Key.bytesTotalOverall)
    }

    public required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: Key.requestID) as String?,
              let fileName = coder.decodeObject(of: NSString.self, forKey: Key.fileName) as String?
        else { return nil }
        self.requestID = requestID
        self.fileName = fileName
        self.fileIndex = coder.decodeInteger(forKey: Key.fileIndex)
        self.fileCount = coder.decodeInteger(forKey: Key.fileCount)
        self.bytesReceivedForFile = coder.decodeInt64(forKey: Key.bytesReceivedForFile)
        self.bytesTotalForFile = coder.decodeInt64(forKey: Key.bytesTotalForFile)
        self.bytesReceivedOverall = coder.decodeInt64(forKey: Key.bytesReceivedOverall)
        self.bytesTotalOverall = coder.decodeInt64(forKey: Key.bytesTotalOverall)
        super.init()
    }

    private enum Key {
        static let requestID = "requestID"
        static let fileName = "fileName"
        static let fileIndex = "fileIndex"
        static let fileCount = "fileCount"
        static let bytesReceivedForFile = "bytesReceivedForFile"
        static let bytesTotalForFile = "bytesTotalForFile"
        static let bytesReceivedOverall = "bytesReceivedOverall"
        static let bytesTotalOverall = "bytesTotalOverall"
    }
}

/// One file, as it ended up on disk. `wasVerified` distinguishes "the catalog
/// pinned a digest and it matched" from "the catalog has no digest yet, so this
/// was only recorded" — never conflate those two.
@objc(GDDownloadedFile)
public final class GDDownloadedFile: NSObject, NSSecureCoding {

    public let name: String
    public let sha256: String
    public let size: Int64
    public let wasVerified: Bool
    public let wasPinnedButWrong: Bool

    public init(name: String, sha256: String, size: Int64, wasVerified: Bool, wasPinnedButWrong: Bool = false) {
        self.name = name
        self.sha256 = sha256
        self.size = size
        self.wasVerified = wasVerified
        self.wasPinnedButWrong = wasPinnedButWrong
        super.init()
    }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(name, forKey: Key.name)
        coder.encode(sha256, forKey: Key.sha256)
        coder.encode(size, forKey: Key.size)
        coder.encode(wasVerified, forKey: Key.wasVerified)
        coder.encode(wasPinnedButWrong, forKey: Key.wasPinnedButWrong)
    }

    public required init?(coder: NSCoder) {
        guard let name = coder.decodeObject(of: NSString.self, forKey: Key.name) as String?,
              let sha256 = coder.decodeObject(of: NSString.self, forKey: Key.sha256) as String?
        else { return nil }
        self.name = name
        self.sha256 = sha256
        self.size = coder.decodeInt64(forKey: Key.size)
        self.wasVerified = coder.decodeBool(forKey: Key.wasVerified)
        self.wasPinnedButWrong = coder.decodeBool(forKey: Key.wasPinnedButWrong)
        super.init()
    }

    private enum Key {
        static let name = "name"
        static let sha256 = "sha256"
        static let size = "size"
        static let wasVerified = "wasVerified"
        static let wasPinnedButWrong = "wasPinnedButWrong"
    }
}

/// The single reply. `workingDirectoryURL` is the handover; everything else is
/// diagnostics the app may show or log (no user text can be in here).
@objc(GDDownloadReply)
public final class GDDownloadReply: NSObject, NSSecureCoding {

    public let requestID: String
    public let succeeded: Bool
    public let cancelled: Bool
    /// Valid only when `succeeded`; identical to `GDDownloadRequest.workingDirectoryPath`.
    public let workingDirectoryPath: String?
    public let sourceHost: String
    public let files: [GDDownloadedFile]
    public let unpinnedFileNames: [String]
    public let sizeAnomalyFileNames: [String]
    public let resumedFileNames: [String]
    public let bytesOnDisk: Int64
    /// `DownloadError` / `TransportError` description, already human-readable.
    /// Never contains anything the user typed — the service never receives any.
    public let failureMessage: String?

    public init(requestID: String,
                succeeded: Bool,
                cancelled: Bool,
                workingDirectoryPath: String?,
                sourceHost: String,
                files: [GDDownloadedFile],
                unpinnedFileNames: [String] = [],
                sizeAnomalyFileNames: [String] = [],
                resumedFileNames: [String] = [],
                bytesOnDisk: Int64 = 0,
                failureMessage: String? = nil) {
        self.requestID = requestID
        self.succeeded = succeeded
        self.cancelled = cancelled
        self.workingDirectoryPath = workingDirectoryPath
        self.sourceHost = sourceHost
        self.files = files
        self.unpinnedFileNames = unpinnedFileNames
        self.sizeAnomalyFileNames = sizeAnomalyFileNames
        self.resumedFileNames = resumedFileNames
        self.bytesOnDisk = bytesOnDisk
        self.failureMessage = failureMessage
        super.init()
    }

    /// The URL to hand to `ModelStore.install(fromTemporaryDirectory:…)`.
    public var workingDirectoryURL: URL? {
        workingDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static var supportsSecureCoding: Bool { true }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID, forKey: Key.requestID)
        coder.encode(succeeded, forKey: Key.succeeded)
        coder.encode(cancelled, forKey: Key.cancelled)
        coder.encode(workingDirectoryPath, forKey: Key.workingDirectoryPath)
        coder.encode(sourceHost, forKey: Key.sourceHost)
        coder.encode(files as NSArray, forKey: Key.files)
        coder.encode(unpinnedFileNames as NSArray, forKey: Key.unpinnedFileNames)
        coder.encode(sizeAnomalyFileNames as NSArray, forKey: Key.sizeAnomalyFileNames)
        coder.encode(resumedFileNames as NSArray, forKey: Key.resumedFileNames)
        coder.encode(bytesOnDisk, forKey: Key.bytesOnDisk)
        coder.encode(failureMessage, forKey: Key.failureMessage)
    }

    public required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: Key.requestID) as String?,
              let sourceHost = coder.decodeObject(of: NSString.self, forKey: Key.sourceHost) as String?
        else { return nil }
        self.requestID = requestID
        self.succeeded = coder.decodeBool(forKey: Key.succeeded)
        self.cancelled = coder.decodeBool(forKey: Key.cancelled)
        self.workingDirectoryPath = coder.decodeObject(of: NSString.self, forKey: Key.workingDirectoryPath) as String?
        self.sourceHost = sourceHost
        self.files = (coder.decodeObject(of: [NSArray.self, GDDownloadedFile.self], forKey: Key.files) as? [GDDownloadedFile]) ?? []
        self.unpinnedFileNames = (coder.decodeObject(of: [NSArray.self, NSString.self], forKey: Key.unpinnedFileNames) as? [String]) ?? []
        self.sizeAnomalyFileNames = (coder.decodeObject(of: [NSArray.self, NSString.self], forKey: Key.sizeAnomalyFileNames) as? [String]) ?? []
        self.resumedFileNames = (coder.decodeObject(of: [NSArray.self, NSString.self], forKey: Key.resumedFileNames) as? [String]) ?? []
        self.bytesOnDisk = coder.decodeInt64(forKey: Key.bytesOnDisk)
        self.failureMessage = coder.decodeObject(of: NSString.self, forKey: Key.failureMessage) as String?
        super.init()
    }

    private enum Key {
        static let requestID = "requestID"
        static let succeeded = "succeeded"
        static let cancelled = "cancelled"
        static let workingDirectoryPath = "workingDirectoryPath"
        static let sourceHost = "sourceHost"
        static let files = "files"
        static let unpinnedFileNames = "unpinnedFileNames"
        static let sizeAnomalyFileNames = "sizeAnomalyFileNames"
        static let resumedFileNames = "resumedFileNames"
        static let bytesOnDisk = "bytesOnDisk"
        static let failureMessage = "failureMessage"
    }
}

// MARK: - The protocol

/// App-side callback for progress. One-way (`void` return) so progress ticks never
/// block the service. The app implements this on an object it hands in as the
/// `progress` argument of `download(_:progress:reply:)`.
@objc(GrammarDownloadProgressReporting)
public protocol GrammarDownloadProgressReporting {
    /// Delivered on the connection's queue; hop to the main actor before touching UI.
    func didUpdate(progress: GDDownloadProgress)
}

/// The service's exported interface.
///
/// `download` returns exactly one `GDDownloadReply`. Progress is pushed
/// out-of-band through the `GrammarDownloadProgressReporting` proxy; cancellation
/// is a separate message so it works from a different thread than the caller's.
@objc(GrammarDownloading)
public protocol GrammarDownloading {

    /// `progress` may be nil. `reply` is called exactly once, on success or failure.
    func download(_ request: GDDownloadRequest,
                  progress: GrammarDownloadProgressReporting?,
                  reply: @escaping (GDDownloadReply) -> Void)

    /// Cancels an in-flight request and cleans up its partial files.
    /// A no-op for an unknown or already-finished `requestID`.
    func cancel(requestID: String)

    /// Cheap liveness check used before the app builds a real request.
    func ping(reply: @escaping (Bool) -> Void)
}

// MARK: - Interface configuration

/// Both ends of the connection must whitelist the payload classes; getting this
/// wrong fails at runtime with a generic XPC error, so it lives in one place.
public enum GrammarDownloadingInterfaceFactory {

    public static let progressSelector = #selector(GrammarDownloadProgressReporting.didUpdate(progress:))
    public static let downloadSelector = #selector(GrammarDownloading.download(_:progress:reply:))

    /// Interface for the object the service exports (`GrammarDownloading`).
    public static func serviceInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: GrammarDownloading.self)
        interface.setClasses(GrammarDownloadingInterfaceFactory.requestClasses,
                             for: downloadSelector, argumentIndex: 0, ofReply: false)
        interface.setClasses(GrammarDownloadingInterfaceFactory.replyClasses,
                             for: downloadSelector, argumentIndex: 0, ofReply: true)
        interface.setInterface(progressInterface(), for: downloadSelector, argumentIndex: 1, ofReply: false)
        return interface
    }

    /// Interface for the object the app exports (`GrammarDownloadProgressReporting`).
    public static func progressInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: GrammarDownloadProgressReporting.self)
        interface.setClasses(GrammarDownloadingInterfaceFactory.progressClasses,
                             for: progressSelector, argumentIndex: 0, ofReply: false)
        return interface
    }

    public static var requestClasses: Set<AnyHashable> {
        classSet([GDDownloadRequest.self, GDDownloadFile.self, NSArray.self])
    }

    public static var replyClasses: Set<AnyHashable> {
        classSet([GDDownloadReply.self, GDDownloadedFile.self,
                  NSArray.self, NSString.self, NSNull.self])
    }

    public static var progressClasses: Set<AnyHashable> {
        classSet([GDDownloadProgress.self, NSString.self])
    }

    /// Class metatypes are not `Hashable` in Swift, so `AnyHashable(SomeClass.self)`
    /// does not compile. `NSXPCInterface.setClasses` wants a `Set<AnyHashable>`, and
    /// going through `NSSet` is the way through — verified at runtime (the cast does
    /// not trap and the set holds every class).
    static func classSet(_ classes: [AnyObject.Type]) -> Set<AnyHashable> {
        NSSet(array: classes) as! Set<AnyHashable>
    }

    /// Standard XPC service name; matches `GrammarDownloaderServiceName` in the
    /// app and the `XPCService` dictionary in the generated Info.plist.
    public static let serviceName = "com.grammarbar.GrammarDownloader"
}
