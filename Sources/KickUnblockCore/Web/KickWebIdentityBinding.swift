import Foundation

public struct KickWebIdentityBinding: Sendable {
    public private(set) var identity: KickIdentity?
    public private(set) var lastError: KickAccountError?
    private var verifiedCookies: [WebCookie] = []

    public init() {}

    private static func context(_ cookies: [WebCookie]) -> [WebCookie] {
        KickSessionCookies.filter(cookies).sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.value < $1.value
        }
    }

    public mutating func observe(_ cookies: [WebCookie]) {
        if Self.context(cookies) != verifiedCookies {
            identity = nil
            verifiedCookies = []
        }
    }

    public mutating func complete(data: Data, cookies: [WebCookie], currentCookies: [WebCookie]) {
        if let identity = KickIdentity.parse(data) {
            complete(identity: identity, cookies: cookies, currentCookies: currentCookies)
        } else if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object.isEmpty {
            complete(identity: nil, cookies: cookies, currentCookies: currentCookies)
        } else {
            fail(.decoding, cookies: cookies, currentCookies: currentCookies)
        }
    }

    public mutating func complete(identity: KickIdentity?, cookies: [WebCookie], currentCookies: [WebCookie]) {
        observe(currentCookies)
        guard Self.context(cookies) == Self.context(currentCookies) else { return }
        self.identity = KickSessionCookies.isSignedIn(cookies) ? identity : nil
        verifiedCookies = self.identity == nil ? [] : Self.context(cookies)
        lastError = nil
    }

    public mutating func fail(_ error: KickAccountError, cookies: [WebCookie], currentCookies: [WebCookie]) {
        observe(currentCookies)
        guard Self.context(cookies) == Self.context(currentCookies) else { return }
        if error == .notSignedIn { identity = nil; verifiedCookies = [] }
        lastError = error == .notSignedIn ? nil : error
    }

    public func authorizes(_ cookies: [WebCookie]) -> Bool {
        identity != nil && KickSessionCookies.isSignedIn(cookies) && Self.context(cookies) == verifiedCookies
    }
}
