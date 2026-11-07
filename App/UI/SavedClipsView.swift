import SwiftUI
import KickUnblockCore

struct SavedClipsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: PlaybackSession
    @State private var error: String?
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error { Text(error).font(.caption).foregroundStyle(.orange).listRowBackground(Color.clear) }
                ForEach(model.saved) { item in
                    Group {
                        if item.kind == .channel {
                            NavigationLink(value: item.channelSlug) { row(item) }
                        } else {
                            Button { Task { await play(item) } } label: { row(item) }.buttonStyle(.plain)
                        }
                    }
                    .themedRows()
                    .swipeActions { Button("Remove", role: .destructive) { model.removeSaved(item.id) } }
                }
                if !downloads.files.isEmpty {
                    Section {
                        ForEach(downloads.files, id: \.self) { f in
                            HStack {
                                Label(f.lastPathComponent, systemImage: "film").lineLimit(1)
                                Spacer()
                                ShareLink(item: f) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                            }
                            .themedRows()
                            .swipeActions { Button("Delete", role: .destructive) { downloads.delete(f) } }
                        }
                    } header: { Text("Downloads") } footer: {
                        Text("MPEG-TS downloads are in Files › On My iPhone › KickUnblock. Open .ts files with VLC or another .ts player.")
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.saved.isEmpty && downloads.files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark").font(.system(size: 40)).foregroundStyle(.kuSecondary)
                        Text("Nothing saved yet").font(.headline)
                        Text("Save a video or channel here with its bookmark button.")
                            .font(.footnote).foregroundStyle(.kuSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                }
            }
            .oledPage()
            .navigationTitle("Saved Clips")
            .onAppear { downloads.refreshFiles() }
            .navigationDestination(for: String.self) { ChannelView(slug: $0) }
        }
        .modifier(ChannelRequestRoute(tab: .saved, path: $path))
    }

    private func row(_ s: SavedClip) -> some View {
        MediaRow(title: s.title, thumb: s.thumbnailURL.flatMap(URL.init(string:)), duration: s.duration,
                 subtitle: "\(s.kind.rawValue.capitalized) · \(s.channelName)")
    }

    private func play(_ s: SavedClip) async {
        error = nil
        var url = s.playbackURL.flatMap(URL.init(string:))
        if s.kind == .vod, let uuid = s.videoUUID, let fresh = try? await model.vodSource(uuid: uuid) { url = fresh }
        guard let url else { error = "No playback link for this item."; return }
        let artworkURL = ImageURLSanitizer.url(from: s.artworkURL)
        session.play(NowPlaying(kind: s.kind == .clip ? .clip : .vod, title: s.title, channelSlug: s.channelSlug,
                                channelName: s.channelName, streamURL: url, embedSlug: nil, startOffset: s.offset ?? 0,
                                thumbnailURL: s.thumbnailURL.flatMap(URL.init(string:)), artworkURL: artworkURL, chat: nil, savedItem: s, knownDuration: s.duration))
        if artworkURL == nil {
            session.resolveChannelArtwork { [model] in (try? await model.channel(s.channelSlug))?.avatarURL }
        }
    }
}
