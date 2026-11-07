import Foundation

public struct ChatTarget: Hashable, Sendable {
    public let channelID: Int?
    public let chatroomID: Int?
    public let broadcasterUserID: Int?
    public let slug: String
    public init(channelID: Int?, chatroomID: Int?, broadcasterUserID: Int?, slug: String) {
        self.channelID = channelID; self.chatroomID = chatroomID
        self.broadcasterUserID = broadcasterUserID; self.slug = slug
    }
}

public protocol ChatTransport: AnyObject {
    var onEvent: ((ChatStreamEvent) -> Void)? { get set }
    var onStatus: ((ChatConnectionStatus) -> Void)? { get set }
    func connect(_ target: ChatTarget)
    func disconnect()
}

public enum ChatConnectionStatus: Equatable, Sendable {
    case idle, connecting, connected, failed(String)
}

public struct RelayEnvelope: Decodable {
    public let type: String
    public let payload: KickChatEvent?
}

public enum PusherFrame {
    public struct Raw: Decodable { public let event: String; public let channel: String?; public let data: String? }

    public static func socketURL(cluster: String, key: String) -> URL? {
        URL(string: "wss://ws-\(cluster).pusher.com/app/\(key)?protocol=7&client=kickunblock&version=1.0&flash=false")
    }

    public static func subscribe(_ channel: String) -> String {
        #"{"event":"pusher:subscribe","data":{"auth":"","channel":"\#(channel)"}}"#
    }

    public static func unsubscribe(_ channel: String) -> String {
        #"{"event":"pusher:unsubscribe","data":{"channel":"\#(channel)"}}"#
    }

    public static let pong = #"{"event":"pusher:pong","data":{}}"#
    public static let ping = #"{"event":"pusher:ping","data":{}}"#

    public static func decode(_ text: String) -> Raw? {
        try? JSONDecoder().decode(Raw.self, from: Data(text.utf8))
    }
}
