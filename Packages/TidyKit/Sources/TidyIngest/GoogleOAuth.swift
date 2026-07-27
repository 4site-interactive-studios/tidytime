import Foundation
import CryptoKit
import TidyCore

// Google OAuth 2.0 for an **installed/desktop app**: loopback redirect + PKCE.
//
// Why this shape (and not the alternatives):
//  - **Loopback, not out-of-band.** Google deprecated the `urn:ietf:wg:oauth:2.0:oob` flow; a
//    desktop app must receive the code on `http://127.0.0.1:<port>`.
//  - **PKCE with S256.** A desktop client secret ships inside the app and is not truly secret, so
//    proof-of-possession is what actually protects the exchange.
//  - **`state` is mandatory here**, not optional garnish: without it a malicious local page could
//    hand our listener a code from a different authorization (CSRF).
//
// Everything in this file is pure request-building / response-parsing so it is fully testable; the
// socket lives in `LoopbackReceiver` and the browser hand-off in `GoogleAuthenticator`.

// MARK: - PKCE

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    /// RFC 7636: verifier is 43–128 chars from the unreserved set; challenge is
    /// BASE64URL(SHA256(ASCII(verifier))) with padding stripped.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    public init(randomBytes: (Int) -> Data = PKCE.secureRandom) {
        // 32 random bytes → 43 base64url chars, the RFC's recommended minimum.
        self.init(verifier: Self.base64URL(randomBytes(32)))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func secureRandom(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Endpoints & configuration

public struct GoogleOAuthConfig: Sendable, Equatable {
    public var clientId: String
    public var clientSecret: String?
    public var scopes: [String]
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL

    public init(clientId: String, clientSecret: String? = nil,
                scopes: [String] = ["https://www.googleapis.com/auth/calendar.readonly"],
                authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!) {
        self.clientId = clientId; self.clientSecret = clientSecret; self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint; self.tokenEndpoint = tokenEndpoint
    }
}

// MARK: - Request building / response parsing (pure)

public enum GoogleOAuthError: Error, Equatable, CustomStringConvertible {
    case stateMismatch
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    /// The refresh token was revoked or expired — the user must sign in again.
    case refreshRejected(String)
    case noRefreshToken
    /// A Workspace admin has restricted the scope. Retrying cannot help — the admin must allow it.
    case blockedByAdmin(String)
    /// An Internal-type client signed into with an account outside the Cloud Organization.
    case wrongOrganization(String)

    public var description: String {
        switch self {
        case .stateMismatch: return "OAuth state mismatch — possible CSRF; authorization discarded"
        case .authorizationDenied(let m): return "authorization denied: \(m)"
        case .tokenExchangeFailed(let m): return "token exchange failed: \(m)"
        case .refreshRejected(let m): return "refresh token rejected (sign in again): \(m)"
        case .noRefreshToken: return "no refresh token stored — run Google sign-in"
        case .blockedByAdmin(let m): return "blocked by a Workspace admin policy (they must allow this app): \(m)"
        case .wrongOrganization(let m): return "this OAuth client is Internal to another organization: \(m)"
        }
    }
}

public struct GoogleTokenResponse: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?      // absent on refresh responses — keep the existing one
    public let expiresIn: Int
    public let scope: String?
}

public enum GoogleOAuthRequests {
    /// The URL the user opens in a browser to consent.
    /// `forceConsent` re-prompts the consent screen. Leave it **off** for normal sign-in: Google
    /// documents that "refresh tokens are always returned for installed applications", and
    /// `prompt=consent` would re-prompt on every launch. Turn it on only for the recovery path, where
    /// it is the documented way to force issuance of a new refresh token.
    public static func authorizationURL(config: GoogleOAuthConfig, pkce: PKCE,
                                        redirectURI: String, state: String,
                                        forceConsent: Bool = false) -> URL {
        var comps = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
            // Documented on the web-server page as what asks for a refresh token; harmless for
            // installed apps, which receive one regardless.
            .init(name: "access_type", value: "offline"),
        ]
        if forceConsent { comps.queryItems?.append(.init(name: "prompt", value: "consent")) }
        return comps.url!
    }

    /// Initial `authorization_code` → tokens.
    public static func exchangeRequest(config: GoogleOAuthConfig, code: String,
                                       verifier: String, redirectURI: String) -> HTTPRequest {
        var fields = [
            "client_id": config.clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        // Google issues a secret for desktop clients and its token endpoint expects it, even though
        // it documents the value as non-confidential for installed apps. Send it when present.
        if let secret = config.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        return formRequest(to: config.tokenEndpoint, fields: fields)
    }

    /// `refresh_token` → a fresh access token.
    public static func refreshRequest(config: GoogleOAuthConfig, refreshToken: String) -> HTTPRequest {
        var fields = [
            "client_id": config.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = config.clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        return formRequest(to: config.tokenEndpoint, fields: fields)
    }

    static func formRequest(to url: URL, fields: [String: String]) -> HTTPRequest {
        // Sorted so the body is deterministic — makes the request assertable in tests.
        var pairs: [String] = []
        for key in fields.keys.sorted() {
            let k: String = formEncode(key)
            let v: String = formEncode(fields[key] ?? "")
            pairs.append(k + "=" + v)
        }
        let body: String = pairs.joined(separator: "&")
        return HTTPRequest(method: "POST", url: url,
                           headers: ["Content-Type": "application/x-www-form-urlencoded"],
                           body: Data(body.utf8))
    }

    /// `application/x-www-form-urlencoded` escaping — note space becomes `%20` here (not `+`), and
    /// `+` itself must be escaped or the server will read it as a space.
    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Parse a token response, mapping Google's error shape onto typed errors.
    public static func parseTokenResponse(_ response: HTTPResponse, isRefresh: Bool) throws -> GoogleTokenResponse {
        struct Payload: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Int?
            let scope: String?
            let error: String?
            let error_description: String?
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: response.body)
        let raw = String(decoding: response.body, as: UTF8.self)

        if let error = payload?.error {
            let detail = payload?.error_description ?? error
            // invalid_grant on a refresh means the token was revoked/expired → re-auth required.
            if isRefresh && error == "invalid_grant" { throw GoogleOAuthError.refreshRejected(detail) }
            throw GoogleOAuthError.tokenExchangeFailed("\(error): \(detail)")
        }
        guard (200..<300).contains(response.status) else {
            throw GoogleOAuthError.tokenExchangeFailed("HTTP \(response.status): \(raw)")
        }
        guard let token = payload?.access_token else {
            throw GoogleOAuthError.tokenExchangeFailed("no access_token in response")
        }
        return GoogleTokenResponse(accessToken: token, refreshToken: payload?.refresh_token,
                                   expiresIn: payload?.expires_in ?? 3600, scope: payload?.scope)
    }

    /// Turn an authorization-endpoint `error=` code into a typed, actionable error.
    /// Names verified against Google's native-app + web-server docs (2026-07-26).
    public static func authorizationError(_ code: String) -> GoogleOAuthError {
        switch code {
        case "access_denied":          return .authorizationDenied("you declined the consent screen")
        case "admin_policy_enforced":  return .blockedByAdmin(code)
        case "org_internal":           return .wrongOrganization(code)
        case "disallowed_useragent":
            // Only reachable if the auth URL is opened in an embedded WKWebView, which Google blocks.
            // We open the system browser precisely to avoid this.
            return .authorizationDenied("Google refused the browser used for sign-in (\(code))")
        case "deleted_client":         return .tokenExchangeFailed("the OAuth client was deleted (\(code))")
        case "redirect_uri_mismatch":
            return .tokenExchangeFailed("redirect_uri_mismatch — the client must be type 'Desktop app'")
        default:                       return .authorizationDenied(code)
        }
    }

    /// Extract `code`/`state`/`error` from the loopback callback request line.
    public static func parseCallback(query: String) -> (code: String?, state: String?, error: String?) {
        var comps = URLComponents()
        comps.query = query
        let items = comps.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        return (value("code"), value("state"), value("error"))
    }
}
