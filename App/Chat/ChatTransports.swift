import Foundation
import KickUnblockCore

class WebSocketTransportBase: NSObject {
    var onEvent: ((ChatStreamEvent) -> Void)?
    var onStatus: ((ChatConnectionStatus) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var attempts = 0
    private(set) var stopped = true
    var fatal = false
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": KickWebClient.userAgent]
        return URLSession(configuration: c)
    }()

    func open(_ url: URL) {
        stopped = false
        fatal = false
        onStatus?(.connecting)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(on: t, url: url)
    }

    func send(_ text: String) { task?.send(.string(text)) { _ in } }
    func handle(_ text: String) {}
    func reconnectURL(after url: URL) async -> URL? { url }

    func close() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onStatus?(.idle)
    }

    func markConnected() { attempts = 0; onStatus?(.connected) }

    private func receive(on t: URLSessionWebSocketTask, url: URL) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .success(.string(let s)): self.handle(s); self.receive(on: t, url: url)
            case .success(.data(let d)): self.handle(String(decoding: d, as: UTF8.self)); self.receive(on: t, url: url)
            case .success: self.receive(on: t, url: url)
            case .failure(let e):
                if KickPusher.isFatalClose(t.closeCode.rawValue) { self.fatal = true }
                self.onStatus?(.failed(e.localizedDescription))
                guard !self.stopped else { return }
                let delay = KickPusher.backoff(attempt: self.attempts) + Double.random(in: 0...0.5)
                self.attempts += 1
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, !self.stopped, let next = await self.reconnectURL(after: url) else { return }
                    self.open(next)
                }
            }
        }
    }
}

final class KickPusherTransport: WebSocketTransportBase, ChatTransport {
    private var key: String
    private var cluster: String
    private var channel = ""
    private var channelID: Int?
    private var negotiated = false
    private var keepAlive: Timer?

    init(key: String?, cluster: String?) {
        self.key = (key?.isEmpty == false ? key! : KickPusher.defaultKey)
        self.cluster = (cluster?.isEmpty == false ? cluster! : KickPusher.defaultCluster)
    }

    func connect(_ target: ChatTarget) {
        guard let room = target.chatroomID else {
            onStatus?(.failed("This channel needs Website data for chat.")); return
        }
        channel = KickPusher.chatChannel(chatroomID: room)
        channelID = target.channelID
        guard let url = PusherFrame.socketURL(cluster: cluster, key: key) else { onStatus?(.failed("Invalid Pusher settings")); return }
        open(url)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keepAlive?.invalidate()
            self.keepAlive = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.send(PusherFrame.ping) }
        }
    }

    func disconnect() {
        if !channel.isEmpty { send(PusherFrame.unsubscribe(channel)) }
        DispatchQueue.main.async { [weak self] in self?.keepAlive?.invalidate() }
        close()
    }

    override func handle(_ text: String) {
        guard let f = PusherFrame.decode(text) else { return }
        switch f.event {
        case "pusher:connection_established": send(PusherFrame.subscribe(channel))
        case "pusher_internal:subscription_succeeded": markConnected()
        case "pusher:ping": send(PusherFrame.pong)
        case "pusher:error":
            let code = (f.data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])?["code"] as? Int
            if code == KickPusher.appKeyNotInCluster { fatal = true }
            onStatus?(.failed("Pusher error \(code.map(String.init) ?? "")"))
        default:
            if let ev = KickPusherEvents.parse(frame: text) { onEvent?(ev) }
        }
    }

    override func reconnectURL(after url: URL) async -> URL? {
        guard fatal else { return url }
        guard !negotiated, let id = channelID else { onStatus?(.failed("Pusher rejected the chat key (4001). Set a key under Tweaks › Developer Diagnostics.")); return nil }
        negotiated = true
        let req = KickRealtimeNegotiation.request(channelID: id, clientID: UUID().uuidString.lowercased(), userAgent: KickWebClient.userAgent)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let creds = KickRealtimeNegotiation.pusherCredentials(from: data) else {
            onStatus?(.failed("Couldn't refresh chat credentials.")); return nil
        }
        key = creds.key; cluster = creds.cluster
        return PusherFrame.socketURL(cluster: cluster, key: key)
    }
}

final class RelayChatTransport: WebSocketTransportBase, ChatTransport {
    let base: URL
    init(base: URL) { self.base = base }

    func connect(_ target: ChatTarget) {
        guard let id = target.broadcasterUserID else { onStatus?(.failed("Missing broadcaster ID")); return }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [.init(name: "broadcaster_user_id", value: String(id))]
        open(c.url!)
    }
    func disconnect() { close() }

    override func handle(_ text: String) {
        guard let env = try? JSONDecoder().decode(RelayEnvelope.self, from: Data(text.utf8)) else {
            if text.contains("\"hello\"") { markConnected() }
            return
        }
        markConnected()
        if env.type == "chat.message.sent", let p = env.payload { onEvent?(.message(IncomingChat(webhook: p))) }
    }
}
