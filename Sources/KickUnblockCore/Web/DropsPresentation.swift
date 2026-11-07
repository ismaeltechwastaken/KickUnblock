import Foundation

public struct DropsScreenSnapshot: Equatable, Sendable {
    public struct Header: Equatable, Sendable {
        public let title: String
        public let statusText: String
        public let isActive: Bool
        public let logoURL: URL?
    }

    public struct Details: Equatable, Sendable {
        public let category: String?
        public let endsText: String?
        public let ruleText: String?
        public let channelsText: String?
    }

    public struct Reward: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case none, claim, claimed }
        public let name: String
        public let imageURL: URL?
        public let fraction: Double?
        public let caption: String?
        public let action: Action
    }

    public enum Content: Equatable, Sendable {
        case details(Details)
        case reward(Reward)
        case connect(URL)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let content: Content
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let id: String
        public let header: Header
        public let rows: [Row]
    }

    struct Block: Equatable, Sendable {
        let id: String
        let isActive: Bool
        let header: Header
        let details: Details
        let rewards: [DropsCampaign.Reward]
        let connectURL: URL?
    }

    let blocks: [Block]
    public let progress: DropsProgress
    public let activeSections: [Section]
    public let allSections: [Section]

    public static let empty = DropsScreenSnapshot(campaigns: [])

    public init(campaigns: [DropsCampaign], progress: DropsProgress = DropsProgress(),
                formatEnd: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var seen = Set<String>()
        var blocks: [Block] = []
        blocks.reserveCapacity(campaigns.count)
        for c in campaigns where seen.insert(c.id).inserted {
            let end = c.ends_at.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) }
            blocks.append(Self.block(c, endsText: end.map { "Ends " + formatEnd($0) }))
        }
        self.init(blocks: blocks, progress: progress)
    }

    init(blocks: [Block], progress: DropsProgress) {
        self.blocks = blocks
        self.progress = progress
        let all = blocks.map { Self.section($0, progress: progress) }
        self.allSections = all
        self.activeSections = zip(blocks, all).filter { $0.0.isActive }.map(\.1)
    }

    public func applying(progress: DropsProgress) -> DropsScreenSnapshot {
        progress == self.progress ? self : DropsScreenSnapshot(blocks: blocks, progress: progress)
    }

    public func sections(activeOnly: Bool) -> [Section] { activeOnly ? activeSections : allSections }

    public func rows(activeOnly: Bool) -> [Row] { sections(activeOnly: activeOnly).flatMap(\.rows) }

    // MARK: Building

    static func block(_ c: DropsCampaign, endsText: String?) -> Block {
        let isActive = c.isActive
        let status = isActive ? "Active" : (c.status ?? "").capitalized
        let header = Header(title: c.name, statusText: status, isActive: isActive,
                            logoURL: ImageURLSanitizer.url(from: c.organization?.logo_url, base: nil))
        let slugs = (c.channels ?? []).compactMap(\.slug).filter { !$0.isEmpty }
        let channels = slugs.isEmpty ? nil
            : "Channels: " + slugs.prefix(6).joined(separator: ", ") + (slugs.count > 6 ? " +\(slugs.count - 6)" : "")
        let details = Details(category: c.category?.name.flatMap(nonEmpty), endsText: endsText,
                              ruleText: c.rule?.name.flatMap(nonEmpty), channelsText: channels)
        var rewardIDs = Set<String>()
        let rewards = (c.rewards ?? []).filter { rewardIDs.insert($0.id).inserted }
        var connect: URL?
        if isActive, let s = c.connect_url, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           scheme == "https" || scheme == "http", u.host != nil { connect = u }
        return Block(id: c.id, isActive: isActive, header: header, details: details, rewards: rewards, connectURL: connect)
    }

    static func section(_ b: Block, progress: DropsProgress) -> Section {
        var rows: [Row] = [Row(id: b.id + "/details", content: .details(b.details))]
        rows.reserveCapacity(b.rewards.count + 2)
        for r in b.rewards {
            rows.append(Row(id: b.id + "/reward/" + r.id,
                            content: .reward(reward(r, progress: progress.byReward[r.id], campaignActive: b.isActive))))
        }
        if let u = b.connectURL { rows.append(Row(id: b.id + "/connect", content: .connect(u))) }
        return Section(id: b.id, header: b.header, rows: rows)
    }

    static func reward(_ r: DropsCampaign.Reward, progress p: DropsProgress.Item?, campaignActive: Bool) -> Reward {
        let need = max(1, r.required_units ?? 0)
        let fraction: Double?
        let caption: String?
        if let p {
            let done = min(max(0, p.units), need)
            fraction = Double(done) / Double(need)
            caption = "\(done)/\(need) min"
        } else {
            fraction = nil
            caption = r.required_units.map { "Watch \($0) min" }
        }
        let action: Reward.Action
        if p?.claimed == true { action = .claimed }
        else if let p, p.units >= need, campaignActive { action = .claim }
        else { action = .none }
        return Reward(name: r.name.flatMap(nonEmpty) ?? "Reward", imageURL: r.imageURL,
                      fraction: fraction, caption: caption, action: action)
    }
}

private func nonEmpty(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}
