import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySurface
@testable import TidyIngest

/// End-to-end tests of the sign-in orchestrator: the REAL loopback socket, a fake HTTP client for
/// the token endpoint, and an opener closure that plays the browser's role by hitting the
/// receiver's redirect URI — the same technique as LoopbackReceiverTests.
final class GoogleAuthenticatorTests: XCTestCase {
    private let config = GoogleOAuthConfig(clientId: "cid.apps.googleusercontent.com", clientSecret: "sec")

    /// An opener that immediately "consents": parses the auth URL, extracts redirect_uri + state,
    /// and redirects like the browser would. Optionally overrides the state or replies with an error.
    private func consentingOpener(stateOverride: String? = nil, errorParam: String? = nil,
                                  onOpen: (@Sendable (URL) -> Void)? = nil) -> GoogleAuthenticator.Opener {
        { url in
            onOpen?(url)
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let redirect = q["redirect_uri"]!
            let state = stateOverride ?? q["state"]!
            let reply = errorParam.map { "error=\($0)&state=\(state)" } ?? "code=the-code&state=\(state)"
            Task {
                var request = URLRequest(url: URL(string: "\(redirect)/?\(reply)")!)
                request.timeoutInterval = 10
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    func testSignInHappyPathStoresRefreshToken() async throws {
        let secrets = InMemorySecretStore()
        let http = FakeHTTPClient([.json(#"{"access_token":"at","refresh_token":"rt1","expires_in":3600}"#)])
        let openedURL = CapturedURL()
        let auth = GoogleAuthenticator(config: config, http: http, secrets: secrets,
                                       opener: consentingOpener(onOpen: { openedURL.set($0) }),
                                       timeout: 15)
        let tokens = try await auth.signIn()
        XCTAssertEqual(tokens.refreshToken, "rt1")
        XCTAssertEqual(try secrets.get(SecretKey.googleRefreshToken), "rt1")

        // The auth URL the "browser" saw must carry PKCE + offline access, and NO prompt by default.
        let url = openedURL.get()!
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertNotNil(q["code_challenge"])
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertNil(q["prompt"])
        // The exchange must have carried the matching verifier.
        let body = String(decoding: http.sentRequests[0].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("code_verifier="))
        XCTAssertTrue(body.contains("code=the-code"))
    }

    func testStateMismatchDiscardsCodeWithoutExchange() async throws {
        let secrets = InMemorySecretStore()
        let http = FakeHTTPClient([])   // any exchange attempt would throw transport — none may happen
        let auth = GoogleAuthenticator(config: config, http: http, secrets: secrets,
                                       opener: consentingOpener(stateOverride: "FORGED"), timeout: 15)
        do {
            _ = try await auth.signIn()
            XCTFail("expected stateMismatch")
        } catch let error as GoogleOAuthError {
            XCTAssertEqual(error, .stateMismatch)
        }
        XCTAssertNil(try secrets.get(SecretKey.googleRefreshToken))
        XCTAssertTrue(http.sentRequests.isEmpty, "a forged state must never reach the token endpoint")
    }

    func testUserDeniedConsent() async throws {
        let secrets = InMemorySecretStore()
        let auth = GoogleAuthenticator(config: config, http: FakeHTTPClient([]), secrets: secrets,
                                       opener: consentingOpener(errorParam: "access_denied"), timeout: 15)
        do {
            _ = try await auth.signIn()
            XCTFail("expected authorizationDenied")
        } catch let error as GoogleOAuthError {
            guard case .authorizationDenied = error else { return XCTFail("got \(error)") }
        }
        XCTAssertNil(try secrets.get(SecretKey.googleRefreshToken))
    }

    func testTimesOutWhenBrowserNeverReturns() async throws {
        let auth = GoogleAuthenticator(config: config, http: FakeHTTPClient([]),
                                       secrets: InMemorySecretStore(),
                                       opener: { _ in }, timeout: 1)
        do {
            _ = try await auth.signIn()
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("timed out"))
        }
    }

    /// A previously-consented account gets no refresh token — the retry must force the consent
    /// screen and succeed on the second pass.
    func testMissingRefreshTokenRetriesWithForcedConsent() async throws {
        let secrets = InMemorySecretStore()
        let http = FakeHTTPClient([
            .json(#"{"access_token":"at1","expires_in":3600}"#),                       // no refresh token
            .json(#"{"access_token":"at2","refresh_token":"rt2","expires_in":3600}"#), // retry succeeds
        ])
        let opened = CapturedURLs()
        let auth = GoogleAuthenticator(config: config, http: http, secrets: secrets,
                                       opener: consentingOpener(onOpen: { opened.append($0) }),
                                       timeout: 15)
        let tokens = try await auth.signIn()
        XCTAssertEqual(tokens.refreshToken, "rt2")
        XCTAssertEqual(try secrets.get(SecretKey.googleRefreshToken), "rt2")
        let urls = opened.get()
        XCTAssertEqual(urls.count, 2, "must have opened the browser twice")
        XCTAssertFalse(urls[0].absoluteString.contains("prompt=consent"))
        XCTAssertTrue(urls[1].absoluteString.contains("prompt=consent"),
                      "the retry must force the consent screen")
    }
}

/// Thread-safe capture boxes for @Sendable closures.
private final class CapturedURL: @unchecked Sendable {
    private let lock = NSLock(); private var url: URL?
    func set(_ u: URL) { lock.lock(); url = u; lock.unlock() }
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
}
private final class CapturedURLs: @unchecked Sendable {
    private let lock = NSLock(); private var urls: [URL] = []
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    func get() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

/// Readiness transitions for the google source now that the flow exists.
final class GoogleReadinessTests: XCTestCase {
    private func coordinator(clientId: String, secrets: [String: String]) throws -> IngestCoordinator {
        var config = Config()
        config.google.clientId = clientId
        return IngestCoordinator(db: try AppDatabase.inMemory(), config: config,
                                 secrets: InMemorySecretStore(secrets),
                                 clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testGoogleNeedsClientIdFirst() throws {
        let c = try coordinator(clientId: "", secrets: [SecretKey.googleClientSecret: "s",
                                                       SecretKey.googleRefreshToken: "r"])
        XCTAssertEqual(c.readiness(.googleCalendar), .missingConfig("google.client_id"))
    }

    func testGoogleNeedsClientSecretBeforeSignIn() throws {
        let c = try coordinator(clientId: "cid", secrets: [:])
        XCTAssertEqual(c.readiness(.googleCalendar), .missingCredential(SecretKey.googleClientSecret))
    }

    func testGoogleWithoutRefreshTokenNeedsSignIn() throws {
        let c = try coordinator(clientId: "cid", secrets: [SecretKey.googleClientSecret: "s"])
        let r = c.readiness(.googleCalendar)
        XCTAssertEqual(r, .needsSignIn("click Sign in with Google in Settings → Credentials"))
        XCTAssertFalse(r.canRun)
        XCTAssertTrue(r.explanation.hasPrefix("needs sign-in — "))
    }

    func testGoogleFullyConfiguredIsReady() throws {
        let c = try coordinator(clientId: "cid", secrets: [SecretKey.googleClientSecret: "s",
                                                          SecretKey.googleRefreshToken: "r"])
        XCTAssertEqual(c.readiness(.googleCalendar), .ready)
    }

    func testGoogleKillSwitchStillWins() throws {
        var config = Config()
        config.google.clientId = "cid"
        config.capture.killSwitches.calendar = false
        let c = IngestCoordinator(db: try AppDatabase.inMemory(), config: config,
                                  secrets: InMemorySecretStore([SecretKey.googleClientSecret: "s",
                                                                SecretKey.googleRefreshToken: "r"]))
        XCTAssertEqual(c.readiness(.googleCalendar), .disabledByKillSwitch)
    }

    func testCalendarWindowIsRFC3339SpanningPastAndFuture() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (timeMin, timeMax) = IngestCoordinator.calendarWindow(daysBack: 30, daysForward: 60, clock: clock)
        let f = ISO8601DateFormatter()
        let minDate = f.date(from: timeMin)!
        let maxDate = f.date(from: timeMax)!
        XCTAssertEqual(minDate.timeIntervalSince1970, 1_700_000_000 - 30 * 86_400, accuracy: 1)
        XCTAssertEqual(maxDate.timeIntervalSince1970, 1_700_000_000 + 60 * 86_400, accuracy: 1)
    }

    /// A rejected refresh token must clear itself so readiness flips back to needs-sign-in.
    func testRefreshRejectedClearsRefreshTokenAndRecordsError() async throws {
        let db = try AppDatabase.inMemory()
        var config = Config()
        config.google.clientId = "cid"
        let secrets = InMemorySecretStore([SecretKey.googleClientSecret: "s",
                                           SecretKey.googleRefreshToken: "revoked"])
        let http = FakeHTTPClient([
            .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#,
                  status: 400),
        ])
        let c = IngestCoordinator(db: db, config: config, secrets: secrets, http: http,
                                  clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(c.readiness(.googleCalendar), .ready)
        await c.runAll()   // productive/fathom/slack skip (no creds); google runs and fails

        XCTAssertNil(try secrets.get(SecretKey.googleRefreshToken),
                     "rejected refresh token must be deleted")
        let state = (try db.syncState("google_calendar")) ?? nil
        XCTAssertTrue(state?.lastError?.contains("sign in again") ?? false,
                      "the recorded error must carry the re-auth hint")
        guard case .needsSignIn = c.readiness(.googleCalendar) else {
            return XCTFail("readiness must flip to needsSignIn after deletion")
        }
    }
}
