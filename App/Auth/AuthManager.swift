import AuthenticationServices
import SwiftUI
import KickUnblockCore

@MainActor
final class AuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var config: KickOAuthConfig?
    @Published private(set) var tokens: KickTokens?
    @Published private(set) var username: String?
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?

    private static let cfgKey = "oauth.config", tokKey = "oauth.tokens"
    private let tokenSession: OAuthChatTokenSession
    private var browser: ASWebAuthenticationSession?
    private var loginID: UUID?
    private var loginCompletion: ((Result<URL, Error>) -> Void)?

    override init() {
        config = KeychainStore.get(KickOAuthConfig.self, for: Self.cfgKey)
        let restored = KeychainStore.get(KickTokens.self, for: Self.tokKey)
        tokens = restored
        tokenSession = OAuthChatTokenSession(tokens: restored)
        super.init()
        tokenSession.onChange = { [weak self] value in
            self?.tokens = value
            if let value { KeychainStore.set(value, for: Self.tokKey) }
            else { self?.username = nil; KeychainStore.delete(Self.tokKey) }
        }
        if restored?.isAppToken == false {
            Task { [weak self] in try? await self?.refreshIdentity() }
        }
    }

    var isConfigured: Bool { !(config?.clientID.isEmpty ?? true) }
    var isSignedIn: Bool { tokens.map { !$0.isAppToken } ?? false }
    var hasChatCredential: Bool {
        isSignedIn && tokens?.scope?.split(whereSeparator: { $0.isWhitespace }).contains("chat:write") == true
    }

    func save(config: KickOAuthConfig) {
        if self.config != config { invalidateAccount() }
        self.config = config
        KeychainStore.set(config, for: Self.cfgKey)
    }

    func clearCredentials() {
        invalidateAccount()
        config = nil
        KeychainStore.delete(Self.cfgKey)
    }

    func validAccessToken() async throws -> String? {
        guard let config else { return nil }
        let client = KickOAuthClient(config: config)
        return try await tokenSession.validToken(refresh: { try await client.refresh($0) }, app: {
            guard config.clientSecret != nil || config.tokenEndpointOverride != nil else {
                throw KickAPIClient.APIError.notAuthenticated
            }
            return try await client.appToken()
        })
    }

    func refreshIdentity() async throws {
        let generation = tokenSession.generation
        guard isSignedIn, let bearer = try await validAccessToken() else { return }
        do {
            let user = try await KickAPIClient(token: { bearer }).currentUser()
            guard generation == tokenSession.generation, tokens?.accessToken == bearer else { throw CancellationError() }
            guard let user, user.user_id > 0, !user.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KickAPIClient.APIError.notAuthenticated
            }
            username = user.name
        } catch {
            if generation == tokenSession.generation, tokens?.accessToken == bearer,
               case KickAPIClient.APIError.http(401, _) = error { invalidateAccount() }
            throw error
        }
    }

    func validUserChatToken() async throws -> String {
        let generation = tokenSession.generation
        guard hasChatCredential else { throw KickAPIClient.APIError.notAuthenticated }
        _ = try await validAccessToken()
        guard generation == tokenSession.generation else { throw CancellationError() }
        if username == nil { try await refreshIdentity() }
        guard generation == tokenSession.generation else { throw CancellationError() }
        return try OAuthChatAuthorization.require(tokens, identity: username)
    }

    func sendChat(_ body: KickPostChat) async throws -> KickChatResponse {
        let generation = tokenSession.generation
        var sentBearer: String?
        do {
            _ = try await validUserChatToken()
            guard generation == tokenSession.generation else { throw CancellationError() }
            sentBearer = tokens?.accessToken
            return try await OAuthChatAPI.send(body, token: tokens, identity: username)
        }
        catch {
            if generation == tokenSession.generation, let sentBearer, tokens?.accessToken == sentBearer,
               case KickAPIClient.APIError.http(401, _) = error { invalidateAccount() }
            throw error
        }
    }

    func signIn() async {
        guard !isSigningIn else { return }
        guard let config else { lastError = "Add your Kick Client ID under Tweaks › Official API first."; return }
        invalidateAccount()
        let id = UUID(), generation = tokenSession.generation
        loginID = id; isSigningIn = true; lastError = nil
        defer {
            if loginID == id { browser = nil; loginCompletion = nil; loginID = nil; isSigningIn = false }
        }
        let client = KickOAuthClient(config: config)
        let pkce = PKCE.generate(), state = PKCE.randomState()
        let scheme = URL(string: config.redirectURI)?.scheme ?? "kickunblock"
        do {
            let callback: URL = try await withCheckedThrowingContinuation { cont in
                loginCompletion = { cont.resume(with: $0) }
                let session = ASWebAuthenticationSession(url: client.authorizeURL(pkce: pkce, state: state), callbackURLScheme: scheme) { [weak self] url, error in
                    Task { @MainActor in
                        guard let self, self.loginID == id, let completion = self.loginCompletion else { return }
                        self.loginCompletion = nil
                        if let url { completion(.success(url)) }
                        else { completion(.failure(error ?? CancellationError())) }
                    }
                }
                browser = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                if !session.start() {
                    let completion = loginCompletion; loginCompletion = nil
                    completion?(.failure(URLError(.cannotLoadFromNetwork)))
                }
            }
            guard generation == tokenSession.generation else { throw CancellationError() }
            let code = try KickOAuthClient.code(from: callback, expectedState: state)
            let received = try await client.exchange(code: code, pkce: pkce)
            guard generation == tokenSession.generation else { throw CancellationError() }
            tokenSession.reset(tokens: received)
            try await refreshIdentity()
        } catch {
            guard loginID == id else { return }
            if error is CancellationError || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            lastError = error.localizedDescription
        }
    }

    private func invalidateAccount() {
        tokenSession.reset()
        browser?.cancel(); browser = nil
        let completion = loginCompletion
        loginCompletion = nil; loginID = nil; isSigningIn = false
        completion?(.failure(CancellationError()))
    }

    func signOut() {
        let previous = tokens, config = config
        invalidateAccount()
        if let config, let previous, !previous.isAppToken {
            var request = URLRequest(url: config.revokeURL(token: previous.accessToken))
            request.httpMethod = "POST"
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
