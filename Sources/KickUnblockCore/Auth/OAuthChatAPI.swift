import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OAuthChatAPI {
    public static func send(_ body: KickPostChat, token: KickTokens?, identity: String?,
                            session: URLSession = .shared) async throws -> KickChatResponse {
        let bearer = try OAuthChatAuthorization.require(token, identity: identity)
        return try await KickAPIClient(session: session, token: { bearer }).sendChat(body)
    }
}
