import Foundation
import TidyCore

/// The Google sign-in orchestrator: ties PKCE + the loopback receiver + the system browser + the
/// token exchange into one call. On success the refresh token is in the Keychain and calendar sync
/// can run unattended.
///
/// The browser opener is a **required injected closure** — deliberately no default. That keeps this
/// module AppKit-free (TidySurface supplies `NSWorkspace.shared.open`) and makes the entire flow
/// end-to-end testable: tests pass an opener that plays the browser's role by hitting the loopback
/// receiver's real socket with a crafted redirect.
public struct GoogleAuthenticator: Sendable {
    public typealias Opener = @Sendable (URL) -> Void

    private let config: GoogleOAuthConfig
    private let http: HTTPClient
    private let secrets: SecretStore
    private let opener: Opener
    private let timeout: TimeInterval
    private let randomBytes: @Sendable (Int) -> Data

    public init(config: GoogleOAuthConfig, http: HTTPClient, secrets: SecretStore,
                opener: @escaping Opener, timeout: TimeInterval = 300,
                randomBytes: @escaping @Sendable (Int) -> Data = PKCE.secureRandom) {
        self.config = config; self.http = http; self.secrets = secrets
        self.opener = opener; self.timeout = timeout; self.randomBytes = randomBytes
    }

    /// Run the full loopback + PKCE flow. If Google returns no refresh token (an account that
    /// consented before), retries ONCE with `prompt=consent` — the documented recovery path.
    @discardableResult
    public func signIn() async throws -> GoogleTokenResponse {
        do {
            return try await attempt(forceConsent: false)
        } catch GoogleOAuthError.noRefreshToken {
            return try await attempt(forceConsent: true)
        }
    }

    private func attempt(forceConsent: Bool) async throws -> GoogleTokenResponse {
        let pkce = PKCE(randomBytes: randomBytes)
        // CSRF state: 16 random bytes, base64url. Validated BEFORE the code is even looked at.
        let state = PKCE.base64URL(randomBytes(16))

        let receiver = LoopbackReceiver()
        let redirectURI = try receiver.start()
        defer { receiver.stop() }   // idempotent; also runs on every throw path

        opener(GoogleOAuthRequests.authorizationURL(
            config: config, pkce: pkce, redirectURI: redirectURI, state: state,
            forceConsent: forceConsent))

        // User closing the browser simply never redirects — surfaces as the receiver's timeout.
        let query = try await receiver.waitForCallback(timeout: timeout)
        let callback = GoogleOAuthRequests.parseCallback(query: query)

        if let error = callback.error {
            throw GoogleOAuthRequests.authorizationError(error)
        }
        // State mismatch = this redirect wasn't the one we initiated. Discard without touching
        // the code — no exchange is attempted.
        guard callback.state == state else { throw GoogleOAuthError.stateMismatch }
        guard let code = callback.code, !code.isEmpty else {
            throw GoogleOAuthError.tokenExchangeFailed("callback carried no authorization code")
        }

        let response = try await http.send(GoogleOAuthRequests.exchangeRequest(
            config: config, code: code, verifier: pkce.verifier, redirectURI: redirectURI))
        let tokens = try GoogleOAuthRequests.parseTokenResponse(response, isRefresh: false)

        guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
            throw GoogleOAuthError.noRefreshToken   // triggers the forceConsent retry in signIn()
        }
        try secrets.set(SecretKey.googleRefreshToken, refresh)
        return tokens
    }
}
