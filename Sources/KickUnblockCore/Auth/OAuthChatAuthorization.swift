import Foundation

public enum OAuthChatAuthorization {
    public static func require(_ token: KickTokens?, identity: String?) throws -> String {
        guard let token, !token.isAppToken, !token.isExpired, !token.accessToken.isEmpty,
              token.scope?.split(whereSeparator: { $0.isWhitespace }).contains("chat:write") == true,
              let identity, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KickAPIClient.APIError.notAuthenticated
        }
        return token.accessToken
    }

    public static func selected(_ preferred: ChatSendPath, webAvailable: Bool, officialAvailable: Bool) -> ChatSendPath? {
        switch preferred {
        case .webSession: return webAvailable ? .webSession : nil
        case .official: return officialAvailable ? .official : nil
        }
    }
}

@MainActor
public final class OAuthChatSendCoordinator {
    public private(set) var isSending = false
    public init() {}

    public func send(revision: UInt64, operation: () async throws -> Bool) async throws -> UInt64? {
        guard !isSending else { return nil }
        isSending = true
        defer { isSending = false }
        return try await operation() ? revision : nil
    }
}
