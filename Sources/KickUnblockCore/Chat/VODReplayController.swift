import Foundation

public enum VODReplayPhase: Equatable, Sendable {
    case idle, loading, ready, empty, partial
    case unavailable(VODReplayError)
}

public struct VODReplaySnapshot: Equatable, Sendable {
    public var phase: VODReplayPhase
    public var messages: [IncomingChat]
    public init(phase: VODReplayPhase = .idle, messages: [IncomingChat] = []) {
        self.phase = phase; self.messages = messages
    }
}

@MainActor
public final class VODReplayController {
    public let context: VODReplayContext
    public private(set) var snapshot = VODReplaySnapshot()
    public var onChange: (@MainActor (VODReplaySnapshot) -> Void)?
    private let client: VODReplayClient
    private let lookAhead: TimeInterval
    private let backfill: TimeInterval
    private let debounce: Duration
    private let storeLimit = 600
    private let visibleLimit = 300
    private var position: TimeInterval = 0
    private var window: VODReplayWindow?
    private var hasGap = false
    private var loadTask: Task<Void, Never>?
    private var extendTask: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private var failed = false

    public init(context: VODReplayContext, client: VODReplayClient, lookAhead: TimeInterval = 15,
                backfill: TimeInterval = 60, debounce: Duration = .milliseconds(300)) {
        self.context = context; self.client = client
        self.lookAhead = lookAhead.isFinite ? min(30, max(1, lookAhead)) : 15
        self.backfill = backfill.isFinite ? min(120, max(0, backfill)) : 60
        self.debounce = debounce
    }

    public func seek(to seconds: TimeInterval) async {
        beginLoad(at: seconds, debounced: false)
        guard let task = loadTask else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    public func update(to seconds: TimeInterval) {
        guard !stopped, let time = try? context.clamped(seconds) else { return }
        let jumped = time < position - 0.25 || time > position + 3
        position = time
        if jumped {
            if !failed, loadTask == nil, let window, covers(window, time) { publish(window); return }
            beginLoad(at: time, debounced: true)
            return
        }
        guard !failed else { return }
        guard let window else {
            if loadTask == nil { beginLoad(at: time, debounced: false) }
            return
        }
        publish(window)
        if loadTask == nil, extendTask == nil, window.upperBound < context.duration,
           time >= window.upperBound - min(5, lookAhead / 2) {
            extend(from: window.upperBound, through: min(context.duration, time + lookAhead))
        }
    }

    public func stop() {
        stopped = true
        generation += 1
        loadTask?.cancel(); loadTask = nil
        extendTask?.cancel(); extendTask = nil
        window = nil; hasGap = false
        setSnapshot(.init())
    }

    private func covers(_ window: VODReplayWindow, _ time: TimeInterval) -> Bool {
        !window.isPartial && time >= window.lowerBound && time <= window.upperBound
    }

    private func beginLoad(at seconds: TimeInterval, debounced: Bool) {
        generation += 1
        loadTask?.cancel(); loadTask = nil
        extendTask?.cancel(); extendTask = nil
        window = nil; hasGap = false
        stopped = false; failed = false
        guard let time = try? context.clamped(seconds) else {
            failed = true; setSnapshot(.init(phase: .unavailable(.invalidTimestamp))); return
        }
        position = time
        setSnapshot(.init(phase: .loading))
        let token = generation, client = client, context = context, delay = debounce
        let lower = max(0, time - backfill), upper = min(context.duration, time + lookAhead)
        loadTask = Task { [weak self] in
            do {
                if debounced { try await Task.sleep(for: delay) }
                let window = try await client.load(context: context, from: lower, through: upper)
                guard !Task.isCancelled, let self, self.generation == token, !self.stopped else { return }
                self.loadTask = nil
                self.window = window
                self.hasGap = window.isPartial
                self.publish(window)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, !self.stopped else { return }
                self.loadTask = nil; self.failed = true
                self.setSnapshot(.init(phase: .unavailable((error as? VODReplayError) ?? .unexpectedResponse)))
            }
        }
    }

    private func extend(from lower: TimeInterval, through upper: TimeInterval) {
        guard lower < upper else { return }
        let token = generation, client = client, context = context
        extendTask = Task { [weak self] in
            do {
                let next = try await client.load(context: context, from: lower, through: upper)
                guard !Task.isCancelled, let self, self.generation == token, !self.stopped,
                      let current = self.window else { return }
                self.extendTask = nil
                let merged = self.merged(current, next)
                self.window = merged
                if next.isPartial { self.hasGap = true }
                self.publish(merged)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, !self.stopped else { return }
                self.extendTask = nil; self.failed = true
                self.setSnapshot(.init(phase: .unavailable((error as? VODReplayError) ?? .unexpectedResponse),
                                       messages: self.snapshot.messages))
            }
        }
    }

    private func merged(_ a: VODReplayWindow, _ b: VODReplayWindow) -> VODReplayWindow {
        var ids = Set<String>()
        var rows = (a.messages + b.messages)
            .sorted { $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt }
            .filter { ids.insert($0.id).inserted }
        var lower = a.lowerBound
        if rows.count > storeLimit {
            rows = Array(rows.suffix(storeLimit))
            lower = max(lower, rows[0].sentAt.timeIntervalSince(context.startedAt))
        }
        return VODReplayWindow(lowerBound: lower, upperBound: max(a.upperBound, b.upperBound),
                               messages: rows, isPartial: a.isPartial || b.isPartial)
    }

    private func publish(_ window: VODReplayWindow) {
        let cutoff = context.startedAt.addingTimeInterval(position)
        let rows = Array(window.messages.filter { $0.sentAt <= cutoff }.suffix(visibleLimit))
        let phase: VODReplayPhase = hasGap ? .partial : rows.isEmpty ? .empty : .ready
        setSnapshot(.init(phase: phase, messages: rows))
    }

    private func setSnapshot(_ value: VODReplaySnapshot) {
        guard value != snapshot else { return }
        snapshot = value
        onChange?(value)
    }
}
