import SwiftUI
import KickUnblockCore

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var status: ChatConnectionStatus = .idle
    @Published var draft = "" { didSet { draftRevision &+= 1 } }
    @Published private(set) var isSending = false
    private var draftRevision: UInt64 = 0
    private let sender = OAuthChatSendCoordinator()
    private var sendContext = UUID()
    @Published var sendError: String?
    @Published private(set) var subBadges: SubscriberBadgeSet = .empty
    @Published private(set) var badgeImages: [URL: UIImage] = [:]
    @Published private(set) var isReplay = false
    @Published private(set) var cosmetics = SevenTVCosmeticsStore()
    @Published private(set) var cosmeticBadgeImages: [String: UIImage] = [:]
    private(set) var replayStartedAt: Date?
    private var replayRows: [String: ChatMessage] = [:]
    private var replayAllowed: [String: Bool] = [:]

    private var transport: ChatTransport?
    private var emoteSession = ChatEmoteSession()
    private var emotes: EmoteIndex { emoteSession.index }
    private var filter = ChatFilter(settings: .init())
    private var target: ChatTarget?
    var channelSlug: String? { target?.slug }
    var thirdPartyEmotes: EmoteIndex { emotes }
    private var deduper = MessageDeduper()
    private var pending: [ChatStreamEvent] = []
    private var flushTask: Task<Void, Never>?
    private static let flushInterval: UInt64 = 200_000_000
    private var historyTask: Task<Void, Never>?
    private var badgeTask: Task<Void, Never>?
    private var activeSetTask: Task<Void, Never>?
    private var events: SevenTVEventStream?
    private var sevenTVChannel = SevenTVChannel.empty
    private var badgeLoads: Set<String> = []
    private var everConnected = false
    private var defaultsObs: NSObjectProtocol?
    private let d = UserDefaults.standard

    private var maxMessages: Int {
        let n = d.integer(forKey: PrefKey.chatMaxMessages)
        return n == 0 ? ChatLimits.defaultMax : ChatLimits.clamp(n)
    }
    private var kickEmotes: Bool { d.bool(PrefKey.emotesKick, default: TweakDefault.emotesKick) }
    private var sevenTVEnabled: Bool { d.bool(PrefKey.emotes7TV, default: TweakDefault.emotes7TV) }
    private var cosmeticsEnabled: Bool { d.bool(PrefKey.sevenTVCosmetics, default: TweakDefault.sevenTVCosmetics) }

    static func filterSettings(_ d: UserDefaults = .standard) -> ChatFilterSettings {
        ChatFilterSettings(hideCommands: d.bool(PrefKey.hideCommands, default: TweakDefault.hideCommands),
                           hideSystemBanners: d.bool(PrefKey.hideSystemBanners, default: TweakDefault.hideBanners),
                           dedupe: d.bool(PrefKey.dedupeSpam, default: TweakDefault.dedupe),
                           blockedTerms: d.stringArray(forKey: PrefKey.blockedTerms) ?? [],
                           blockedUsers: Set(d.stringArray(forKey: PrefKey.blockedUsers) ?? []))
    }

    static func makeEventStream() -> SevenTVEventStream { SevenTVEventClient() }

    static func makeTransport(_ d: UserDefaults = .standard) -> ChatTransport {
        if let s = d.string(forKey: PrefKey.chatRelayURL), !s.isEmpty, let url = URL(string: s) {
            return RelayChatTransport(base: url)
        }
        return KickPusherTransport(key: d.string(forKey: PrefKey.pusherKey), cluster: d.string(forKey: PrefKey.pusherCluster))
    }

    func start(_ target: ChatTarget, globalEmotes: EmoteIndex) async {
        guard self.target != target || isReplay else { return }
        stop()
        isReplay = false
        replayRows = [:]
        self.target = target
        messages = []
        deduper.reset()
        filter = ChatFilter(settings: Self.filterSettings())
        let emoteGen = emoteSession.begin(globalEmotes)
        defaultsObs = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        everConnected = false
        subBadges = .empty
        sevenTVChannel = .empty
        let t = Self.makeTransport()
        t.onStatus = { [weak self, weak t] s in
            Task { @MainActor in
                guard let self, let t, self.transport === t else { return }
                self.handleStatus(s)
            }
        }
        t.onEvent = { [weak self, weak t] ev in
            Task { @MainActor in
                guard let self, let t, self.transport === t else { return }
                self.enqueue(ev)
            }
        }
        transport = t
        var emoteTask: Task<SevenTVChannel, Never>?
        if sevenTVEnabled, let uid = target.broadcasterUserID {
            emoteTask = Task { await AppModel.fetchSevenTVChannel(kickUserID: uid) }
        }
        if let channelID = target.channelID {
            historyTask = Task { [weak self] in
                async let recent = ChatHistory.fetchRecent(channelID: channelID)
                if let e = await emoteTask?.value { self?.useEmotes(e, for: target, generation: emoteGen) }
                let r = await recent
                guard !Task.isCancelled else { return }
                self?.insertHistory(r, for: target)
            }
        }
        let slug = target.slug
        if !slug.isEmpty {
            badgeTask = Task { [weak self] in
                let set = await SubscriberBadgeSet.fetch(slug: slug)
                guard !Task.isCancelled else { return }
                await self?.useBadges(set, for: target)
            }
        }
        t.connect(target)
        updateEventSubscriptions()
        if let e = await emoteTask?.value { useEmotes(e, for: target, generation: emoteGen) }
    }

    private func useEmotes(_ channel: SevenTVChannel, for t: ChatTarget, generation: UInt64) {
        guard target == t, sevenTVEnabled, generation == emoteSession.generation else { return }
        sevenTVChannel = channel
        updateEventSubscriptions()
        guard emoteSession.accept(channel: channel.index, for: generation) else { return }
        messages = emoteSession.hydrate(messages, cache: &replayRows)
    }

    private func preferencesChanged() {
        applyFilterSettings()
        if !cosmeticsEnabled && cosmetics != SevenTVCosmeticsStore() { cosmetics = SevenTVCosmeticsStore() }
        updateEventSubscriptions()
    }

    private func applyFilterSettings() {
        let next = Self.filterSettings()
        guard next != filter.settings else { return }
        filter.settings = next
        let kept = messages.filter { !filter.blocks($0) }
        if kept.count != messages.count { messages = kept }
    }

    func block(user name: String) {
        guard let user = ChatBlockList.user(name) else { return }
        d.set(ChatBlockList.adding(user, to: d.stringArray(forKey: PrefKey.blockedUsers) ?? []), forKey: PrefKey.blockedUsers)
        applyFilterSettings()
    }

    // MARK: 7TV live events

    private func updateEventSubscriptions() {
        guard !isReplay, let t = target else { stopEvents(); return }
        var subs = Set<SevenTVSubscription>()
        if sevenTVEnabled {
            if let id = sevenTVChannel.setID { subs.insert(.emoteSet(id)) }
            if let id = sevenTVChannel.userID { subs.insert(.user(id)) }
        }
        if cosmeticsEnabled, let id = t.broadcasterUserID { subs.formUnion(SevenTVSubscription.cosmetics(kickUserID: id)) }
        guard !subs.isEmpty else { stopEvents(); return }
        if events == nil {
            let stream = Self.makeEventStream()
            stream.onEvent = { [weak self, weak stream] ev in
                guard let self, let stream, self.events === stream else { return }
                self.handle(ev)
            }
            events = stream
        }
        events?.update(subs)
    }

    private func stopEvents() {
        events?.stop()
        events = nil
    }

    private func handle(_ ev: SevenTVEvent) {
        switch ev {
        case .emoteSetChanged(let setID, let added, let removed):
            guard sevenTVEnabled, setID == sevenTVChannel.setID,
                  emoteSession.applyChannelChange(added: added, removed: removed) else { return }
            messages = emoteSession.hydrate(messages, cache: &replayRows)
        case .activeSetChanged(let userID):
            guard userID == sevenTVChannel.userID, let t = target, let uid = t.broadcasterUserID else { return }
            let generation = emoteSession.generation
            activeSetTask?.cancel()
            activeSetTask = Task { [weak self] in
                let channel = await AppModel.fetchSevenTVChannel(kickUserID: uid)
                guard !Task.isCancelled else { return }
                self?.useEmotes(channel, for: t, generation: generation)
            }
        case .entitlement, .cosmetic:
            guard cosmeticsEnabled else { return }
            var next = cosmetics
            guard next.apply(ev) else { return }
            cosmetics = next
            if case .cosmetic(.badge(let badge)) = ev { loadCosmeticBadge(badge) }
        }
    }

    private func loadCosmeticBadge(_ badge: SevenTVBadge) {
        guard cosmeticBadgeImages[badge.id] == nil, badgeLoads.insert(badge.id).inserted else { return }
        Task { [weak self] in
            let image = await EmoteDataCache.shared.image(for: badge.url, provider: .sevenTV)
            guard let self else { return }
            self.badgeLoads.remove(badge.id)
            if let image { self.cosmeticBadgeImages[badge.id] = image }
        }
    }

    func updateGlobalEmotes(_ globals: EmoteIndex) {
        guard target != nil,
              emoteSession.accept(globals: globals, keepChannel: sevenTVEnabled)
        else { return }
        messages = emoteSession.hydrate(messages, cache: &replayRows)
    }

    private func useBadges(_ set: SubscriberBadgeSet, for t: ChatTarget) async {
        guard target == t else { return }
        subBadges = set
        for tier in set.tiers {
            guard let url = tier.imageURL, badgeImages[url] == nil else { continue }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data), target == t else { continue }
            badgeImages[url] = img
        }
    }

    private func handleStatus(_ s: ChatConnectionStatus) {
        guard !isReplay else { return }
        let wasConnected = status == .connected
        status = s
        guard s == .connected else { return }
        if everConnected && !wasConnected, let t = target, let channelID = t.channelID {
            historyTask?.cancel()
            historyTask = Task { [weak self] in
                let recent = await ChatHistory.fetchRecent(channelID: channelID)
                guard !Task.isCancelled else { return }
                self?.insertHistory(recent, for: t)
            }
        }
        everConnected = true
    }

    // MARK: VOD replay (driven by VODChatReplay)

    func beginReplay(_ t: ChatTarget, startedAt: Date, globalEmotes: EmoteIndex) {
        stop()
        isReplay = true
        replayStartedAt = startedAt
        target = ChatTarget(channelID: t.channelID, chatroomID: nil, broadcasterUserID: t.broadcasterUserID, slug: t.slug)
        let replayTarget = target!
        messages = []
        replayRows = [:]
        replayAllowed = [:]
        deduper.reset()
        sendError = nil
        draft = ""
        status = .connecting
        subBadges = .empty
        let emoteGen = emoteSession.begin(globalEmotes)
        filter = ChatFilter(settings: Self.filterSettings())
        if sevenTVEnabled, let uid = t.broadcasterUserID {
            historyTask = Task { [weak self] in
                let e = await AppModel.fetchSevenTVChannel(kickUserID: uid)
                guard !Task.isCancelled, let self, self.isReplay else { return }
                self.useEmotes(e, for: replayTarget, generation: emoteGen)
            }
        }
        if !t.slug.isEmpty {
            badgeTask = Task { [weak self] in
                let set = await SubscriberBadgeSet.fetch(slug: t.slug)
                guard !Task.isCancelled else { return }
                await self?.useBadges(set, for: replayTarget)
            }
        }
    }

    func showReplay(_ snapshot: VODReplaySnapshot) {
        guard isReplay else { return }
        var next: [String: ChatMessage] = [:]
        var rows: [ChatMessage] = []
        rows.reserveCapacity(snapshot.messages.count)
        for c in snapshot.messages {
            let m = replayRows[c.id] ?? ChatMessage(c, emotes: emotes, kickEmotes: kickEmotes)
            next[c.id] = m
            let allowed = replayAllowed[c.id] ?? filter.allows(m, now: c.sentAt)
            replayAllowed[c.id] = allowed
            if allowed && !filter.blocks(m) { rows.append(m) }
        }
        replayRows = next
        if replayAllowed.count > next.count * 4 + 1000 { replayAllowed = replayAllowed.filter { next[$0.key] != nil } }
        let limited = rows.count > maxMessages ? Array(rows.suffix(maxMessages)) : rows
        if limited.map(\.id) != messages.map(\.id) { messages = limited }
        let newStatus: ChatConnectionStatus
        switch snapshot.phase {
        case .idle, .loading: newStatus = .connecting
        case .ready, .empty, .partial: newStatus = .connected
        case .unavailable(let e): newStatus = .failed(Self.replayErrorText(e))
        }
        if status != newStatus { status = newStatus }
    }

    func endReplay() {
        guard isReplay else { return }
        stop()
        isReplay = false
        replayStartedAt = nil
        replayRows = [:]
        replayAllowed = [:]
        messages = []
        status = .idle
    }

    static func replayErrorText(_ e: VODReplayError) -> String {
        switch e {
        case .rateLimited: return "Chat replay is rate limited. Seek to try again."
        case .httpStatus(let code): return "Chat replay unavailable (HTTP \(code)). Seek to try again."
        case .invalidContext, .invalidTimestamp: return "Chat replay isn't available for this video."
        case .cursorLoop, .outsideWindow, .unexpectedResponse: return "Chat replay returned unexpected data."
        }
    }

    func stop() {
        sendContext = UUID()
        draftRevision &+= 1
        flushTask?.cancel(); flushTask = nil
        pending.removeAll()
        historyTask?.cancel(); historyTask = nil
        badgeTask?.cancel(); badgeTask = nil
        activeSetTask?.cancel(); activeSetTask = nil
        stopEvents()
        emoteSession.end()
        transport?.disconnect(); transport = nil; target = nil
        if let o = defaultsObs { NotificationCenter.default.removeObserver(o) }
        defaultsObs = nil
    }

    private func insertHistory(_ recent: [IncomingChat], for t: ChatTarget) {
        guard !isReplay, target == t, !recent.isEmpty else { return }
        var older: [ChatMessage] = []
        for c in recent where deduper.insert(c.id) {
            let m = ChatMessage(c, emotes: emotes, kickEmotes: kickEmotes)
            if filter.allows(m) { older.append(m) }
        }
        guard !older.isEmpty else { return }
        messages = ChatTimeline.merge(existing: messages, history: older, limit: maxMessages)
    }

    private func enqueue(_ ev: ChatStreamEvent) {
        guard !isReplay else { return }
        pending.append(ev)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushInterval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard !isReplay, !pending.isEmpty else { pending.removeAll(); return }
        var list = messages
        for ev in pending { apply(ev, to: &list) }
        pending.removeAll()
        if list.count > maxMessages { list.removeFirst(list.count - maxMessages) }
        messages = list
    }

    private func apply(_ ev: ChatStreamEvent, to list: inout [ChatMessage]) {
        switch ev {
        case .message(let c):
            guard deduper.insert(c.id) else { return }
            let m = ChatMessage(c, emotes: emotes, kickEmotes: kickEmotes)
            guard filter.allows(m) else { return }
            list.append(m)
        case .system(let id, let text):
            let m = ChatMessage.system(id: id, text: text)
            guard filter.allows(m) else { return }
            list.append(m)
        case .deleted(let id):
            list.removeAll { $0.id == id }
        case .userBanned(let uid, let name):
            list.removeAll { m in (uid != nil && m.userID == uid) || (name != nil && m.username.caseInsensitiveCompare(name!) == .orderedSame) }
        case .cleared:
            list.removeAll()
        }
    }

    static func selectedSendPath(preferred: ChatSendPath, web: KickWebSession, auth: AuthManager) -> ChatSendPath? {
        OAuthChatAuthorization.selected(preferred, webAvailable: web.isSignedIn, officialAvailable: auth.hasChatCredential)
    }

    func send(web: KickWebSession, auth: AuthManager, preferred: ChatSendPath) async {
        guard !isSending else { return }
        guard !isReplay else { sendError = "Chat replay is read-only."; return }
        guard let path = Self.selectedSendPath(preferred: preferred, web: web, auth: auth) else {
            sendError = "Sign in with the selected chat account. It needs permission to send messages."; return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let target else { return }
        let revision = draftRevision
        let context = sendContext
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            let submittedRevision = try await sender.send(revision: revision) {
                switch path {
                case .webSession:
                    guard let room = target.chatroomID else { throw KickAPIClient.APIError.notAuthenticated }
                    try await web.sendMessage(text, chatroomID: room, channelSlug: target.slug)
                    return true
                case .official:
                    guard let id = target.broadcasterUserID else { throw KickAPIClient.APIError.notAuthenticated }
                    let result = try await auth.sendChat(KickPostChat(broadcasterUserID: id, content: String(text.prefix(500))))
                    if !result.is_sent { throw ChatSendFailure.notSent }
                    return true
                }
            }
            if context == sendContext, submittedRevision == draftRevision { draft = "" }
        } catch {
            if context == sendContext { sendError = error.localizedDescription }
        }
    }

    private enum ChatSendFailure: LocalizedError {
        case notSent
        var errorDescription: String? { "Message not sent. Tap Send to try again." }
    }
}
