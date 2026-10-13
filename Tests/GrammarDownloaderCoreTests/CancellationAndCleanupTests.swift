import XCTest
@testable import GrammarDownloaderCore

/// Cancellation and failure must leave nothing behind, and cleanup must never be
/// able to reach outside the download's own directory.
final class CancellationAndCleanupTests: XCTestCase {

    // MARK: CleanupSafety (pure)

    func testProtectedPathsAreNotRemovable() {
        for path in ["/", "/Users", "/System", "/Library", "/Applications", "/private", "/tmp", "/var", "/Volumes"] {
            XCTAssertFalse(CleanupSafety.isRemovable(URL(fileURLWithPath: path)), "\(path) must never be removable")
        }
    }

    func testHomeDirectoryItselfIsNotRemovable() {
        XCTAssertFalse(CleanupSafety.isRemovable(URL(fileURLWithPath: NSHomeDirectory())))
    }

    func testShallowPathsAreNotRemovable() {
        XCTAssertFalse(CleanupSafety.isRemovable(URL(fileURLWithPath: "/Users/someone")))
    }

    func testTemporaryDirectoryIsRemovable() {
        let directory = TempDirectory()
        defer { directory.remove() }
        XCTAssertTrue(CleanupSafety.isRemovable(directory.url))
        XCTAssertTrue(CleanupSafety.isRemovable(directory.url.appendingPathComponent("work")))
    }

    func testRemoveWorkingDirectoryRefusesAProtectedPath() {
        XCTAssertThrowsError(try CleanupSafety.removeWorkingDirectory(URL(fileURLWithPath: "/System"))) { error in
            XCTAssertEqual(error as? DownloadError, .workingDirectoryNotRemovable("/System"))
        }
    }

    func testRemoveWorkingDirectoryIsIdempotent() throws {
        let directory = TempDirectory()
        let work = directory.makeChild("work")
        XCTAssertTrue(try CleanupSafety.removeWorkingDirectory(work))
        XCTAssertFalse(try CleanupSafety.removeWorkingDirectory(work), "second removal is a no-op")
        directory.remove()
    }

    // MARK: Engine refuses to work in a system path

    func testEngineRefusesAProtectedWorkingDirectory() async throws {
        let transport = ScriptedTransport(payload: ["model.safetensors": Payload.bytes(10)])
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: URL(fileURLWithPath: "/System"),
                                                                transport: transport))
        let plan = try TestCatalog.plan(files: [("model.safetensors", Payload.bytes(10))])
        await XCTAssertThrowsDownloadError(try await engine.download(plan)) { error in
            error == .workingDirectoryNotRemovable("/System")
        }
        XCTAssertEqual(transport.callCount, 0, "nothing may be fetched for a refused directory")
    }

    // MARK: Cancellation

    func testCancellationThrowsCancelledAndLeavesNothingBehind() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(500)
        let transport = ScriptedTransport(payload: ["model.safetensors": data], hang: true)
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: work, transport: transport))
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        let task = Task { try await engine.download(plan) }
        try await Task.sleep(nanoseconds: 50_000_000)  // let the transfer start
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected the download to fail with a cancellation")
        } catch let error as DownloadError {
            XCTAssertTrue(error.isCancellation, "expected a cancellation, got \(error)")
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(transport.callCount, 1, "the transfer should have been attempted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path),
                       "a cancelled download must remove its working directory")
        XCTAssertTrue(directory.contents().isEmpty, "nothing may be left beside the working directory")
    }

    func testCancellationDiscardsAlreadyVerifiedFilesFromTheSamePlan() async throws {
        // All-or-nothing: the handoff directory is never left half-complete for
        // ModelStore to trip over.
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")

        let first = Payload.bytes(100)
        let second = Payload.bytes(200)
        // First file already fully on disk -> verified without touching the network.
        try first.write(to: work.appendingPathComponent("model.safetensors.partial"))

        let transport = ScriptedTransport(payload: ["model.safetensors": first,
                                                    "tokenizer.json": second],
                                          hang: true)
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: work, transport: transport))
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [
            TestCatalog.item(name: "model.safetensors", data: first),
            TestCatalog.item(name: "tokenizer.json", data: second),
        ])

        let task = Task { try await engine.download(plan) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path),
                       "the verified first file must go too — the directory is all-or-nothing")
    }

    // MARK: Failure

    func testFailureRemovesPartialsAndTheWorkingDirectory() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let good = Payload.bytes(200)
        let transport = ScriptedTransport(payload: ["model.safetensors": good,
                                                    "config.json": Payload.bytes(50)],
                                          failuresRemaining: 1,
                                          interruptionError: .httpStatus(500),
                                          partialWriteOnFailure: 120)
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: work, transport: transport))
        let plan = try TestCatalog.plan(files: [("model.safetensors", good),
                                                ("config.json", Payload.bytes(50))])

        await XCTAssertThrowsDownloadError(try await engine.download(plan)) { error in
            error == .transport(.httpStatus(500))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path),
                       "a failed download must remove its working directory")
        XCTAssertTrue(directory.contents().isEmpty, "no stray files may be left in the parent directory")
    }

    func testFailureRemovesAVerifiedFirstFileToo() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")

        let first = Payload.bytes(100)
        let second = Payload.bytes(100)
        try first.write(to: work.appendingPathComponent("model.safetensors.partial"))

        let transport = ScriptedTransport(payload: ["model.safetensors": first,
                                                    "tokenizer.json": second],
                                          failuresRemaining: 99,
                                          interruptionError: .httpStatus(404))
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: work, transport: transport))
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [
            TestCatalog.item(name: "model.safetensors", data: first),
            TestCatalog.item(name: "tokenizer.json", data: second),
        ])

        await XCTAssertThrowsDownloadError(try await engine.download(plan)) { error in
            error == .transport(.httpStatus(404))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path),
                       "the verified first file must be discarded with the rest")
    }

    func testHashMismatchAlsoCleansUp() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(100)
        let item = TestCatalog.item(name: "model.safetensors", data: data,
                                    pin: .custom(String(repeating: "0", count: 64)))
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [item])
        let transport = ScriptedTransport(payload: ["model.safetensors": data])
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: work, transport: transport))

        await XCTAssertThrowsDownloadError(try await engine.download(plan)) { error in
            if case .hashMismatch = error { return true }
            return false
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    // MARK: Opt-in resume policy

    func testKeepPartialsPolicyLeavesThePartialForTheNextRun() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(500)

        let failing = ScriptedTransport(payload: ["model.safetensors": data],
                                        failuresRemaining: 1,
                                        partialWriteOnFailure: 200)
        let firstEngine = ModelDownloadEngine(configuration: .testing(workingDirectory: work,
                                                                     transport: failing,
                                                                     maxRetriesPerFile: 0,
                                                                     cleanupPolicy: .keepPartialsForResume))
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        await XCTAssertThrowsDownloadError(try await firstEngine.download(plan)) { error in
            error == .transport(.interrupted)
        }

        let partial = work.appendingPathComponent("model.safetensors.partial")
        XCTAssertEqual(PartialFiles.byteCount(at: partial), 200, "the partial must survive for resume")

        // A second run continues from byte 200 rather than starting over.
        let second = ScriptedTransport(payload: ["model.safetensors": data])
        let secondEngine = ModelDownloadEngine(configuration: .testing(workingDirectory: work, transport: second))
        let report = try await secondEngine.download(plan)

        XCTAssertEqual(second.calls.count, 1)
        XCTAssertEqual(second.calls.first?.resumeFromByte, 200)
        XCTAssertEqual(report.resumedFileNames, ["model.safetensors"])
        XCTAssertEqual(try FileHashing.sha256(ofFileAt: work.appendingPathComponent("model.safetensors")),
                       FileHashing.sha256(of: data))
    }

    func testCleanupMethodIsCallableDirectlyAndIdempotent() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(10)
        try Payload.bytes(5).write(to: work.appendingPathComponent("model.safetensors.partial"))
        let engine = ModelDownloadEngine(configuration: .testing(workingDirectory: work,
                                                                 transport: ScriptedTransport(payload: [:])))
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])
        await engine.cleanup(plan: plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        await engine.cleanup(plan: plan)  // second call must not throw or recreate anything
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }
}
