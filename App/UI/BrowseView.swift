import SwiftUI
import KickUnblockCore

struct BrowseView: View {
    @EnvironmentObject var model: AppModel
    @State private var categories: [CategoryCard] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var loadedOnce = false
    @State private var showingSeeds = false
    @State private var generation = 0
    @State private var path = NavigationPath()

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                NavigationLink(value: BrowseRoute.allLive) {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("All live channels").font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.kuTertiary)
                    }
                    .padding().background(ThemeReader().surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(cells) { cell in
                        switch cell {
                        case .category(let c):
                            NavigationLink(value: BrowseRoute.category(c)) { CategoryTile(category: c) }
                                .buttonStyle(.plain)
                                .onAppear { if c.id == categories.last?.id { Task { await loadMore() } } }
                        case .skeleton:
                            VStack(alignment: .leading) { Skeleton().aspectRatio(3 / 4, contentMode: .fit); Skeleton(cornerRadius: 4).frame(height: 10) }
                        }
                    }
                }
                .padding()
                if categories.isEmpty {
                    FeedStateView(phase: FeedPhase.resolve(visible: 0, total: 0, loading: loading || !loadedOnce, error: error),
                                  emptyTitle: "No categories", emptyMessage: "Kick didn't return any categories.") { Task { await reload() } }
                } else if let error {
                    ErrorBox(text: showingSeeds ? "kick.com's list didn't load. Showing popular categories. \(error)" : error) { Task { await retryMore() } }
                }
            }
            .refreshable { await reload() }
            .oledPage()
            .navigationTitle("Browse")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { KickUnblockWordmark(height: 15) }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: BrowseRoute.search) { Image(systemName: "magnifyingglass") }
                }
            }
            .navigationDestination(for: BrowseRoute.self) { r in
                switch r {
                case .allLive: CategoryStreamsView(category: nil)
                case .category(let c): CategoryStreamsView(category: c)
                case .search: SearchView()
                }
            }
            .navigationDestination(for: String.self) { ChannelView(slug: $0) }
            .task { if categories.isEmpty || showingSeeds { await reload() } }
            .task(id: generation) {
                let start = Date()
                try? await Task.sleep(nanoseconds: UInt64(BrowseGrid.placeholderDeadline * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if BrowseGrid.showsFallback(loadedCount: categories.count, elapsed: Date().timeIntervalSince(start), failed: false) { showSeeds() }
            }
        }
        .modifier(ChannelRequestRoute(tab: .browse, path: $path))
    }

    private var cells: [BrowseCell] {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return BrowseGrid.slots(categoryIDs: categories.map(\.id), loading: loading || !loadedOnce).compactMap { slot in
            switch slot {
            case .category(let id): byID[id].map(BrowseCell.category)
            case .skeleton(let i): .skeleton(i)
            }
        }
    }

    private func showSeeds() {
        guard categories.isEmpty else { return }
        categories = CategorySeed.top.map { CategoryCard(id: $0.id, name: $0.name, viewers: nil, imageURLs: [], slug: $0.slug) }
        showingSeeds = true
    }

    private func reload() async { page = 1; hasMore = true; categories = []; showingSeeds = false; error = nil; generation += 1; await loadMore() }
    private func retryMore() async { hasMore = true; error = nil; await loadMore() }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true; defer { loading = false }
        let model = self.model, page = self.page
        do {
            let r = try await Deadline.run(seconds: Deadline.list) { try await model.categories(page: page) }
            if showingSeeds, !r.items.isEmpty { categories = []; showingSeeds = false }
            categories += r.items.filter { n in !categories.contains { $0.id == n.id } }
            hasMore = r.hasMore && !r.items.isEmpty; self.page += 1; error = nil
            loadedOnce = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription; hasMore = false; loadedOnce = true
            if page == 1 { showSeeds() }
        }
    }
}

enum BrowseCell: Identifiable {
    case category(CategoryCard)
    case skeleton(Int)
    var id: GridSlot {
        switch self {
        case .category(let c): .category(c.id)
        case .skeleton(let i): .skeleton(i)
        }
    }
}

enum BrowseRoute: Hashable {
    case allLive, search
    case category(CategoryCard)
}

struct CategoryTile: View {
    let category: CategoryCard
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(RemoteImage(urls: category.imageURLs) { CategoryPlaceholder(category: category) })
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(category.name).font(.caption.weight(.semibold)).lineLimit(1)
            if let v = category.viewers { Text("\(DisplayFormat.compactCount(v)) watching").font(.caption2).foregroundStyle(.kuSecondary) }
        }
    }
}

struct CategoryStreamsView: View {
    @EnvironmentObject var model: AppModel
    let category: CategoryCard?
    @AppStorage(PrefKey.hideMature) private var hideMature = TweakDefault.hideMature
    @State private var streams: [StreamCard] = []
    @State private var cursor: String?
    @State private var done = false
    @State private var loading = false
    @State private var error: String?
    @State private var loadedOnce = false
    @State private var showWeb = false

    private var visible: [StreamCard] { streams.filter { !(hideMature && $0.isMature) } }

    var body: some View {
        let shown = visible
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(shown) { s in
                    NavigationLink(value: s.slug) { StreamCardView(card: s) }
                        .buttonStyle(.plain)
                        .onAppear { if s.id == shown.last?.id { Task { await loadMore() } } }
                }
                let phase = FeedPhase.resolve(visible: shown.count, total: streams.count, loading: loading || !loadedOnce, error: error)
                if phase == .loading { ForEach((0..<4).map(GridSlot.skeleton), id: \.self) { _ in StreamCardSkeleton() } }
                FeedStateView(phase: phase, openOnWeb: webPage == nil ? nil : { showWeb = true }) { Task { await reload() } }
                if phase == .content, let error { ErrorBox(text: error) { Task { await retryMore() } } }
                if phase != .content, !done, !loading, loadedOnce, error == nil, !streams.isEmpty {
                    Color.clear.frame(height: 1).onAppear { Task { await loadMore() } }
                }
            }
            .padding()
        }
        .refreshable { await reload() }
        .oledPage()
        .navigationTitle(category?.name ?? "Live")
        .task { if streams.isEmpty { await reload() } }
        .sheet(isPresented: $showWeb) {
            if let webPage { KickWebSheet(title: category?.name ?? "kick.com", url: webPage).environmentObject(model.webSession).themedControlTint() }
        }
    }

    private var webPage: URL? { category?.slug.map(CategorySeed.webPage(slug:)) }

    private func reload() async { streams = []; cursor = nil; done = false; error = nil; await loadMore() }
    private func retryMore() async { done = false; error = nil; await loadMore() }

    private func loadMore() async {
        guard !done, !loading else { return }
        loading = true; defer { loading = false }
        let model = self.model, category = self.category, cursor = self.cursor
        do {
            let r = try await Deadline.run(seconds: Deadline.list) { try await model.liveStreams(category: category, cursor: cursor) }
            streams += r.items.filter { n in !streams.contains { $0.id == n.id } }
            self.cursor = r.next; done = r.next == nil || r.items.isEmpty; error = nil
            loadedOnce = true
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription; done = true; loadedOnce = true }
    }
}

struct CategoryPlaceholder: View {
    let category: CategoryCard
    var body: some View {
        let g = CategoryArt.gradientHex(seed: CategoryArt.seed(id: category.id, name: category.name))
        ZStack {
            LinearGradient(colors: [Color(hex: g.top), Color(hex: g.bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                if let s = category.symbol { Text(s).font(.system(size: 30)) }
                Text(category.name)
                    .font(.footnote.weight(.bold)).multilineTextAlignment(.center)
                    .foregroundStyle(.white).lineLimit(3).minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
            }
        }
    }
}
