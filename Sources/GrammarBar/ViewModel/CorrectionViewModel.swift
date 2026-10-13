import Foundation
import Observation
import GrammarBarCore

@MainActor
@Observable
public final class CorrectionViewModel {

    public enum RunState: Equatable {
        case idle
        case running
        case done(CorrectionOutcome)
        case failed(String)

        public var isRunning: Bool { if case .running = self { return true }; return false }
    }

    public var input: String = ""
    public private(set) var output: String = ""
    public private(set) var state: RunState = .idle
    public private(set) var warning: String?
    public private(set) var attempts: Int = 0
    public private(set) var firstTokenMilliseconds: Double?
    public private(set) var totalMilliseconds: Double?

    private var task: Task<Void, Never>?
    private let service = CorrectionService()

    public init() {}

    public func submit(engine: any GrammarEngine) {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        cancel()
        output = ""
        warning = nil
        attempts = 0
        firstTokenMilliseconds = nil
        totalMilliseconds = nil
        state = .running

        let started = Date()
        var sawFirstToken = false

        task = Task { [service] in
            do {
                for try await event in service.run(text: text, engine: engine) {
                    if Task.isCancelled { return }
                    switch event {
                    case .partial(let partial):
                        if !sawFirstToken {
                            sawFirstToken = true
                            self.firstTokenMilliseconds = Date().timeIntervalSince(started) * 1000
                        }
                        self.output = partial
                    case .finished(let result):
                        self.output = result.text
                        self.attempts = result.attempts
                        self.totalMilliseconds = Date().timeIntervalSince(started) * 1000
                        switch result.outcome {
                        case .flagged(let message):
                            self.warning = message
                            self.state = .done(result.outcome)
                        case .failed(let message):
                            self.state = .failed(message)
                        default:
                            self.state = .done(result.outcome)
                        }
                    }
                }
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if state.isRunning { state = .idle }
    }

    /// True when a clear action has something to remove.
    public var hasContent: Bool {
        !input.isEmpty || !output.isEmpty || warning != nil
    }

    public func clear() {
        cancel()
        input = ""
        output = ""
        warning = nil
        // Without these the header keeps showing the previous run's "412 ms"
        // over a now-empty panel.
        attempts = 0
        firstTokenMilliseconds = nil
        totalMilliseconds = nil
        state = .idle
    }
}
