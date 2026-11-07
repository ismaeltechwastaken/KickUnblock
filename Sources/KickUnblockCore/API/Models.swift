import Foundation

public struct KickEnvelope<T: Decodable>: Decodable {
    public let data: T
    public let message: String?
}

public struct KickPage<T: Decodable>: Decodable {
    public let data: [T]
    public let message: String?
    public let pagination: Pagination?
    public struct Pagination: Decodable { public let next_cursor: String? }
}

public struct KickChannel: Decodable, Hashable, Identifiable {
    public var id: Int { broadcaster_user_id }
    public let broadcaster_user_id: Int
    public let slug: String
    public let stream_title: String?
    public let banner_picture: String?
    public let category: KickCategory?
    public let stream: KickStream?
    public let active_subscribers_count: Int?
    public let active_gifted_subscribers_count: Int?
}

public struct KickStream: Decodable, Hashable {
    public let is_live: Bool?
    public let is_mature: Bool?
    public let language: String?
    public let start_time: String?
    public let thumbnail: String?
    public let viewer_count: Int?
}

public struct KickCategory: Decodable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let thumbnail: String?
    public let tags: [String]?
    public let viewer_count: Int?
}

public struct KickLivestream: Decodable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let thumbnail: String?
    public let viewer_count: Int?
    public let language_code: String?
    public let started_at: String?
    public let has_mature_content: Bool?
    public let tags: [String]?
    public let broadcaster_user: User
    public let channel: Channel
    public let category: KickCategory?

    public struct User: Decodable, Hashable { public let id: Int; public let username: String; public let profile_picture: String? }
    public struct Channel: Decodable, Hashable { public let slug: String }
}

public struct KickUser: Decodable, Hashable {
    public let user_id: Int
    public let name: String
    public let profile_picture: String?
    public let email: String?
}

public struct KickPostChat: Encodable {
    public let broadcaster_user_id: Int
    public let content: String
    public let reply_to_message_id: String?
    public let type: String
    public init(broadcasterUserID: Int, content: String, replyTo: String? = nil) {
        self.broadcaster_user_id = broadcasterUserID
        self.content = content
        self.reply_to_message_id = replyTo
        self.type = "user"
    }
}

public struct KickChatResponse: Decodable { public let is_sent: Bool; public let message_id: String? }
