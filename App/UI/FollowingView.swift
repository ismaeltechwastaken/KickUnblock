import SwiftUI
import KickUnblockCore

struct FollowingView: View {
    @EnvironmentObject var model: AppModel
    @State private var details: [String: ChannelDetail] = [:]
    @State private var loading = false
    @State private var showAdd = false
    @State private var path = NavigationPath()

    private var live: [FollowedChannel] { model.followed.filter { details[$0.slug]?.isLive == true } }
    private var offline: [FollowedChannel] { model.followed.filter { details[$0.slug]?.isLive != true } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.followed.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "heart").font(.largeTitle).foregroundStyle(.kuSecondary)
                            Text("Follow channels to see who's live.").foregroundStyle(.kuSecondary)
                            Button("Find channels") { showAdd = true }.buttonStyle(AccentButtonStyle())
                        }
                        .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    if loading && details.isEmpty {
                        ForEach((0..<min(3, model.followed.count)).map(GridSlot.skeleton), id: \.self) { _ in StreamCardSkeleton() }
                    }
                    if !live.isEmpty {
                        Text("Live").font(.title3.bold())
                        ForEach(live) { f in
                            if let d = details[f.slug] {
                                NavigationLink(value: f.slug) { StreamCardView(card: card(d)) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !offline.isEmpty {
                        Text("Offline").font(.title3.bold()).padding(.top, 6)
                        ForEach(offline) { f in
                            NavigationLink(value: f.slug) {
                                HStack(spacing: 12) {
                                    Avatar(url: (details[f.slug]?.avatarURL) ?? f.avatarURL.flatMap(URL.init(string:)), size: 40)
                                    Text(f.displayName).font(.body.weight(.medium))
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.kuTertiary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .refreshable { await refresh() }
            .oledPage()
            .navigationTitle("Following")
            .navigationDestination(for: String.self) { ChannelView(slug: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { KickUnblockWordmark(height: 15) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Find channels")
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    SearchView(onPick: { _ in showAdd = false })
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAdd = false } } }
                }
                .themedControlTint()
            }
            .task(id: model.followed.map(\.slug)) { await refresh() }
        }
        .modifier(ChannelRequestRoute(tab: .following, path: $path))
    }

    private func card(_ d: ChannelDetail) -> StreamCard {
        StreamCard(id: d.slug, slug: d.slug, channelName: d.displayName, title: d.title ?? "", viewers: d.viewers,
                   thumbnailURL: d.thumbnailURL, avatarURL: d.avatarURL, category: d.category, isMature: false,
                   startedAt: d.startedAt ?? Date())
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (String, ChannelDetail?).self) { g in
            for f in model.followed {
                g.addTask { @MainActor in (f.slug, try? await model.channel(f.slug)) }
            }
            for await (slug, d) in g { if let d { details[slug] = d } }
        }
    }
}

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    var onPick: ((String) -> Void)?
    @State private var query = ""
    @State private var results: [StreamCard] = []
    @State private var error: String?
    @State private var searched: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.kuSecondary) }
            ForEach(results) { r in
                HStack(spacing: 12) {
                    Avatar(url: r.avatarURL, size: 40)
                    NavigationLink(value: r.slug) {
                        VStack(alignment: .leading) {
                            Text(r.channelName).font(.body.weight(.semibold))
                            Text(r.title).font(.caption).foregroundStyle(.kuSecondary)
                        }
                    }
                    let following = model.isFollowing(r.slug)
                    Button {
                        model.toggleFollow(slug: r.slug, id: nil, name: r.channelName, avatar: r.avatarURL?.absoluteString)
                    } label: {
                        Image(systemName: following ? "heart.fill" : "heart")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(following ? "Unfollow \(r.channelName)" : "Follow \(r.channelName)")
                }
                .themedRows()
            }
        }
        .listStyle(.plain)
        .oledPage()
        .navigationTitle("Search")
        .overlay { emptyState }
        .modifier(ChannelDestination(enabled: onPick != nil))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Channel name")
        .task(id: query) {
            searched = nil
            guard let q = ChannelSearch.query(query) else { results = []; error = nil; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await model.search(q)
                guard !Task.isCancelled else { return }
                results = found; error = nil; searched = q
            } catch {
                guard !Task.isCancelled, !ChannelSearch.isQuiet(error) else { return }
                self.error = "Search is unavailable. Try again soon."
            }
        }
    }
}

extension SearchView {
    @ViewBuilder fileprivate var emptyState: some View {
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if error == nil, results.isEmpty, typed {
            if ChannelSearch.query(query) == nil {
                ContentUnavailableView("Keep typing", systemImage: "magnifyingglass",
                                       description: Text("Type at least \(ChannelSearch.minimumLength) letters to search."))
            } else if let searched, searched == ChannelSearch.query(query) {
                ContentUnavailableView.search(text: searched)
            }
        }
    }
}

struct ChannelDestination: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.navigationDestination(for: String.self) { ChannelView(slug: $0) } } else { content }
    }
}
