import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KickOAuthConfig: Codable, Equatable, Sendable {
    public static let authorizeURL = URL(string: "https://id.kick.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://id.kick.com/oauth/token")!
    public static let revokeURL = URL(string: "https://id.kick.com/oauth/revoke")!

    public static let defaultScopes = ["user:read", "channel:read", "chat:write"]

    public var clientID: String
    public var clientSecret: String?
    public var redirectURI: String
    public var scopes: [String]
    public var tokenEndpointOverride: URL?

    public init(clientID: String, clientSecret: String? = nil,
                redirectURI: String = "kickunblock://oauth/callback",
                scopes: [String] = KickOAuthConfig.defaultScopes,
                tokenEndpointOverride: URL? = nil) {
        self.clientID = clientID; self.clientSecret = clientSecret
        self.redirectURI = redirectURI; self.scopes = scopes
        self.tokenEndpointOverride = tokenEndpointOverride
    }
}

public struct KickTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    public var isAppToken: Bool

    public var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }

    struct Wire: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
    }
}

public struct KickOAuthClient: Sendable {
    public let config: KickOAuthConfig
    private let session: URLSession

    public init(config: KickOAuthConfig, session: URLSession = .shared) {
        self.config = config; self.session = session
    }

    public func authorizeURL(pkce: PKCE, state: String) -> URL {
        var c = URLComponents(url: KickOAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    public static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value { throw OAuthError.denied(err) }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { throw OAuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw OAuthError.missingCode }
        return code
    }

    public enum OAuthError: Error, Equatable { case denied(String), stateMismatch, missingCode, http(Int) }

    public func exchange(code: String, pkce: PKCE) async throws -> KickTokens {
        try await token(form: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": config.redirectURI, "code_verifier": pkce.verifier,
        ], isApp: false)
    }

    public func refresh(_ refreshToken: String) async throws -> KickTokens {
        try await token(form: ["grant_type": "refresh_token", "refresh_token": refreshToken], isApp: false)
    }

    public func appToken() async throws -> KickTokens {
        try await token(form: ["grant_type": "client_credentials"], isApp: true)
    }

    public func tokenRequest(form: [String: String]) -> URLRequest {
        var all = form
        all["client_id"] = config.clientID
        if config.tokenEndpointOverride == nil, let s = config.clientSecret { all["client_secret"] = s }
        var req = URLRequest(url: config.tokenEndpointOverride ?? KickOAuthConfig.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(all).data(using: .utf8)
        return req
    }

    private func token(form: [String: String], isApp: Bool) async throws -> KickTokens {
        let (data, resp) = try await session.data(for: tokenRequest(form: form))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw OAuthError.http(code) }
        let w = try JSONDecoder().decode(KickTokens.Wire.self, from: data)
        return KickTokens(accessToken: w.access_token, refreshToken: w.refresh_token,
                          expiresAt: Date().addingTimeInterval(w.expires_in ?? 3600),
                          scope: w.scope, isAppToken: isApp)
    }

    static func formEncode(_ dict: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return dict.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

extension KickOAuthConfig {
    public func revokeURL(token: String) -> URL {
        var c = URLComponents(url: Self.revokeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "token", value: token),
                        .init(name: "token_type_hint", value: "access_token"),
                        .init(name: "token_hint_type", value: "access_token")]
        return c.url!
    }
}
