import Foundation
import TidyCore

/// Supplies the access token `LiveGoogleCalendarClient` has been asking for since Phase 3.
///
/// Holds no long-lived secret in memory beyond the cached access token: the **refresh token lives in
/// the Keychain** (G6) and is read per refresh. Access tokens are cached until shortly before expiry
/// so a burst of calendar calls doesn't re-hit the token endpoint.
public actor GoogleTokenProvider {
    private let config: GoogleOAuthConfig
    private let http: HTTPClient
    private let secrets: SecretStore
    private let clock: TidyClock
    /// Refresh this many seconds BEFORE nominal expiry, so a token can't die mid-request.
    private let earlyRefresh: TimeInterval

    private var cachedToken: String?
    private var cachedExpiry: Date?

    public init(config: GoogleOAuthConfig, http: HTTPClient, secrets: SecretStore,
                clock: TidyClock = SystemClock(), earlyRefresh: TimeInterval = 60) {
        self.config = config; self.http = http; self.secrets = secrets
        self.clock = clock; self.earlyRefresh = earlyRefresh
    }

    /// A valid access token, refreshing only when the cached one is missing or near expiry.
    public func accessToken() async throws -> String {
        if let token = cachedToken, let expiry = cachedExpiry,
           clock.now.addingTimeInterval(earlyRefresh) < expiry {
            return token
        }
        guard let refresh = try secrets.get(SecretKey.googleRefreshToken), !refresh.isEmpty else {
            throw GoogleOAuthError.noRefreshToken
        }
        let response = try await http.send(GoogleOAuthRequests.refreshRequest(config: config, refreshToken: refresh))
        let tokens = try GoogleOAuthRequests.parseTokenResponse(response, isRefresh: true)

        // Google usually omits refresh_token on a refresh; if it DOES rotate one, store the new one
        // or the next refresh fails.
        if let rotated = tokens.refreshToken, !rotated.isEmpty, rotated != refresh {
            try secrets.set(SecretKey.googleRefreshToken, rotated)
        }
        cachedToken = tokens.accessToken
        cachedExpiry = clock.now.addingTimeInterval(TimeInterval(tokens.expiresIn))
        return tokens.accessToken
    }

    /// Drop the cached token (used after a 401 so the next call re-refreshes).
    public func invalidate() {
        cachedToken = nil
        cachedExpiry = nil
    }

    /// `@Sendable` closure matching `LiveGoogleCalendarClient`'s `accessToken` parameter.
    public nonisolated func tokenClosure() -> @Sendable () async throws -> String {
        { try await self.accessToken() }
    }
}
