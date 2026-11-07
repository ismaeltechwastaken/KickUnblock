import Foundation

@MainActor
public final class OAuthChatTokenSession {
    public typealias Refresh = @MainActor (String) async throws -> KickTokens
    public private(set) var tokens: KickTokens?
    public private(set) var generation = UUID()
    public var onChange: ((KickTokens?) -> Void)?
    private var flight: (id: UUID, task: Task<KickTokens, Error>)?

    public init(tokens: KickTokens? = nil) { self.tokens = tokens }

    public func reset(tokens: KickTokens? = nil) {
        generation = UUID()
        flight?.task.cancel(); flight = nil
        self.tokens = tokens
        onChange?(tokens)
    }

    public func validToken(refresh: @escaping Refresh,
                           app: @escaping @MainActor () async throws -> KickTokens) async throws -> String? {
        if let tokens, !tokens.isExpired { return tokens.accessToken }
        let generation = generation
        let work: (id: UUID, task: Task<KickTokens, Error>)
        if let flight { work = flight }
        else {
            let previous = tokens
            work = (UUID(), Task {
                if let previous, !previous.isAppToken {
                    guard let rt = previous.refreshToken else { throw KickAPIClient.APIError.notAuthenticated }
                    var next = try await refresh(rt)
                    if next.refreshToken == nil { next.refreshToken = previous.refreshToken }
                    if next.scope == nil { next.scope = previous.scope }
                    guard !next.isAppToken else { throw KickAPIClient.APIError.notAuthenticated }
                    return next
                }
                return try await app()
            })
            flight = work
        }
        do {
            let result = try await work.task.value
            guard self.generation == generation else { throw CancellationError() }
            guard !result.isExpired, !result.accessToken.isEmpty else { throw KickAPIClient.APIError.notAuthenticated }
            if flight?.id == work.id {
                flight = nil
                tokens = result
                onChange?(result)
            }
            return result.accessToken
        } catch {
            if flight?.id == work.id { flight = nil }
            throw error
        }
    }
}
