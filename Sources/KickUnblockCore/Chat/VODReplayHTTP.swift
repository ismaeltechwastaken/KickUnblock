import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct VODReplayHTTP: Sendable {
    private let session: URLSession
    public init(session: URLSession) { self.session = session }

    public static func anonymous() -> VODReplayHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return VODReplayHTTP(session: URLSession(configuration: config))
    }

    public var client: VODReplayClient {
        VODReplayClient(fetchPage: { try await self.page(channelID: $0, cursor: $1) })
    }

    public func page(channelID: Int, cursor: String) async throws -> VODReplayPage {
        try Task.checkCancellation()
        guard channelID > 0, !cursor.isEmpty, cursor.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw VODReplayError.invalidContext
        }
        var request = URLRequest(url: ChatHistory.url(channelID: channelID, cursor: cursor), timeoutInterval: 8)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw VODReplayError.unexpectedResponse }
        if response.statusCode == 429 { throw VODReplayError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
        guard response.statusCode == 200 else { throw VODReplayError.httpStatus(response.statusCode) }
        guard response.mimeType?.lowercased() == "application/json", data.count <= 2_000_000 else {
            throw VODReplayError.unexpectedResponse
        }
        return try VODReplayPage.parse(data)
    }
}
