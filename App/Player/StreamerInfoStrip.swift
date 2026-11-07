import SwiftUI
import KickUnblockCore

struct StreamerInfoStrip: View {
    @EnvironmentObject var model: AppModel
    let slug: String
    let fallbackName: String
    let fallbackTitle: String
    var isLive = true
    var openChannel: () -> Void = {}
    @AppStorage("kickunblock.player.infoCollapsed") private var collapsed = false
    @State private var detail: ChannelDetail?
    private let theme = ThemeReader()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: collapsed ? .center : .top, spacing: 12) {
                Button(action: openChannel) { channelSummary }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the channel page")
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    followButton
                    circleButton(collapsed ? "chevron.down" : "chevron.up",
                                 label: collapsed ? "Show stream info" : "Hide stream info") {
                        withAnimation(.snappy) { collapsed.toggle() }
                    }
                }
            }
            if isLive, !collapsed, detail != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let c = detail?.category { chip(c) }
                        if let l = detail?.language, !l.isEmpty { chip(l) }
                        if let v = detail?.viewers { chip(DisplayFormat.compactCount(v), systemImage: "eye") }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
        .task(id: slug) { detail = try? await model.channel(slug) }
    }

    private var channelSummary: some View {
        HStack(alignment: collapsed ? .center : .top, spacing: 12) {
            LiveRingAvatar(url: detail?.avatarURL, size: collapsed ? 32 : 52, isLive: isLive && (detail?.isLive ?? true))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(detail?.displayName ?? fallbackName)
                        .font(collapsed ? .subheadline.weight(.bold) : .title3.weight(.bold))
                        .lineLimit(1)
                    if detail?.verified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(collapsed ? .caption : .subheadline)
                            .foregroundStyle(Color(hex: Contrast.liveBadgeHex))
                            .accessibilityLabel("Verified")
                    }
                }
                if !collapsed {
                    let title = isLive ? (detail?.title ?? fallbackTitle) : fallbackTitle
                    if !title.isEmpty {
                        Text(title).font(.footnote).foregroundStyle(.kuSecondary).lineLimit(2)
                    }
                } else if isLive, let v = detail?.viewers {
                    Text("\(DisplayFormat.compactCount(v)) watching").font(.caption2).foregroundStyle(.kuSecondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var followButton: some View {
        let following = model.isFollowing(slug)
        return circleButton(following ? "heart.fill" : "heart", label: following ? "Unfollow" : "Follow",
                            tint: following ? Color(hex: Contrast.liveBadgeHex) : .white) {
            model.toggleFollow(slug: slug, id: detail?.channelID, name: detail?.displayName ?? fallbackName,
                               avatar: detail?.avatarURL?.absoluteString)
        }
    }

    private func circleButton(_ symbol: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.1), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func chip(_ text: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.footnote.weight(.semibold)).lineLimit(1).fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.1), in: Capsule())
    }
}

struct LiveRingAvatar: View {
    let url: URL?
    let size: CGFloat
    var isLive = true
    var body: some View {
        Avatar(url: url, size: size)
            .padding(isLive ? 3 : 0)
            .overlay { if isLive { Circle().strokeBorder(Color(hex: Contrast.liveBadgeHex), lineWidth: 2) } }
            .accessibilityLabel(isLive ? "Live" : "")
    }
}
