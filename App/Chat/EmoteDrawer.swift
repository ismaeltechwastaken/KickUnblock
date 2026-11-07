import SwiftUI
import KickUnblockCore

enum EmoteDrawerTab: String, CaseIterable, Identifiable {
    case recents = "Recents", channel = "Channel", sevenTV = "7TV", global = "Kick", other = "BTTV·FFZ"
    var id: String { rawValue }
    var testID: String { self == .other ? "Other" : rawValue }
}

struct EmoteDrawer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let slug: String?
    let thirdParty: EmoteIndex
    @Binding var recents: RecentEmotes
    let onPick: (PickerEmote) -> Void
    var loadSets: ((String) async throws -> KickEmoteSets)? = nil
    @State private var tab: EmoteDrawerTab = .global
    @State private var sets: KickEmoteSets?
    @State private var loadFailed = false
    @State private var query = ""
    @State private var retry = 0
    @State private var didChooseInitialTab = false

    private var items: [PickerEmote] {
        let all: [PickerEmote]
        switch tab {
        case .recents: all = recents.items
        case .channel: all = sets?.channel ?? []
        case .sevenTV: all = thirdParty.pickerEmotes(provider: .sevenTV)
        case .global: all = sets?.global ?? []
        case .other:
            all = (thirdParty.pickerEmotes(provider: .bttv) + thirdParty.pickerEmotes(provider: .ffz))
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(visibleTabs) { option in
                        Button {
                            tab = option
                            query = ""
                        } label: {
                            Text(option.rawValue).font(.subheadline.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                                .foregroundStyle(tab == option ? ThemeReader().onAccent : Color.kuPrimary)
                                .background(tab == option ? ThemeReader().accent : ThemeReader().surface,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("emote-tab-\(option.testID)")
                        .accessibilityAddTraits(tab == option ? .isSelected : [])
                    }
                }
                TextField("Search emotes", text: $query)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("emote-search")
                ScrollView {
                    if items.isEmpty {
                        VStack(spacing: 12) {
                            Text(emptyText).font(.footnote).foregroundStyle(.kuSecondary)
                            if loadFailed && (tab == .channel || tab == .global) {
                                Button("Retry") { retry += 1 }
                            }
                        }.padding(.top, 30)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                            ForEach(items) { emote in
                                Button { onPick(emote) } label: { EmoteTile(emote: emote) }
                                    .buttonStyle(.plain)
                                    .disabled(emote.locked)
                                    .accessibilityLabel(emote.locked ? "\(emote.name), subscribers only" : emote.name)
                                    .accessibilityIdentifier("emote-item-\(emote.id)")
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding()
            .background(ThemeReader().background.ignoresSafeArea())
            .navigationTitle("Emotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .themedControlTint()
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didChooseInitialTab else { return }
            didChooseInitialTab = true
            tab = recents.items.isEmpty ? .global : .recents
        }
        .task(id: "\(slug ?? ""):\(retry)") {
            sets = nil
            loadFailed = false
            guard let slug, !slug.isEmpty else { loadFailed = true; return }
            do {
                let loaded: KickEmoteSets
                if let loadSets { loaded = try await loadSets(slug) }
                else { loaded = try await model.web.emoteSets(slug: slug) }
                guard !Task.isCancelled else { return }
                sets = loaded
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
    }

    private var visibleTabs: [EmoteDrawerTab] {
        let hasOther = !thirdParty.pickerEmotes(provider: .bttv).isEmpty || !thirdParty.pickerEmotes(provider: .ffz).isEmpty
        return EmoteDrawerTab.allCases.filter { $0 != .other || hasOther }
    }

    private var emptyText: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching emotes." }
        switch tab {
        case .recents: return "Your recent emotes appear here."
        case .channel, .global:
            if loadFailed { return "Couldn't load Kick emotes." }
            if sets == nil { return "Loading…" }
            return tab == .channel ? "This channel has no custom Kick emotes. Try Kick or 7TV." : "No Kick emotes available."
        case .sevenTV: return "No 7TV emotes loaded for this channel."
        case .other: return "No BTTV or FFZ emotes loaded."
        }
    }
}

struct EmoteTile: View {
    let emote: PickerEmote
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            if let url = emote.displayURL {
                EmoteView(name: emote.name, url: url, provider: emote.provider, height: Double(size) * 0.7, animate: false)
                    .allowsHitTesting(false)
            } else {
                Text(emote.name).font(.caption2).lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .clipped()
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if emote.locked { Image(systemName: "lock.fill").font(.system(size: 10)).padding(3) }
        }
        .opacity(emote.locked ? 0.45 : 1)
    }
}
