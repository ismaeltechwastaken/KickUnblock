import SwiftUI
import KickUnblockCore

struct ChannelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: PlaybackSession
    let slug: String
    @State private var detail: ChannelDetail?
    @State private var error: String?
    @State private var segment = Segment.live
    @State private var vods: [VODItem] = []
    @State private var clips: [ClipItem] = []
    @State private var clipCursor: String?
    @State private var listError: String?

    enum Segment: String, CaseIterable { case live = "Live", vods = "VODs", clips = "Clips" }

    var body: some View {
        ScrollView {
            if let d = detail {
                VStack(alignment: .leading, spacing: 16) {
                    header(d)
                    Picker("", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    switch segment {
                    case .live: liveSection(d)
                    case .vods: vodSection(d)
                    case .clips: clipSection(d)
                    }
                }
                .padding()
            } else if let error {
                ErrorBox(text: error) { Task { await load() } }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Skeleton(cornerRadius: 30).frame(width: 60, height: 60); Skeleton(cornerRadius: 4).frame(height: 18) }
                    StreamCardSkeleton()
                }.padding()
            }
        }
        .oledPage()
        .themedControlTint()
        .navigationTitle(detail?.displayName ?? slug)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: segment) { await loadSegment() }
        .onAppear { model.visibleChannel = slug }
        .onDisappear { if model.visibleChannel == slug { model.visibleChannel = nil } }
    }

    private func header(_ d: ChannelDetail) -> some View {
        HStack(spacing: 14) {
            Avatar(url: d.avatarURL, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(d.displayName).font(.title2.bold())
                if let f = d.followers { Text("\(DisplayFormat.compactCount(f)) followers").font(.caption).foregroundStyle(.kuSecondary) }
                if d.source == .official { Text("Official API").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer()
            Button {
                model.toggleFollow(slug: d.slug, id: d.broadcasterUserID, name: d.displayName, avatar: d.avatarURL?.absoluteString)
            } label: {
                Image(systemName: model.isFollowing(d.slug) ? "heart.fill" : "heart").font(.title2)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(model.isFollowing(d.slug) ? "Unfollow" : "Follow")
            Button { model.toggleSaved(d.asSaved) } label: {
                Image(systemName: model.isSaved(d.asSaved.id) ? "bookmark.fill" : "bookmark").font(.title2)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(model.isSaved(d.asSaved.id) ? "Remove from saved" : "Save")
        }
    }

    @ViewBuilder private func liveSection(_ d: ChannelDetail) -> some View {
        if d.isLive {
            Button { session.play(Play.live(d)) } label: {
                StreamCardView(card: StreamCard(id: d.slug, slug: d.slug, channelName: d.displayName, title: d.title ?? "",
                                                viewers: d.viewers, thumbnailURL: d.thumbnailURL, avatarURL: d.avatarURL,
                                                category: d.category, isMature: false, startedAt: d.startedAt ?? Date()),
                               thumbnailFallbackURLs: d.previewFallbacks.isEmpty ? [d.bannerURL].compactMap { $0 } : d.previewFallbacks)
            }.buttonStyle(.plain)
            if d.hlsURL == nil {
                Text("Using Kick's web player. The official API has no direct stream URL.")
                    .font(.caption).foregroundStyle(.kuSecondary)
            }
        } else {
            Text("\(d.displayName) is offline.").foregroundStyle(.kuSecondary).frame(maxWidth: .infinity).padding(.vertical, 30)
        }
    }

    @ViewBuilder private func vodSection(_ d: ChannelDetail) -> some View {
        if let listError { ErrorBox(text: listError) { Task { await loadSegment() } } }
        LazyVStack(spacing: 14) {
            ForEach(vods) { v in
                Button { session.play(Play.vod(v, channel: d)) } label: {
                    MediaRow(title: v.title, thumb: v.thumbnailURL, duration: v.duration,
                             subtitle: [v.startedAt.map { $0.formatted(date: .abbreviated, time: .omitted) },
                                        v.views.map { "\(DisplayFormat.compactCount($0)) views" }].compactMap { $0 }.joined(separator: " · "))
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func clipSection(_ d: ChannelDetail) -> some View {
        if let listError { ErrorBox(text: listError) { Task { await loadSegment() } } }
        LazyVStack(spacing: 14) {
            ForEach(clips) { k in
                Button { session.play(Play.clip(k, slug: d.slug, name: d.displayName, artworkURL: d.avatarURL)) } label: {
                    MediaRow(title: k.title, thumb: k.thumbnailURL, duration: k.duration,
                             subtitle: ["\(DisplayFormat.compactCount(k.views)) views", k.creator.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                }
                .buttonStyle(.plain)
                .onAppear { if k.id == clips.last?.id, clipCursor != nil { Task { await moreClips() } } }
            }
        }
    }

    private func load() async {
        do { detail = try await model.channel(slug); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func loadSegment() async {
        listError = nil
        do {
            switch segment {
            case .live: break
            case .vods: if vods.isEmpty { vods = try await model.vods(slug) }
            case .clips: if clips.isEmpty { let r = try await model.clips(slug, cursor: nil); clips = r.items; clipCursor = r.next }
            }
        } catch { listError = error.localizedDescription }
    }

    private func moreClips() async {
        guard let c = clipCursor, let r = try? await model.clips(slug, cursor: c) else { return }
        clips += r.items.filter { n in !clips.contains { $0.id == n.id } }
        clipCursor = r.next
    }
}

struct MediaRow: View {
    let title: String
    let thumb: URL?
    let duration: Double?
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: thumb)
                .frame(width: 150, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if let duration {
                        Text(formatDuration(duration)).font(.caption2.monospacedDigit()).padding(3)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(4)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.kuSecondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
