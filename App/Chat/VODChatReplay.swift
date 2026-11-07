import SwiftUI
import KickUnblockCore

struct VODChatReplayTarget: Equatable {
    let context: VODReplayContext
    let chat: ChatTarget

    static func make(vod v: VODItem, channel c: ChannelDetail) -> VODChatReplayTarget? {
        guard let channelID = c.channelID, let start = v.startedAt, let duration = v.duration,
              let context = try? VODReplayContext(channelID: channelID, startedAt: start, duration: duration) else { return nil }
        return VODChatReplayTarget(context: context,
                                   chat: ChatTarget(channelID: channelID, chatroomID: nil,
                                                    broadcasterUserID: c.broadcasterUserID, slug: c.slug))
    }
}

@MainActor
final class VODChatReplay: ObservableObject {
    private var controller: VODReplayController?
    private var target: VODChatReplayTarget?
    private weak var vm: ChatViewModel?
    private let http = VODReplayHTTP.anonymous()

    func start(_ t: VODChatReplayTarget, vm: ChatViewModel, globalEmotes: EmoteIndex, at time: Double) async {
        guard target != t || self.vm !== vm else { return }
        stop()
        target = t
        self.vm = vm
        vm.beginReplay(t.chat, startedAt: t.context.startedAt, globalEmotes: globalEmotes)
        let c = VODReplayController(context: t.context, client: http.client)
        c.onChange = { [weak vm] snapshot in vm?.showReplay(snapshot) }
        controller = c
        await c.seek(to: time)
    }

    func update(to time: Double) { controller?.update(to: time) }

    func stop() {
        controller?.onChange = nil
        controller?.stop()
        controller = nil
        target = nil
        vm?.endReplay()
        vm = nil
    }
}

struct VODChatReplayDriver: ViewModifier {
    @EnvironmentObject private var session: PlaybackSession
    let vm: ChatViewModel
    let globalEmotes: EmoteIndex
    @StateObject private var replay = VODChatReplay()

    func body(content: Content) -> some View {
        content
            .task(id: session.nowPlaying?.vodReplay) {
                if let t = session.nowPlaying?.vodReplay, session.nowPlaying?.kind == .vod {
                    await replay.start(t, vm: vm, globalEmotes: globalEmotes, at: session.currentTime)
                } else {
                    replay.stop()
                }
            }
            .onChange(of: session.currentTime) { _, t in
                guard session.nowPlaying?.kind == .vod, !session.isScrubbing else { return }
                replay.update(to: t)
            }
            .onDisappear { replay.stop() }
    }
}

extension View {
    func vodChatReplay(vm: ChatViewModel, globalEmotes: EmoteIndex) -> some View {
        modifier(VODChatReplayDriver(vm: vm, globalEmotes: globalEmotes))
    }
}
