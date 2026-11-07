import SwiftUI
import KickUnblockCore

struct ChatView: View {
    @ObservedObject var vm: ChatViewModel
    var transparent = false
    var allowSending = false
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var web: KickWebSession
    @AppStorage(PrefKey.chatFontSize) private var fontSize = TweakDefault.fontSize
    @AppStorage(PrefKey.chatSpacing) private var spacingRaw = TweakDefault.spacing
    @AppStorage(PrefKey.chatTimestamps) private var timestamps = TweakDefault.timestamps
    @AppStorage(PrefKey.animateEmotes) private var animateEmotes = TweakDefault.animateEmotes
    @AppStorage(PrefKey.highlightOwnMessages) private var highlightOwn = true
    @ObservedObject private var energy = EnergyMonitor.shared
    @State private var pinned = true
    private enum ComposerSheet: Identifiable {
        case web(WebTarget), emotes
        var id: String {
            switch self { case .web(let target): "web-\(target.url.absoluteString)"; case .emotes: "emotes" }
        }
    }
    @State private var composerSheet: ComposerSheet?
    @FocusState private var composerFocused: Bool
    @State private var recents = RecentEmotes.load()

    @AppStorage(PrefKey.chatSendPath) private var sendPathRaw = ChatSendPath.webSession.rawValue
    private var preferredSendPath: ChatSendPath { ChatSendPath(rawValue: sendPathRaw) ?? .webSession }
    private var selectedSendPath: ChatSendPath? {
        ChatViewModel.selectedSendPath(preferred: preferredSendPath, web: web, auth: auth)
    }
    private var myName: String? {
        switch selectedSendPath {
        case .webSession: return web.username
        case .official: return auth.username
        case nil: return nil
        }
    }

    private var spacing: ChatSpacing { ChatSpacing(rawValue: spacingRaw) ?? .comfortable }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.messages) { m in
                            let style = vm.cosmetics.style(for: m.userID)
                            ChatRow(message: m, fontSize: ChatFontSize.clamp(fontSize), timestamps: timestamps, replayStart: vm.replayStartedAt,
                                    animateEmotes: animateEmotes && !energy.constrained,
                                    subBadges: vm.subBadges, badgeImages: vm.badgeImages,
                                    style: style, sevenTVBadge: style?.badge.flatMap { vm.cosmeticBadgeImages[$0.id] },
                                    onBlock: isOwn(m) ? nil : { vm.block(user: $0) })
                                .padding(.vertical, spacing.rowPadding)
                                .padding(.horizontal, 10)
                                .background(isOwn(m) ? ThemeReader().accent.opacity(0.12) : Color.clear)
                                .id(m.id)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: vm.messages.last?.id) { _, id in
                    if pinned, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .simultaneousGesture(DragGesture().onChanged { _ in pinned = false })
                .overlay(alignment: .bottom) {
                    if !pinned {
                        Button { pinned = true; if let id = vm.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } } label: {
                            Label("Resume", systemImage: "arrow.down").font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }.padding(8)
                    }
                }
            }
            if allowSending && !vm.isReplay && selectedSendPath != nil { composer }
        }
        .background(transparent ? Color.clear : ThemeReader().background)
        .themedControlTint()
        .sheet(item: $composerSheet) { sheet in
            switch sheet {
            case .web(let target):
                KickWebSheet(title: "kick.com", url: target.url).environmentObject(web)
                    .themedControlTint()
            case .emotes:
                EmoteDrawer(slug: vm.channelSlug, thirdParty: vm.thirdPartyEmotes, recents: $recents) { insert($0) }
                    .environmentObject(model)
                    .presentationDetents([.fraction(0.45), .large])
                    .presentationDragIndicator(.visible)
                    .compatPresentationBackground(ThemeReader().background)
            }
        }
    }

    @ViewBuilder private var statusBar: some View {
        switch vm.status {
        case .connecting: Text("Connecting to chat…").font(.caption2).foregroundStyle(.kuSecondary).padding(4)
        case .failed(let e): Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(2).padding(4)
        default: EmptyView()
        }
    }

    private func isOwn(_ m: ChatMessage) -> Bool {
        guard highlightOwn, let me = myName, !m.isSystem else { return false }
        return m.username.caseInsensitiveCompare(me) == .orderedSame
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = vm.sendError {
                Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                if let u = web.lastError?.webViewURL {
                    Button("Open in web view") { composerSheet = .web(WebTarget(url: u)) }.font(.caption2.weight(.semibold))
                }
            }
            if !recents.quick.isEmpty { quickEmotes }
            HStack(spacing: 8) {
                identityButton
                TextField("Send a message", text: $vm.draft).textFieldStyle(.roundedBorder).submitLabel(.send)
                    .focused($composerFocused)
                    .onSubmit { sendDraft() }
                HStack(spacing: 0) {
                    Button { composerFocused = false; composerSheet = .emotes } label: {
                        Image(systemName: "face.smiling.inverse")
                            .frame(width: 38, height: 44).contentShape(Rectangle())
                    }
                        .accessibilityLabel("Emotes")
                        .accessibilityIdentifier("chat-emotes")
                    Button { sendDraft() } label: {
                        Image(systemName: "paperplane.fill")
                            .frame(width: 38, height: 44).contentShape(Rectangle())
                    }
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("chat-send")
                        .disabled(vm.isSending || vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .buttonStyle(.plain)
                .foregroundStyle(ThemeReader().accentText)
            }
        }
        .padding(8)
    }

    private var quickEmotes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(recents.quick) { e in
                    Button { insert(e) } label: { EmoteTile(emote: e, size: 34) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(e.name)
                }
            }
        }
    }

    private var identityButton: some View {
        Menu {
            if let me = myName { Text("Chatting as \(me)") }
            Toggle("Highlight my messages", isOn: $highlightOwn)
            Button { composerSheet = .web(WebTarget(url: KickAccountEndpoint.chatSettingsPage)) } label: {
                Label("Name color and badges on kick.com", systemImage: "paintpalette")
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(ThemeReader().accent)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(ThemeReader().onAccent, ThemeReader().accent)
                    .background(Circle().fill(ThemeReader().background).padding(-1.5))
                    .opacity(highlightOwn ? 1 : 0)
            }
        }
        .accessibilityLabel("Chat identity")
    }

    private func insert(_ e: PickerEmote) {
        guard !e.locked else { return }
        vm.draft = PickerEmote.insert(e, into: vm.draft)
        recents.record(e)
        recents.save()
    }

    private func sendDraft() {
        guard !vm.isSending else { return }
        web.lastError = nil
        let path = preferredSendPath
        Task { await vm.send(web: web, auth: auth, preferred: path) }
    }
}

struct ChatRow: View {
    let message: ChatMessage
    let fontSize: Double
    let timestamps: Bool
    var replayStart: Date?
    var animateEmotes = true
    var subBadges: SubscriberBadgeSet = .empty
    var badgeImages: [URL: UIImage] = [:]
    var style: ChatUserStyle?
    var sevenTVBadge: UIImage?
    var onBlock: ((String) -> Void)?
    @ScaledMetric(relativeTo: .body) private var scaledBodyReference = 17.0
    @State private var images: [URL: UIImage] = [:]
    @State private var showBadgeInfo = false

    private var metrics: ChatAccessibilityMetrics {
        ChatAccessibilityMetrics(baseFontSize: fontSize, bodyScale: scaledBodyReference / 17)
    }

    private var hasEmotes: Bool {
        message.segments.contains { if case .text = $0 { return false } else { return true } }
    }

    var body: some View {
        if message.isSystem {
            Text(message.plainText)
                .font(.system(size: metrics.messageFontSize, weight: .semibold))
                .foregroundStyle(ThemeReader().accent)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(ThemeReader().accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let reply = message.replySegments {
                    replyLine(reply)
                }
                if animateEmotes && hasEmotes {
                    flowLine
                } else {
                    composed.font(.system(size: metrics.messageFontSize)).fixedSize(horizontal: false, vertical: true)
                        .task(id: message.segments) { await loadStills() }
                }
                if showBadgeInfo && !message.badges.isEmpty {
                    Text(message.badges.map(ChatBadgeText.describe).joined(separator: " · "))
                        .font(.system(size: metrics.badgeInfoFontSize, weight: .medium))
                        .foregroundStyle(.kuSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !message.badges.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.15)) { showBadgeInfo.toggle() }
            }
            .contextMenu {
                if let onBlock {
                    Button(role: .destructive) { onBlock(message.username) } label: {
                        Label("Block \(message.username)", systemImage: "nosign")
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAction(named: "Block \(message.username)") { onBlock?(message.username) }
        }
    }

    private var accessibilityText: String {
        let who = "\(message.username): \(message.plainText)"
        let badges = [ChatBadgeText.accessibility(message.badges), style?.badge?.tooltip].compactMap { $0 }
        return badges.isEmpty ? who : "\(badges.joined(separator: ", ")). \(who)"
    }

    private func badgeImage(_ b: KickChatEvent.Badge) -> UIImage {
        let kind = ChatBadgeKind(type: b.type)
        let h = metrics.badgeHeight
        if kind == .subscriber, let url = subBadges.badge(forMonths: b.count)?.imageURL, let img = badgeImages[url] {
            return img.scaled(toHeight: h)
        }
        return BadgeArt.image(kind, size: h)
    }

    private var nameColor: Color { readableNameColor(message.colorHex) ?? .accentColor }

    private var header: Text {
        var t = Text("")
        if timestamps {
            let stamp = replayStart.map { ChatTimestamp.streamTime(message.sentAt, since: $0) } ?? ChatTimestamp.format(message.sentAt)
            t = t + Text(stamp + " ").foregroundColor(Color.kuSecondary)
        }
        for b in message.badges.prefix(4) {
            t = t + Text(Image(uiImage: badgeImage(b))).baselineOffset(-metrics.messageFontSize * 0.18) + Text(" ")
        }
        if let img = sevenTVBadge {
            t = t + Text(Image(uiImage: img.scaled(toHeight: metrics.badgeHeight))).baselineOffset(-metrics.messageFontSize * 0.18) + Text(" ")
        }
        return t + nameText + Text(":")
    }

    private var nameText: Text {
        let letters = Array(message.username)
        guard let colors = style?.paint?.nameColors(count: letters.count), colors.count == letters.count else {
            return Text(message.username).bold().foregroundColor(nameColor)
        }
        return zip(letters, colors).reduce(Text("")) { $0 + Text(String($1.0)).bold().foregroundColor(Color(hex: $1.1)) }
    }

    private var composed: Text {
        var t = header + Text(" ")
        for piece in ChatSegment.stacked(message.segments) {
            switch piece {
            case .text(let s): t = t + Text(s)
            case .emote(let base, let overlays):
                if let img = still(base, overlays, height: metrics.emoteHeight) {
                    t = t + Text(Image(uiImage: img))
                } else {
                    t = t + Text(([base] + overlays).map(\.name).joined(separator: " ")).foregroundColor(Color.kuSecondary)
                }
            }
        }
        return t
    }

    private func still(_ base: ChatEmote, _ overlays: [ChatEmote], height h: Double) -> UIImage? {
        guard let bottom = images[base.url] else { return nil }
        let layers = ([bottom] + overlays.compactMap { images[$0.url] }).map { $0.scaled(toHeight: h) }
        guard layers.count > 1 else { return layers[0] }
        let w = layers.map(\.size.width).max() ?? 0
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            for img in layers { img.draw(in: CGRect(x: (w - img.size.width) / 2, y: 0, width: img.size.width, height: h)) }
        }
    }

    private enum Token: Identifiable {
        case word(Int, String)
        case emote(Int, ChatEmote, [ChatEmote])
        var id: Int { switch self { case .word(let i, _), .emote(let i, _, _): i } }
    }

    private var tokens: [Token] {
        var out: [Token] = []
        for piece in ChatSegment.stacked(message.segments) {
            switch piece {
            case .text(let s):
                for w in s.split(separator: " ", omittingEmptySubsequences: true) { out.append(.word(out.count, String(w))) }
            case .emote(let base, let overlays):
                out.append(.emote(out.count, base, overlays))
            }
        }
        return out
    }

    private var flowLine: some View {
        FlowLayout(spacing: metrics.messageFontSize * 0.28, lineSpacing: 2) {
            header
            ForEach(tokens) { token in
                switch token {
                case .word(_, let w): Text(w)
                case .emote(_, let base, let overlays):
                    ZStack {
                        EmoteView(name: base.name, url: base.url, provider: base.provider, height: metrics.emoteHeight, animate: true)
                        ForEach(overlays, id: \.self) { top in
                            EmoteView(name: top.name, url: top.url, provider: top.provider, height: metrics.emoteHeight, animate: true)
                        }
                    }
                }
            }
        }
        .font(.system(size: metrics.messageFontSize))
    }

    private var replyFontSize: Double { metrics.replyFontSize }

    private func replyLine(_ reply: [ChatSegment]) -> some View {
        let lineHeight = UIFont.systemFont(ofSize: replyFontSize).lineHeight
        var t = Text("")
        for piece in ChatSegment.stacked(reply) {
            switch piece {
            case .text(let s): t = t + Text(s)
            case .emote(let base, let overlays):
                if let img = still(base, overlays, height: lineHeight) {
                    t = t + Text(Image(uiImage: img)).baselineOffset(-replyFontSize * 0.2)
                } else {
                    t = t + Text(([base] + overlays).map(\.name).joined(separator: " "))
                }
            }
        }
        return t.font(.system(size: replyFontSize)).foregroundStyle(.kuSecondary)
            .lineLimit(1).truncationMode(.tail)
            .task(id: reply) { await loadStills(reply) }
    }

    private func loadStills(_ segments: [ChatSegment]) async {
        for seg in segments {
            switch seg {
            case .text: continue
            case .emote(_, let url, let provider), .overlay(_, let url, let provider):
                if images[url] == nil, let img = await EmoteDataCache.shared.image(for: url, provider: provider) {
                    images[url] = img
                }
            }
        }
    }

    private func loadStills() async { await loadStills(message.segments) }
}

extension UIImage {
    func scaled(toHeight h: Double) -> UIImage {
        guard size.height > 0 else { return self }
        let w = size.width * h / size.height
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in draw(in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }
}
