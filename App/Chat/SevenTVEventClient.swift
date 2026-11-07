import Foundation
import KickUnblockCore

@MainActor
final class SevenTVEventClient: SevenTVEventStream {
    var onEvent: ((SevenTVEvent) -> Void)?
    private var wanted: Set<SevenTVSubscription> = []
    private var active: Set<SevenTVSubscription> = []
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var attempts = 0
    private var heartbeat: TimeInterval = 45
    private var lastMessage: TimeInterval = 0
    private var watchdog: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    func update(_ subscriptions: Set<SevenTVSubscription>) {
        guard !subscriptions.isEmpty else { stop(); return }
        wanted = subscriptions
        if task == nil {
            if retry == nil { connect() }
        } else if ready {
            sync()
        }
    }

    func stop() {
        wanted = []
        retry?.cancel(); retry = nil
        teardown()
    }

    private func teardown() {
        watchdog?.cancel(); watchdog = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
        active = []
    }

    private func connect() {
        retry = nil
        teardown()
        let t = session.webSocketTask(with: SevenTVEventAPI.url)
        task = t
        lastMessage = ProcessInfo.processInfo.systemUptime
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(.string(let s)): self.handle(s); self.receive(t)
                case .success(.data(let d)): self.handle(String(decoding: d, as: UTF8.self)); self.receive(t)
                case .success: self.receive(t)
                case .failure: self.dropped(closeCode: t.closeCode.rawValue)
                }
            }
        }
    }

    private func handle(_ text: String) {
        lastMessage = ProcessInfo.processInfo.systemUptime
        switch SevenTVEventAPI.decode(text) {
        case .hello(let interval):
            heartbeat = interval
            ready = true
            attempts = 0
            sync()
            startWatchdog()
        case .dispatch(let event): onEvent?(event)
        case .reconnect: dropped(closeCode: nil)
        case .endOfStream(let code): dropped(closeCode: code)
        case .heartbeat, .ignored: break
        }
    }

    private func sync() {
        for s in active.subtracting(wanted) { send(SevenTVEventAPI.unsubscribe(s)) }
        for s in wanted.subtracting(active) { send(SevenTVEventAPI.subscribe(s)) }
        active = wanted
    }

    private func send(_ text: String) { task?.send(.string(text)) { _ in } }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if SevenTVEventAPI.isStale(lastMessage: self.lastMessage, now: ProcessInfo.processInfo.systemUptime, heartbeat: self.heartbeat) {
                    self.dropped(closeCode: nil)
                    return
                }
            }
        }
    }

    private func dropped(closeCode: Int?) {
        teardown()
        guard !wanted.isEmpty, closeCode.map(SevenTVEventAPI.shouldReconnect(closeCode:)) ?? true else { return }
        let delay = SevenTVEventAPI.reconnectDelay(attempt: attempts, closeCode: closeCode) + Double.random(in: 0...1)
        attempts += 1
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.wanted.isEmpty else { return }
            self.connect()
        }
    }
}
