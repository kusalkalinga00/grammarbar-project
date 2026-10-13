import Foundation
import GrammarBarCore
import FoundationModels

// GrammarBar eval harness — plan v2 §8.
//
//   swift run GrammarBarEval --engine apple --set Eval/golden.jsonl --out Eval/results/
//
// For every case in the golden set it runs the correction **through
// CorrectionService** (i.e. the real pipeline: chunk -> generate -> sanitize ->
// validate -> TenseGuard -> no-op guard, with its retry ladders), and, unless
// `--mode pipeline`, additionally records a single-shot **raw engine** pass
// using the same call the recon probe used. The raw pass is what the numbers in
// PLAN-v2.md §0.3 (10/12 fixed, 6/6 unchanged, 362 ms mean TTFT) were measured
// with; the pipeline pass is what the app actually does.
//
// Nothing here is synthesised: every recorded field comes from a live engine
// call in this process.

// --------------------------------------------------------------- model types

struct EvalCase: Codable {
    let id: String
    let kind: String          // "wrong" | "correct" | "special"
    let input: String
    let expected: String?     // nil for kind == "special"
    let source: String
}

struct PassRecord: Codable {
    let output: String
    let rawModelOutput: String
    let outcome: String
    let fixed: Bool?
    let byteIdenticalToInput: Bool
    let editDistance: Double
    let editDistanceToExpected: Double?
    let tenseChanges: Int
    let temporalCues: Int
    let tenseChangedVerbs: [String]
    let tenseFlagged: Bool
    let delimiterEchoed: Bool
    let delimiterUsed: String
    let validatorAccepted: Bool
    let validationReasons: [String]
    let attempts: Int
    let latencyMs: Double
    let ttftMs: Double
    let error: String?
    /// The engine refused on guardrails rather than failing to generate.
    let guardrailRefusal: Bool
}

struct CaseRecord: Codable {
    let id: String
    let kind: String
    let source: String
    let input: String
    let expected: String?
    let expectedEditDistanceFromInput: Double?

    // pipeline — the app's real behaviour
    let output: String
    let outcome: String
    let fixed: Bool?
    let byteIdenticalToInput: Bool
    let editDistance: Double
    let editDistanceToExpected: Double?
    let tenseChanges: Int
    let temporalCues: Int
    let tenseChangedVerbs: [String]
    let tenseFlagged: Bool
    let delimiterEchoed: Bool
    let delimiterUsed: String
    let validatorAccepted: Bool
    let validationReasons: [String]
    let attempts: Int
    let latencyMs: Double
    let ttftMs: Double
    let originalSubstituted: Bool
    /// The pipeline stepped away from `.angleTags` because the model echoed it.
    let delimiterEscalated: Bool
    let warnings: [String]
    let error: String?
    let guardrailRefusal: Bool

    // raw single-shot engine pass (baseline comparability)
    var rawPass: PassRecord?

    // diagnostics
    let meaningChanged: Bool
    let lostProtectedTokens: [String]
}

struct PassSummary: Codable {
    let casesRun: Int
    let errorsFixed: Int
    let wrongTotal: Int
    let correctUnchanged: Int
    let correctTotal: Int
    let correctUnchangedRate: Double?
    let meanTtftMs: Double
    let p50TtftMs: Double
    let p95TtftMs: Double
    let meanLatencyMs: Double
    let p50LatencyMs: Double
    let p95LatencyMs: Double
    let tenseFlagCount: Int
    let tenseChangeTotal: Int
    let temporalCueTotal: Int
    let delimiterEchoCount: Int
    let validatorRejectedCount: Int
    let claimedUnchangedCount: Int
    let failedCount: Int
    let guardrailRefusalCount: Int
    let retryLadderUsedCount: Int
    let outcomeCounts: [String: Int]
}

struct Env: Codable {
    let macOSVersion: String
    let macOSBuild: String
    let architecture: String
    let hostModel: String
    let chip: String
    let swiftVersion: String
    let engine: String
    let engineStatus: String
    let modelAvailability: String
    let contextSize: Int
    let promptRevision: String
    let defaultDelimiter: String
    let chunkerContextSize: Int
    let correctionServiceMaxAttempts: Int
    let validatorMaxEditDistance: Double
    let mode: String
    let notes: [String]
}

struct Report: Codable {
    let schema: String
    let generatedAt: String
    let label: String
    let set: [String]
    let caseCount: Int
    let environment: Env
    let sourceProvenance: [String: Int]
    let summary: [String: PassSummary]
    /// TTFT of the very first engine call in this process, before prewarm().
    /// PLAN-v2.md §0.3 recorded 971 ms here; §4.7.2's prewarm() exists for it.
    let coldFirstRawCallTtftMs: Double?
    let meaningChangedCases: [String]
    let overEditedCorrectCases: [String]
    let records: [CaseRecord]
}

// ------------------------------------------------------------------- helpers

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(since t0: UInt64) -> Double { Double(nowNs() &- t0) / 1_000_000.0 }

func pct(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = max(1, Int((p / 100.0 * Double(sorted.count)).rounded(.up)))
    return sorted[min(rank, sorted.count) - 1]
}

func outcomeName(_ o: CorrectionOutcome) -> String {
    switch o {
    case .corrected: return "corrected"
    case .unchanged: return "unchanged"
    case .flagged: return "flagged"
    case .failed: return "failed"
    }
}

func outcomeMessage(_ o: CorrectionOutcome) -> String? {
    switch o {
    case .flagged(let m), .failed(let m): return m
    default: return nil
    }
}

let numberRegex = try! NSRegularExpression(pattern: "\\b\\d[\\d.,:/-]*\\b")
let urlRegex    = try! NSRegularExpression(pattern: "https?://\\S+")
let emailRegex  = try! NSRegularExpression(pattern: "[\\w.+-]+@[\\w-]+\\.[\\w.]+")

func protectedTokens(_ text: String) -> [String] {
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    var out: [String] = []
    for re in [urlRegex, emailRegex, numberRegex] {
        for m in re.matches(in: text, range: range) { out.append(ns.substring(with: m.range)) }
    }
    return out
}

func lostTokens(input: String, output: String) -> [String] {
    var seen = Set<String>()
    var lost: [String] = []
    for t in protectedTokens(input) where !output.contains(t) {
        if seen.insert(t).inserted { lost.append(t) }
    }
    return lost
}

/// The recon rule (recon/AppleEngineProbe.swift): a wrong case counts as fixed
/// when the output is closer to the reference than the input was.
func isFixed(input: String, output: String, expected: String) -> Bool {
    EditDistance.normalized(output, expected) < EditDistance.normalized(input, expected)
}

/// Recon Bug C, found by this harness: Apple's engine refuses outright on some
/// perfectly ordinary text, with `GenerationError`/guardrail wording rather
/// than a generation failure. Recorded so the rate is visible over time.
func isGuardrailRefusal(_ e: Error) -> Bool {
    let d = "\(e)".lowercased()
    return d.contains("sensitive or unsafe") || d.contains("unsafe content")
        || d.contains("guardrail") || d.contains("refus")
}

func describeError(_ e: Error) -> String { "\(type(of: e)): \(e)" }

func shell(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// ------------------------------------------------------------------- options

struct Options {
    var engine = "apple"
    var sets: [String] = ["Eval/golden.jsonl"]
    var out = "Eval/results"
    var label = "baseline"
    var mode = "both"            // both | pipeline | raw
    var limit: Int? = nil
    var sourceFilters: [String] = []
    var quiet = false
}

func usage() -> String {
    """
    GrammarBarEval — correction regression harness (plan v2 §8)

    USAGE:
      swift run GrammarBarEval [options]

    OPTIONS:
      --engine <apple|local>     engine under test            (default: apple)
      --set <path>               golden set, JSONL; repeatable (default: Eval/golden.jsonl)
      --out <dir>                results directory             (default: Eval/results)
      --label <name>             run label used in the filename (default: baseline)
      --mode <both|pipeline|raw> both = pipeline + raw pass     (default: both)
      --limit <n>                run only the first n cases
      --filter-source <prefix>   only cases whose `source` starts with prefix; repeatable
      --quiet                    suppress per-case progress on stderr
      --help                     this message
    """
}

func parseArgs(_ argv: [String]) -> Options? {
    var o = Options()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        func value() -> String? { i + 1 < argv.count ? argv[i + 1] : nil }
        switch a {
        case "--help", "-h": print(usage()); return nil
        case "--engine": if let v = value() { o.engine = v; i += 1 }
        case "--set": if let v = value() { if o.sets == ["Eval/golden.jsonl"] { o.sets = [] }; o.sets.append(v); i += 1 }
        case "--out": if let v = value() { o.out = v; i += 1 }
        case "--label": if let v = value() { o.label = v; i += 1 }
        case "--mode": if let v = value() { o.mode = v; i += 1 }
        case "--limit": if let v = value(), let n = Int(v) { o.limit = n; i += 1 }
        case "--filter-source": if let v = value() { o.sourceFilters.append(v); i += 1 }
        case "--quiet": o.quiet = true
        default:
            FileHandle.standardError.write("unknown option: \(a)\n\(usage())\n".data(using: .utf8)!)
            return nil
        }
        i += 1
    }
    return o
}

// ---------------------------------------------------------------------- runs

func runRawPass(_ c: EvalCase, engine: any GrammarEngine) async -> PassRecord {
    let t0 = nowNs()
    var firstAt: Double? = nil
    var raw = ""
    var err: String? = nil
    var refusal = false
    do {
        for try await snapshot in engine.correct(c.input, mode: .normal, delimiter: .angleTags) {
            if firstAt == nil { firstAt = ms(since: t0) }
            raw = snapshot
        }
    } catch {
        err = describeError(error)
        refusal = isGuardrailRefusal(error)
    }
    let latency = ms(since: t0)

    let sanitized = OutputSanitizer.sanitize(raw, delimiter: .angleTags)
    let validator = Validator(kind: engine.kind)
    let validation = validator.validate(input: c.input, sanitized: sanitized, kind: engine.kind)
    let out = sanitized.text
    let tense = TenseGuard.check(input: c.input, output: out)
    let identical = out == c.input

    var outcome = identical ? "unchanged" : "corrected"
    if err != nil { outcome = "failed" }

    return PassRecord(
        output: out,
        rawModelOutput: raw,
        outcome: outcome,
        fixed: (c.kind == "wrong" && c.expected != nil)
            ? isFixed(input: c.input, output: out, expected: c.expected!) : nil,
        byteIdenticalToInput: identical,
        editDistance: EditDistance.normalized(c.input, out),
        editDistanceToExpected: c.expected.map { EditDistance.normalized(out, $0) },
        tenseChanges: tense.tenseChanges,
        temporalCues: tense.temporalCues,
        tenseChangedVerbs: tense.changedVerbs,
        tenseFlagged: tense.isFlagged,
        delimiterEchoed: sanitized.delimiterEchoed,
        delimiterUsed: TextDelimiter.angleTags.rawValue,
        validatorAccepted: validation.accepted,
        validationReasons: validation.reasons,
        attempts: 1,
        latencyMs: latency,
        ttftMs: firstAt ?? latency,
        error: err,
        guardrailRefusal: refusal)
}

func runPipelinePass(_ c: EvalCase,
                     engine: any GrammarEngine,
                     service: CorrectionService) async -> CaseRecord {
    let t0 = nowNs()
    var firstAt: Double? = nil
    var final: CorrectionResult? = nil
    var err: String? = nil
    var refusal = false

    do {
        for try await event in service.run(text: c.input, engine: engine) {
            switch event {
            case .partial:
                if firstAt == nil { firstAt = ms(since: t0) }
            case .finished(let result):
                final = result
            }
        }
    } catch {
        err = describeError(error)
        refusal = isGuardrailRefusal(error)
    }
    let latency = ms(since: t0)

    let out = final?.text ?? c.input
    let outcome = final.map { outcomeName($0.outcome) } ?? "failed"
    let validation = final?.validation
    let tense = TenseGuard.check(input: c.input, output: out)
    let identical = out == c.input
    let lost = lostTokens(input: c.input, output: out)
    let changed = !identical && (tense.isFlagged || !lost.isEmpty)

    return CaseRecord(
        id: c.id,
        kind: c.kind,
        source: c.source,
        input: c.input,
        expected: c.expected,
        expectedEditDistanceFromInput: c.expected.map { EditDistance.normalized(c.input, $0) },
        output: out,
        outcome: outcome,
        fixed: (c.kind == "wrong" && c.expected != nil)
            ? isFixed(input: c.input, output: out, expected: c.expected!) : nil,
        byteIdenticalToInput: identical,
        editDistance: EditDistance.normalized(c.input, out),
        editDistanceToExpected: c.expected.map { EditDistance.normalized(out, $0) },
        tenseChanges: tense.tenseChanges,
        temporalCues: tense.temporalCues,
        tenseChangedVerbs: tense.changedVerbs,
        tenseFlagged: tense.isFlagged,
        delimiterEchoed: validation?.delimiterEchoed ?? false,
        delimiterUsed: final?.delimiter.rawValue ?? "angleTags",
        validatorAccepted: validation?.accepted ?? false,
        validationReasons: validation?.reasons ?? [outcomeMessage(final?.outcome ?? .unchanged) ?? "run failed"],
        attempts: final?.attempts ?? 0,
        latencyMs: latency,
        ttftMs: firstAt ?? latency,
        originalSubstituted: outcome == "flagged",
        delimiterEscalated: (final?.delimiter ?? .angleTags) != .angleTags,
        warnings: final?.warnings ?? [],
        error: err,
        guardrailRefusal: refusal,
        rawPass: nil,
        meaningChanged: changed,
        lostProtectedTokens: lost)
}

func summarise(_ records: [CaseRecord], pass: String) -> PassSummary {
    var fixed = 0, wrongTotal = 0, unchanged = 0, correctTotal = 0
    var ttfts: [Double] = [], lats: [Double] = []
    var tenseFlags = 0, tenseTotal = 0, cueTotal = 0, echoes = 0, rejected = 0
    var claimedUnchanged = 0, failed = 0, guardrails = 0, retries = 0
    var outcomes: [String: Int] = [:]

    for r in records {
        let isPipeline = pass == "pipeline"
        let ttf = isPipeline ? r.ttftMs : (r.rawPass?.ttftMs ?? 0)
        let lat = isPipeline ? r.latencyMs : (r.rawPass?.latencyMs ?? 0)
        let out = isPipeline ? r.output : (r.rawPass?.output ?? "")
        let flaggedTense = isPipeline ? r.tenseFlagged : (r.rawPass?.tenseFlagged ?? false)
        let tChanges = isPipeline ? r.tenseChanges : (r.rawPass?.tenseChanges ?? 0)
        let cues = isPipeline ? r.temporalCues : (r.rawPass?.temporalCues ?? 0)
        let echo = isPipeline ? r.delimiterEchoed : (r.rawPass?.delimiterEchoed ?? false)
        let accepted = isPipeline ? r.validatorAccepted : (r.rawPass?.validatorAccepted ?? false)
        let outcome = isPipeline ? r.outcome : (r.rawPass?.outcome ?? "failed")

        if r.rawPass == nil && !isPipeline { continue }
        ttfts.append(ttf); lats.append(lat)
        if flaggedTense { tenseFlags += 1 }
        tenseTotal += tChanges
        cueTotal += cues
        if echo { echoes += 1 }
        if !accepted { rejected += 1 }
        if outcome == "unchanged" { claimedUnchanged += 1 }
        if outcome == "failed" || (isPipeline ? r.error != nil : r.rawPass?.error != nil) { failed += 1 }
        if isPipeline ? r.guardrailRefusal : (r.rawPass?.guardrailRefusal ?? false) { guardrails += 1 }
        if isPipeline && r.attempts > 1 { retries += 1 }
        outcomes[outcome, default: 0] += 1

        switch r.kind {
        case "wrong":
            wrongTotal += 1
            if isFixed(input: r.input, output: out, expected: r.expected ?? "") { fixed += 1 }
        case "correct":
            correctTotal += 1
            if out == r.input { unchanged += 1 }
        default:
            break
        }
    }

    let sT = ttfts.sorted(), sL = lats.sorted()
    let meanT = ttfts.isEmpty ? 0 : ttfts.reduce(0, +) / Double(ttfts.count)
    let meanL = lats.isEmpty ? 0 : lats.reduce(0, +) / Double(lats.count)

    return PassSummary(
        casesRun: ttfts.count,
        errorsFixed: fixed,
        wrongTotal: wrongTotal,
        correctUnchanged: unchanged,
        correctTotal: correctTotal,
        correctUnchangedRate: correctTotal == 0 ? nil : Double(unchanged) / Double(correctTotal),
        meanTtftMs: meanT,
        p50TtftMs: pct(sT, 50),
        p95TtftMs: pct(sT, 95),
        meanLatencyMs: meanL,
        p50LatencyMs: pct(sL, 50),
        p95LatencyMs: pct(sL, 95),
        tenseFlagCount: tenseFlags,
        tenseChangeTotal: tenseTotal,
        temporalCueTotal: cueTotal,
        delimiterEchoCount: echoes,
        validatorRejectedCount: rejected,
        claimedUnchangedCount: claimedUnchanged,
        failedCount: failed,
        guardrailRefusalCount: guardrails,
        retryLadderUsedCount: retries,
        outcomeCounts: outcomes)
}

// ----------------------------------------------------------------------- main

func main() async -> Int32 {
    guard let opts = parseArgs(CommandLine.arguments) else { return 1 }

    // Load golden set(s).
    var cases: [EvalCase] = []
    for path in opts.sets {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read set: \(path)\n".data(using: .utf8)!)
            return 2
        }
        let dec = JSONDecoder()
        for (n, line) in text.split(separator: "\n").enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            do {
                cases.append(try dec.decode(EvalCase.self, from: Data(t.utf8)))
            } catch {
                FileHandle.standardError.write("bad JSONL at \(path):\(n + 1): \(error)\n".data(using: .utf8)!)
                return 2
            }
        }
    }
    if !opts.sourceFilters.isEmpty {
        cases = cases.filter { c in opts.sourceFilters.contains { c.source.hasPrefix($0) } }
    }
    if let lim = opts.limit { cases = Array(cases.prefix(lim)) }
    guard !cases.isEmpty else {
        FileHandle.standardError.write("no cases selected\n".data(using: .utf8)!)
        return 2
    }

    // Engine.
    let engine: any GrammarEngine
    let kind: EngineKind
    switch opts.engine {
    case "apple":
        let e = AppleGrammarEngine()
        engine = e; kind = .apple
        guard e.status.isReady else {
            FileHandle.standardError.write("engine not ready: \(e.status.message ?? "?")\n".data(using: .utf8)!)
            return 3
        }
    case "local":
        let store = ModelStore()
        let e = LocalGrammarEngine(store: store)
        engine = e; kind = .local
        guard e.status.isReady else {
            FileHandle.standardError.write("engine not ready: \(e.status.message ?? "?")\n".data(using: .utf8)!)
            return 3
        }
    default:
        FileHandle.standardError.write("unknown engine: \(opts.engine)\n".data(using: .utf8)!)
        return 1
    }

    let apple = AppleGrammarEngine()
    let liveContext = kind == .apple ? apple.contextSize : Chunker.appleMeasuredContext
    let service = CorrectionService(contextSize: liveContext)
    let validator = Validator(kind: kind)

    let modelAvailability: String
    if kind == .apple {
        modelAvailability = String(describing: SystemLanguageModel.default.availability)
    } else {
        modelAvailability = "n/a"
    }

    let doRaw = opts.mode == "both" || opts.mode == "raw"
    let doPipe = opts.mode == "both" || opts.mode == "pipeline"

    // Cold call first, before prewarm(): PLAN-v2.md §0.3 recorded 971 ms here
    // and §4.7.2's prewarm() exists to hide it. Measuring it requires *not*
    // warming first, so this one extra call is deliberate.
    var coldFirstCallMs: Double? = nil
    if doRaw {
        coldFirstCallMs = await runRawPass(cases[0], engine: engine).ttftMs
    }

    await engine.prewarm()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    var records: [CaseRecord] = []

    FileHandle.standardError.write("GrammarBarEval: \(cases.count) cases, engine=\(opts.engine), mode=\(opts.mode)\n".data(using: .utf8)!)

    for (n, c) in cases.enumerated() {
        var rec = await runPipelinePass(c, engine: engine, service: service)
        if doRaw {
            rec.rawPass = await runRawPass(c, engine: engine)
        }
        records.append(rec)

        if !opts.quiet {
            let mark: String
            switch c.kind {
            case "wrong":   mark = rec.fixed == true ? "FIXED" : "MISS "
            case "correct": mark = rec.byteIdenticalToInput ? "OK   " : "EDITED"
            default:        mark = rec.byteIdenticalToInput ? "same " : "chg  "
            }
            let line = "[\(mark)] \(n + 1)/\(cases.count) \(c.id) "
                + String(format: "ttft=%.0fms total=%.0fms nd=%.3f tense=%d/%d echo=%@ out=%@",
                         rec.ttftMs, rec.latencyMs, rec.editDistance,
                         rec.tenseChanges, rec.temporalCues,
                         rec.delimiterEchoed ? "Y" : "N", rec.outcome)
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }
    }

    // ---- summaries
    var passSummaries: [String: PassSummary] = [:]
    if doPipe { passSummaries["pipeline"] = summarise(records, pass: "pipeline") }
    if doRaw { passSummaries["rawEngine"] = summarise(records, pass: "rawEngine") }

    var provenance: [String: Int] = [:]
    for r in records {
        let tag = r.source.components(separatedBy: " | ").first ?? r.source
        provenance[tag, default: 0] += 1
    }

    let changedCases = records.filter { $0.meaningChanged }.map { $0.id }
    let overEdited = records.filter { $0.kind == "correct" && !$0.byteIdenticalToInput }.map { $0.id }

    let iso = ISO8601DateFormatter()
    let dayFmt = DateFormatter()
    dayFmt.dateFormat = "yyyy-MM-dd"
    dayFmt.timeZone = TimeZone.current

    let env = Env(
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        macOSBuild: shell(["sw_vers", "-buildVersion"]),
        architecture: shell(["uname", "-m"]),
        hostModel: shell(["sysctl", "-n", "hw.model"]),
        chip: shell(["sysctl", "-n", "machdep.cpu.brand_string"]),
        swiftVersion: shell(["swift", "--version"]).components(separatedBy: "\n").first ?? "",
        engine: opts.engine,
        engineStatus: engine.status.isReady ? "ready" : (engine.status.message ?? "?"),
        modelAvailability: modelAvailability,
        contextSize: liveContext,
        promptRevision: "Prompts.base@PLAN-v2.md§4.5",
        defaultDelimiter: TextDelimiter.angleTags.rawValue,
        chunkerContextSize: liveContext,
        correctionServiceMaxAttempts: service.maxAttempts,
        validatorMaxEditDistance: validator.options.maxEditDistance,
        mode: opts.mode,
        notes: [
            "pipeline pass = CorrectionService.run (the app's real path); ttftMs there is time to the first emitted partial, which is emitted only after sanitize+validate, so it is NOT comparable to token-level TTFT.",
            "rawEngine pass = one-shot engine.correct(.angleTags) with no retry ladder, no escalation — the same call shape recon/AppleEngineProbe.swift used, so it is the pass comparable to PLAN-v2.md §0.3.",
            "fixed = normalized(output, expected) < normalized(input, expected)  (the recon rule).",
            "meaningChanged = output != input AND (TenseGuard flagged OR a protected number/URL/email from the input is missing from the output).",
            "the first engine call in this process happens BEFORE prewarm(); coldFirstRawCallTtftMs is that call's TTFT (PLAN-v2.md §0.3: 971 ms)."
        ])

    let report = Report(
        schema: "grammarbar-eval/1",
        generatedAt: iso.string(from: Date()),
        label: opts.label,
        set: opts.sets,
        caseCount: records.count,
        environment: env,
        sourceProvenance: provenance,
        summary: passSummaries,
        coldFirstRawCallTtftMs: coldFirstCallMs,
        meaningChangedCases: changedCases,
        overEditedCorrectCases: overEdited,
        records: records)

    // ---- write
    try? FileManager.default.createDirectory(atPath: opts.out, withIntermediateDirectories: true)
    let stem = "\(opts.engine)-\(opts.label)-\(dayFmt.string(from: Date()))"
    let jsonPath = "\(opts.out)/\(stem).json"
    let txtPath = "\(opts.out)/\(stem).txt"

    do {
        let data = try encoder.encode(report)
        // JSONEncoder omits nil optionals, so the key set would vary run to run.
        // For a file whose whole purpose is to be diffed across macOS updates,
        // insert explicit nulls for every schema key that is absent.
        try normaliseNulls(data).write(to: URL(fileURLWithPath: jsonPath))
    } catch {
        FileHandle.standardError.write("failed to write \(jsonPath): \(error)\n".data(using: .utf8)!)
        return 4
    }

    let text = renderText(report)
    try? text.write(toFile: txtPath, atomically: true, encoding: .utf8)
    print(text)
    FileHandle.standardError.write("\nwrote \(jsonPath)\nwrote \(txtPath)\n".data(using: .utf8)!)
    return 0
}

func f1(_ v: Double?) -> String { v == nil ? "n/a" : String(format: "%.3f", v!) }

/// The optional keys of the two record types plus the report root. Only these
/// object levels are normalised — `summary.outcomeCounts` is a free-form
/// dictionary and must not have keys injected into it.
let caseOptionalKeys = ["expected", "fixed", "editDistanceToExpected", "rawPass", "error"]
let passOptionalKeys = ["error"]
let rootOptionalKeys = ["coldFirstRawCallTtftMs"]

func withNulls(_ dict: [String: Any], _ keys: [String]) -> [String: Any] {
    var out = dict
    for k in keys where out[k] == nil { out[k] = NSNull() }
    return out
}

func normaliseNulls(_ data: Data) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "GrammarBarEval", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "report is not a JSON object"])
    }
    root = withNulls(root, rootOptionalKeys)
    if let records = root["records"] as? [[String: Any]] {
        root["records"] = records.map { rec -> [String: Any] in
            var r = withNulls(rec, caseOptionalKeys)
            if let raw = r["rawPass"] as? [String: Any] {
                r["rawPass"] = withNulls(raw, passOptionalKeys)
            }
            return r
        }
    }
    return try JSONSerialization.data(withJSONObject: root,
                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

func renderText(_ r: Report) -> String {
    var out = ""
    out += "GrammarBarEval — \(r.generatedAt)\n"
    out += "set: \(r.set.joined(separator: ", "))   cases: \(r.caseCount)\n"
    out += "host: \(r.environment.macOSVersion) build \(r.environment.macOSBuild) "
    out += "\(r.environment.architecture) \(r.environment.hostModel) \(r.environment.chip)\n"
    out += "\(r.environment.swiftVersion)\n"
    out += "engine: \(r.environment.engine)  status=\(r.environment.engineStatus)  "
    out += "availability=\(r.environment.modelAvailability)  contextSize=\(r.environment.contextSize)  "
    out += "mode=\(r.environment.mode)\n"
    out += "provenance: " + r.sourceProvenance.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: "  ") + "\n"
    out += "cold first call (pre-prewarm): "
        + (r.coldFirstRawCallTtftMs.map { String(format: "%.0f ms", $0) } ?? "n/a") + "\n"
    out += String(repeating: "=", count: 78) + "\n"

    for key in ["pipeline", "rawEngine"] {
        guard let s = r.summary[key] else { continue }
        out += "\n[\(key)]\n"
        out += "  errors fixed            : \(s.errorsFixed)/\(s.wrongTotal)\n"
        out += "  correct unchanged       : \(s.correctUnchanged)/\(s.correctTotal)"
        out += "  (\(f1(s.correctUnchangedRate)))\n"
        out += String(format: "  TTFT   mean %.0f ms   p50 %.0f   p95 %.0f\n", s.meanTtftMs, s.p50TtftMs, s.p95TtftMs)
        out += String(format: "  total  mean %.0f ms   p50 %.0f   p95 %.0f\n", s.meanLatencyMs, s.p50LatencyMs, s.p95LatencyMs)
        out += "  tense-guard flags       : \(s.tenseFlagCount)   (sum tenseChanges=\(s.tenseChangeTotal), cues=\(s.temporalCueTotal))\n"
        out += "  delimiter echoes        : \(s.delimiterEchoCount)\n"
        out += "  guardrail refusals      : \(s.guardrailRefusalCount)\n"
        out += "  validator rejections    : \(s.validatorRejectedCount)\n"
        out += "  retry ladder used       : \(s.retryLadderUsedCount)\n"
        out += "  runs claiming unchanged : \(s.claimedUnchangedCount)\n"
        out += "  failed runs             : \(s.failedCount)\n"
        out += "  outcomes                : " + s.outcomeCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "\n"
    }

    out += "\nmeaning-changed corrections (\(r.meaningChangedCases.count)): "
    out += r.meaningChangedCases.isEmpty ? "none" : r.meaningChangedCases.joined(separator: ", ")
    out += "\nover-edited already-correct cases (\(r.overEditedCorrectCases.count)): "
    out += r.overEditedCorrectCases.isEmpty ? "none" : r.overEditedCorrectCases.joined(separator: ", ")
    out += "\ndelimiter escalations: "
        + String(r.records.filter { $0.delimiterEscalated }.count)
    out += "\n"
    let refusals = r.records.filter { $0.guardrailRefusal }.map { $0.id }
    out += "guardrail-refused cases (\(refusals.count)): " + refusals.joined(separator: ", ") + "\n"

    out += "\n--- per-case (pipeline | rawEngine) ---\n"
    for c in r.records {
        let f = c.fixed.map { $0 ? "FIXED" : "MISS" } ?? "-"
        out += "\(c.id) [\(c.kind)] \(f) pipeline=\(c.outcome) nd=\(String(format: "%.3f", c.editDistance)) "
        if let raw = c.rawPass {
            let rf = raw.fixed.map { $0 ? "FIXED" : "MISS" } ?? "-"
            out += "| raw=\(raw.outcome) \(rf) nd=\(String(format: "%.3f", raw.editDistance)) echo=\(raw.delimiterEchoed ? "Y" : "N")"
        }
        out += "\n"
        out += "   in : \(c.input.replacingOccurrences(of: "\n", with: "\\n"))\n"
        out += "   out: \(c.output.replacingOccurrences(of: "\n", with: "\\n"))\n"
        if let raw = c.rawPass, raw.rawModelOutput != c.output {
            out += "   raw model out: \(raw.rawModelOutput.replacingOccurrences(of: "\n", with: "\\n"))\n"
        }
        if let e = c.expected, c.kind == "wrong" {
            out += "   exp: \(e.replacingOccurrences(of: "\n", with: "\\n"))\n"
        }
        if c.meaningChanged {
            out += "   >>> MEANING CHANGED (tense \(c.tenseChanges) vs cues \(c.temporalCues)"
            + (c.lostProtectedTokens.isEmpty ? "" : ", lost \(c.lostProtectedTokens.joined(separator: ","))") + ")\n"
        }
        if let e = c.error { out += "   error: \(e)\n" }
    }
    return out
}

exit(await main())
