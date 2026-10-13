import XCTest
@testable import GrammarDownloaderCore

/// End-to-end orchestration through the transport seam: no network, but the full
/// engine path — pre-flight, resume, verification, the atomic rename and the report.
final class DownloadEngineTests: XCTestCase {

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [DownloadProgress] = []
        func record(_ progress: DownloadProgress) {
            lock.lock(); storage.append(progress); lock.unlock()
        }
        var ticks: [DownloadProgress] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private func engine(work: URL,
                        transport: ScriptedTransport,
                        capacity: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max },
                        maxRetriesPerFile: Int = 2,
                        cleanupPolicy: ModelDownloadEngine.CleanupPolicy = .removePartialsAndWorkingDirectory)
    -> ModelDownloadEngine {
        ModelDownloadEngine(configuration: .testing(workingDirectory: work,
                                                    transport: transport,
                                                    capacity: capacity,
                                                    maxRetriesPerFile: maxRetriesPerFile,
                                                    cleanupPolicy: cleanupPolicy))
    }

    // MARK: Happy path

    func testHappyPathVerifiesFinalisesAndHandsBackTheWorkingDirectory() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")

        let safetensors = Payload.bytes(2_048)
        let tokenizer = Payload.text("{\"tokenizer\": true}")
        let config = Payload.text("{\"model_type\": \"qwen3\"}")
        let transport = ScriptedTransport(payload: ["model.safetensors": safetensors,
                                                    "tokenizer.json": tokenizer,
                                                    "config.json": config])
        let plan = try TestCatalog.plan(files: [("model.safetensors", safetensors),
                                                ("tokenizer.json", tokenizer),
                                                ("config.json", config)])

        let report = try await engine(work: work, transport: transport).download(plan)

        XCTAssertEqual(report.modelID, "qwen3-0.6b-4bit")
        XCTAssertEqual(report.revision, "73e3e38d9813")
        XCTAssertEqual(report.sourceHost, "huggingface.co")
        XCTAssertEqual(report.files.count, 3)
        XCTAssertEqual(report.verifiedFileCount, 3)
        XCTAssertTrue(report.isFullyPinned)
        XCTAssertTrue(report.unpinnedFileNames.isEmpty)
        XCTAssertEqual(report.totalBytesOnDisk, Int64(safetensors.count + tokenizer.count + config.count))
        XCTAssertEqual(report.workingDirectory, work)

        // The handoff directory ModelStore.install() expects: final names only.
        XCTAssertEqual(directory.contents(), ["work"])
        XCTAssertEqual(workContents(work), ["config.json", "model.safetensors", "tokenizer.json"])
        XCTAssertEqual(try FileHashing.sha256(ofFileAt: work.appendingPathComponent("model.safetensors")),
                       FileHashing.sha256(of: safetensors))
        XCTAssertTrue(report.sizeAnomalyFileNames.isEmpty)
    }

    func testPinnedDigestsAreEchoedBackInTheReport() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(64)
        let transport = ScriptedTransport(payload: ["config.json": data])
        let plan = try TestCatalog.plan(files: [("config.json", data)])

        let report = try await engine(work: work, transport: transport).download(plan)
        XCTAssertEqual(report.files.first?.sha256, FileHashing.sha256(of: data))
        XCTAssertEqual(report.files.first?.verification, .verified(digest: FileHashing.sha256(of: data)))
    }

    // MARK: The catalog's real current state

    func testCatalogShapedPlanWithNoPinsSucceedsButClaimsNoVerification() async throws {
        // Mirrors `ModelCatalog.qwen3_0_6b_4bit`, whose `sha256` fields are all ""
        // because the digests have not been computed from real bytes yet.
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")

        let bodies: [(String, Data)] = [("model.safetensors", Payload.bytes(512)),
                                        ("tokenizer.json", Payload.text("{\"t\":1}")),
                                        ("vocab.json", Payload.text("{\"v\":1}")),
                                        ("config.json", Payload.text("{}"))]
        let plan = try DownloadPlan(modelID: "qwen3-0.6b-4bit",
                                    revision: "73e3e38d9813",
                                    files: bodies.map { TestCatalog.item(name: $0.0, data: $0.1, pin: .unpinned) })
        let transport = ScriptedTransport(payload: Dictionary(uniqueKeysWithValues: bodies))

        let report = try await engine(work: work, transport: transport).download(plan)

        XCTAssertEqual(report.files.count, 4)
        XCTAssertEqual(report.verifiedFileCount, 0, "nothing may be reported as verified while the catalog is unpinned")
        XCTAssertEqual(report.unpinnedFileNames, ["config.json", "model.safetensors", "tokenizer.json", "vocab.json"])
        XCTAssertFalse(report.isFullyPinned)
        // Digests are recorded so the app can pin them later, rather than lost.
        for file in report.files {
            XCTAssertTrue(FileDigestFormat.isValid(file.sha256), "\(file.name) should carry a recorded digest")
            XCTAssertEqual(file.verification, .recordedUnpinned(digest: file.sha256))
        }
        XCTAssertEqual(workContents(work), ["config.json", "model.safetensors", "tokenizer.json", "vocab.json"])
    }

    // MARK: Resume

    func testSecondRunVerifiesFromDiskWithoutTouchingTheNetwork() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(300)
        try data.write(to: work.appendingPathComponent("model.safetensors.partial"))

        let transport = ScriptedTransport(payload: ["model.safetensors": data])
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        let report = try await engine(work: work, transport: transport).download(plan)

        XCTAssertEqual(transport.callCount, 0, "a complete file must not be re-fetched")
        XCTAssertEqual(report.resumedFileNames, ["model.safetensors"])
        XCTAssertEqual(report.verifiedFileCount, 1)
        XCTAssertEqual(workContents(work), ["model.safetensors"])
    }

    func testInterruptedTransferResumesWithARangeRequest() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(500)
        let transport = ScriptedTransport(payload: ["model.safetensors": data],
                                          failuresRemaining: 1,
                                          partialWriteOnFailure: 200)
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        let report = try await engine(work: work, transport: transport).download(plan)

        XCTAssertEqual(transport.calls.count, 2, "one interruption then one resumed attempt")
        XCTAssertEqual(transport.calls.first?.resumeFromByte, 0)
        XCTAssertEqual(transport.calls.last?.resumeFromByte, 200)
        XCTAssertEqual(report.resumedFileNames, ["model.safetensors"])
        XCTAssertEqual(try FileHashing.sha256(ofFileAt: work.appendingPathComponent("model.safetensors")),
                       FileHashing.sha256(of: data))
    }

    func testInterruptionWithNoProgressStillRetries() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(64)
        let transport = ScriptedTransport(payload: ["config.json": data],
                                          failuresRemaining: 1,
                                          partialWriteOnFailure: 0)
        let plan = try TestCatalog.plan(files: [("config.json", data)])

        let report = try await engine(work: work, transport: transport).download(plan)
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(transport.calls.last?.resumeFromByte, 0, "there was nothing to resume from")
        XCTAssertEqual(report.verifiedFileCount, 1)
    }

    func testRetriesAreBounded() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(64)
        let transport = ScriptedTransport(payload: ["config.json": data],
                                          failuresRemaining: 99,
                                          partialWriteOnFailure: 10)
        let plan = try TestCatalog.plan(files: [("config.json", data)])

        await XCTAssertThrowsDownloadError(
            try await engine(work: work, transport: transport, maxRetriesPerFile: 2).download(plan)
        ) { error in
            error == .transport(.interrupted)
        }
        XCTAssertEqual(transport.callCount, 3, "one attempt plus two retries")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testNonRetryableTransportErrorIsNotRetried() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(64)
        let transport = ScriptedTransport(payload: ["config.json": data],
                                          failuresRemaining: 99,
                                          interruptionError: .httpStatus(403))
        let plan = try TestCatalog.plan(files: [("config.json", data)])

        await XCTAssertThrowsDownloadError(try await engine(work: work, transport: transport).download(plan)) { error in
            error == .transport(.httpStatus(403))
        }
        XCTAssertEqual(transport.callCount, 1)
    }

    func testServerIgnoringTheRangeHeaderRestartsCleanly() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(400)
        // A stale 120-byte partial from an earlier run.
        try data.prefix(120).write(to: work.appendingPathComponent("model.safetensors.partial"))

        let transport = ScriptedTransport(payload: ["model.safetensors": data], ignoreResume: true)
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        let report = try await engine(work: work, transport: transport).download(plan)

        XCTAssertEqual(transport.calls.first?.resumeFromByte, 120, "the offset was still requested")
        XCTAssertEqual(report.files.first?.size, 400, "the file must not be double-written")
        XCTAssertEqual(try FileHashing.sha256(ofFileAt: work.appendingPathComponent("model.safetensors")),
                       FileHashing.sha256(of: data))
    }

    // MARK: Integrity failures

    func testTruncatedDownloadFails() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(100)
        let item = TestCatalog.item(name: "model.safetensors", data: data, declaredSize: 100)
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [item])
        let transport = ScriptedTransport(payload: ["model.safetensors": Data(data.prefix(40))])

        await XCTAssertThrowsDownloadError(try await engine(work: work, transport: transport).download(plan)) { error in
            error == .truncatedFile(fileName: "model.safetensors", expected: 100, received: 40)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testOversizedFileIsFlaggedNotFatal() async throws {
        // The catalog sizes are measured approximations; a bigger file is worth
        // surfacing but is not proof of corruption on its own.
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(200)
        let item = TestCatalog.item(name: "model.safetensors", data: data, declaredSize: 150)
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [item])
        let transport = ScriptedTransport(payload: ["model.safetensors": data])

        let report = try await engine(work: work, transport: transport).download(plan)
        XCTAssertEqual(report.sizeAnomalyFileNames, ["model.safetensors"])
        XCTAssertEqual(report.files.first?.size, 200)
        XCTAssertEqual(report.verifiedFileCount, 1)
    }

    func testPinnedDigestMismatchFails() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(64)
        let wrong = String(repeating: "f", count: 64)
        let item = TestCatalog.item(name: "model.safetensors", data: data, pin: .custom(wrong))
        let plan = try DownloadPlan(modelID: "m", revision: "r", files: [item])
        let transport = ScriptedTransport(payload: ["model.safetensors": data])

        await XCTAssertThrowsDownloadError(try await engine(work: work, transport: transport).download(plan)) { error in
            error == .hashMismatch(fileName: "model.safetensors", expected: wrong,
                                   actual: FileHashing.sha256(of: data))
        }
    }

    // MARK: Disk space

    func testInsufficientDiskSpaceAbortsBeforeAnyRequest() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(1_000)
        let transport = ScriptedTransport(payload: ["model.safetensors": data])
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        // 1000 bytes of payload needs 2000 free; the volume has 1.
        let eng = engine(work: work, transport: transport, capacity: { _ in 1 })
        await XCTAssertThrowsDownloadError(try await eng.download(plan)) { error in
            error == .insufficientDiskSpace(required: 2_000, available: 1)
        }
        XCTAssertEqual(transport.callCount, 0, "the disk check must run before the network")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testExactlyTwiceTheSizeIsEnough() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(1_000)
        let transport = ScriptedTransport(payload: ["model.safetensors": data])
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        let report = try await engine(work: work, transport: transport, capacity: { _ in 2_000 }).download(plan)
        XCTAssertEqual(report.diskCheck, .sufficient(requiredBytes: 2_000, availableBytes: 2_000))
    }

    func testUnknownCapacityProceedsAndIsReported() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(64)
        let transport = ScriptedTransport(payload: ["config.json": data])
        let plan = try TestCatalog.plan(files: [("config.json", data)])

        let report = try await engine(work: work, transport: transport, capacity: { _ in nil }).download(plan)
        XCTAssertEqual(report.diskCheck, .capacityUnknown(requiredBytes: 128))
        XCTAssertEqual(report.verifiedFileCount, 1)
    }

    // MARK: Progress

    func testProgressIsMonotonicAndEndsAtTheTotal() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let first = Payload.bytes(300)
        let second = Payload.bytes(120)
        let transport = ScriptedTransport(payload: ["model.safetensors": first,
                                                    "tokenizer.json": second],
                                          failuresRemaining: 1,
                                          partialWriteOnFailure: 100)
        let plan = try TestCatalog.plan(files: [("model.safetensors", first),
                                                ("tokenizer.json", second)])

        let recorder = ProgressRecorder()
        _ = try await engine(work: work, transport: transport).download(plan) { recorder.record($0) }

        let ticks = recorder.ticks
        XCTAssertFalse(ticks.isEmpty, "a download must report progress")

        var previous: Int64 = 0
        for tick in ticks {
            XCTAssertGreaterThanOrEqual(tick.bytesReceivedOverall, previous, "progress must not go backwards")
            previous = tick.bytesReceivedOverall
            XCTAssertLessThanOrEqual(tick.bytesReceivedOverall, tick.bytesTotalOverall)
            XCTAssertLessThanOrEqual(tick.bytesReceivedForFile, tick.bytesTotalForFile)
            XCTAssertEqual(tick.fileCount, 2)
            XCTAssertEqual(tick.modelID, "qwen3-0.6b-4bit")
        }
        XCTAssertEqual(ticks.last?.bytesReceivedOverall, plan.totalBytes)
        XCTAssertEqual(ticks.last?.bytesReceivedForFile, ticks.last?.bytesTotalForFile)
        XCTAssertEqual(ticks.last?.fileIndex, 1)
        XCTAssertEqual(ticks.last?.overallFraction, 1.0)
    }

    func testProgressFractionIsBounded() {
        let progress = DownloadProgress(modelID: "m", fileIndex: 0, fileCount: 1, fileName: "a",
                                        bytesReceivedForFile: 5, bytesTotalForFile: 10,
                                        bytesReceivedOverall: 5, bytesTotalOverall: 10)
        XCTAssertEqual(progress.fileFraction, 0.5)
        XCTAssertEqual(progress.overallFraction, 0.5)

        let unknown = DownloadProgress(modelID: "m", fileIndex: 0, fileCount: 1, fileName: "a",
                                       bytesReceivedForFile: 5, bytesTotalForFile: 0,
                                       bytesReceivedOverall: 5, bytesTotalOverall: 0)
        XCTAssertEqual(unknown.fileFraction, 1)
        XCTAssertEqual(unknown.overallFraction, 0)
    }

    // MARK: Containment

    func testNothingIsWrittenOutsideTheWorkingDirectory() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let work = directory.makeChild("work")
        let data = Payload.bytes(128)
        let transport = ScriptedTransport(payload: ["model.safetensors": data])
        let plan = try TestCatalog.plan(files: [("model.safetensors", data)])

        _ = try await engine(work: work, transport: transport).download(plan)

        XCTAssertEqual(directory.contents(), ["work"], "the parent directory must be untouched")
        XCTAssertEqual(workContents(work), ["model.safetensors"])
    }

    func testWorkingDirectoryIsCreatedWhenMissing() async throws {
        let directory = TempDirectory()
        defer { directory.remove() }
        let nested = directory.url.appendingPathComponent("a/b/downloads")
        let data = Payload.bytes(32)
        let transport = ScriptedTransport(payload: ["config.json": data])
        let plan = try TestCatalog.plan(files: [("config.json", data)])

        let report = try await engine(work: nested, transport: transport).download(plan)
        XCTAssertEqual(report.workingDirectory, nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("config.json").path))
    }

    // MARK: Helpers

    private func workContents(_ work: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).sorted()
    }
}
