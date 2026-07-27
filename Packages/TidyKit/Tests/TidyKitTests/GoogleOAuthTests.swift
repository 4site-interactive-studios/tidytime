import XCTest
import Foundation
import TidyCore
@testable import TidyIngest

final class PKCETests: XCTestCase {
    /// RFC 7636 Appendix B test vector — the authoritative check that S256 is computed correctly.
    func testRFC7636TestVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierMeetsRFCLengthAndCharset() {
        let pkce = PKCE()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertLessThanOrEqual(pkce.verifier.count, 128)
        // base64url only — no +, /, or = padding
        XCTAssertNil(pkce.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNil(pkce.challenge.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(pkce.method, "S256", "plain must never be used")
    }

    func testVerifiersAreUnique() {
        XCTAssertNotEqual(PKCE().verifier, PKCE().verifier)
    }
}

final class GoogleAuthURLTests: XCTestCase {
    private let config = GoogleOAuthConfig(clientId: "cid.apps.googleusercontent.com", clientSecret: "sec")

    private func items(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[i.name] = i.value
        }
        return out
    }

    func testAuthorizationURLCarriesEverythingGoogleNeeds() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleOAuthRequests.authorizationURL(
            config: config, pkce: pkce, redirectURI: "http://127.0.0.1:51234", state: "st8")
        let q = items(url)
        XCTAssertEqual(q["client_id"], "cid.apps.googleusercontent.com")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:51234")
        XCTAssertEqual(q["scope"], "https://www.googleapis.com/auth/calendar.readonly")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(q["state"], "st8")
        // access_type=offline is the documented ask for a refresh token (harmless for installed
        // apps, which always receive one). prompt=consent must NOT be sent by default — it would
        // re-show the consent screen on every sign-in; it's reserved for the recovery path.
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertNil(q["prompt"], "prompt=consent must be opt-in, not the default")
        // The verifier itself must NEVER travel in the authorization request.
        XCTAssertFalse(url.absoluteString.contains(pkce.verifier))
    }

    func testForceConsentAddsPromptForTheRecoveryPath() {
        let url = GoogleOAuthRequests.authorizationURL(
            config: config, pkce: PKCE(), redirectURI: "http://127.0.0.1:1", state: "s",
            forceConsent: true)
        XCTAssertEqual(items(url)["prompt"], "consent")
    }

    func testScopeIsReadOnly() {
        let url = GoogleOAuthRequests.authorizationURL(
            config: config, pkce: PKCE(), redirectURI: "http://127.0.0.1:1", state: "s")
        let scope = items(url)["scope"] ?? ""
        XCTAssertTrue(scope.contains("calendar.readonly"))
        XCTAssertFalse(scope.contains("calendar.events"), "must not request write scope")
    }
}

final class GoogleTokenRequestTests: XCTestCase {
    private let config = GoogleOAuthConfig(clientId: "cid", clientSecret: "sec")

    private func body(_ r: HTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: r.body ?? Data(), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1].replacingOccurrences(of: "%2F", with: "/") }
        }
        return out
    }

    func testExchangeRequestShape() {
        let r = GoogleOAuthRequests.exchangeRequest(
            config: config, code: "auth-code", verifier: "the-verifier", redirectURI: "http://127.0.0.1:99")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["Content-Type"], "application/x-www-form-urlencoded")
        let b = body(r)
        XCTAssertEqual(b["grant_type"], "authorization_code")
        XCTAssertEqual(b["code"], "auth-code")
        XCTAssertEqual(b["code_verifier"], "the-verifier")   // the verifier appears HERE, not before
        XCTAssertEqual(b["client_id"], "cid")
        XCTAssertEqual(b["client_secret"], "sec")
    }

    func testRefreshRequestShape() {
        let r = GoogleOAuthRequests.refreshRequest(config: config, refreshToken: "r3fr3sh")
        let b = body(r)
        XCTAssertEqual(b["grant_type"], "refresh_token")
        XCTAssertEqual(b["refresh_token"], "r3fr3sh")
        XCTAssertNil(b["code"])
    }

    func testClientSecretOmittedWhenAbsent() {
        let noSecret = GoogleOAuthConfig(clientId: "cid", clientSecret: nil)
        let r = GoogleOAuthRequests.refreshRequest(config: noSecret, refreshToken: "x")
        XCTAssertNil(body(r)["client_secret"])
    }

    func testFormEncodingEscapesPlusAndSpace() {
        // A '+' left unescaped would be read by the server as a space — a classic token corruption.
        XCTAssertEqual(GoogleOAuthRequests.formEncode("a+b c"), "a%2Bb%20c")
    }
}

final class GoogleTokenResponseTests: XCTestCase {
    func testParsesExchangeResponse() throws {
        let json = #"{"access_token":"at1","refresh_token":"rt1","expires_in":3599,"scope":"cal","token_type":"Bearer"}"#
        let t = try GoogleOAuthRequests.parseTokenResponse(.json(json), isRefresh: false)
        XCTAssertEqual(t.accessToken, "at1")
        XCTAssertEqual(t.refreshToken, "rt1")
        XCTAssertEqual(t.expiresIn, 3599)
    }

    func testRefreshResponseWithoutRefreshTokenIsValid() throws {
        // Google normally omits refresh_token on refresh — that must not be treated as an error.
        let t = try GoogleOAuthRequests.parseTokenResponse(
            .json(#"{"access_token":"at2","expires_in":3600}"#), isRefresh: true)
        XCTAssertEqual(t.accessToken, "at2")
        XCTAssertNil(t.refreshToken)
    }

    func testInvalidGrantOnRefreshMapsToReAuthRequired() {
        let json = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        do {
            _ = try GoogleOAuthRequests.parseTokenResponse(.json(json, status: 400), isRefresh: true)
            XCTFail("expected refreshRejected")
        } catch let e as GoogleOAuthError {
            guard case .refreshRejected = e else { return XCTFail("got \(e)") }
            XCTAssertTrue(e.description.contains("sign in again"))
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testOtherErrorsMapToExchangeFailure() {
        let json = #"{"error":"redirect_uri_mismatch","error_description":"bad redirect"}"#
        XCTAssertThrowsError(try GoogleOAuthRequests.parseTokenResponse(.json(json, status: 400), isRefresh: false)) {
            guard case GoogleOAuthError.tokenExchangeFailed = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testCallbackParsing() {
        let ok = GoogleOAuthRequests.parseCallback(query: "code=abc&state=xyz&scope=cal")
        XCTAssertEqual(ok.code, "abc"); XCTAssertEqual(ok.state, "xyz"); XCTAssertNil(ok.error)
        let denied = GoogleOAuthRequests.parseCallback(query: "error=access_denied&state=xyz")
        XCTAssertEqual(denied.error, "access_denied"); XCTAssertNil(denied.code)
    }
}

final class GoogleTokenProviderTests: XCTestCase {
    private let config = GoogleOAuthConfig(clientId: "cid", clientSecret: "sec")

    func testNoRefreshTokenIsAClearError() async {
        let provider = GoogleTokenProvider(config: config, http: FakeHTTPClient([]),
                                           secrets: InMemorySecretStore())
        do {
            _ = try await provider.accessToken()
            XCTFail("expected noRefreshToken")
        } catch let e as GoogleOAuthError {
            XCTAssertEqual(e, .noRefreshToken)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRefreshesOnceThenServesFromCache() async throws {
        let http = FakeHTTPClient([.json(#"{"access_token":"at1","expires_in":3600}"#)])
        let provider = GoogleTokenProvider(
            config: config, http: http,
            secrets: InMemorySecretStore([SecretKey.googleRefreshToken: "rt"]),
            clock: FixedClock(Date(timeIntervalSince1970: 1000)))
        let tok1 = try await provider.accessToken()
        XCTAssertEqual(tok1, "at1")
        // Second call must NOT hit the token endpoint (only one response was stubbed).
        let tok2 = try await provider.accessToken()
        XCTAssertEqual(tok2, "at1")
        XCTAssertEqual(http.sentRequests.count, 1)
    }

    func testRefreshesAgainNearExpiry() async throws {
        let http = FakeHTTPClient([
            .json(#"{"access_token":"at1","expires_in":100}"#),
            .json(#"{"access_token":"at2","expires_in":3600}"#),
        ])
        let clock = FixedClock(Date(timeIntervalSince1970: 1000))
        let provider = GoogleTokenProvider(
            config: config, http: http,
            secrets: InMemorySecretStore([SecretKey.googleRefreshToken: "rt"]), clock: clock)
        let tok3 = try await provider.accessToken()
        XCTAssertEqual(tok3, "at1")
        clock.advance(by: 50)   // 50s left < the 60s early-refresh margin
        let tok4 = try await provider.accessToken()
        XCTAssertEqual(tok4, "at2")
        XCTAssertEqual(http.sentRequests.count, 2)
    }

    func testStoresRotatedRefreshToken() async throws {
        let secrets = InMemorySecretStore([SecretKey.googleRefreshToken: "old"])
        let http = FakeHTTPClient([.json(#"{"access_token":"a","refresh_token":"new","expires_in":3600}"#)])
        let provider = GoogleTokenProvider(config: config, http: http, secrets: secrets,
                                           clock: FixedClock(Date(timeIntervalSince1970: 1)))
        _ = try await provider.accessToken()
        XCTAssertEqual(try secrets.get(SecretKey.googleRefreshToken), "new",
                       "a rotated refresh token must be persisted or the next refresh fails")
    }

    func testInvalidateForcesRefresh() async throws {
        let http = FakeHTTPClient([
            .json(#"{"access_token":"at1","expires_in":3600}"#),
            .json(#"{"access_token":"at2","expires_in":3600}"#),
        ])
        let provider = GoogleTokenProvider(
            config: config, http: http,
            secrets: InMemorySecretStore([SecretKey.googleRefreshToken: "rt"]),
            clock: FixedClock(Date(timeIntervalSince1970: 1)))
        let tok5 = try await provider.accessToken()
        XCTAssertEqual(tok5, "at1")
        await provider.invalidate()
        let tok6 = try await provider.accessToken()
        XCTAssertEqual(tok6, "at2")
    }

    /// The provider must satisfy the closure signature LiveGoogleCalendarClient already expects.
    func testTokenClosureDrivesTheCalendarClient() async throws {
        let events = #"{"items":[],"nextSyncToken":"tok"}"#
        let http = FakeHTTPClient([
            .json(#"{"access_token":"live-at","expires_in":3600}"#),   // token refresh
            .json(events),                                              // calendar call
        ])
        let provider = GoogleTokenProvider(
            config: config, http: http,
            secrets: InMemorySecretStore([SecretKey.googleRefreshToken: "rt"]),
            clock: FixedClock(Date(timeIntervalSince1970: 1)))
        let client = LiveGoogleCalendarClient(http: http, internalDomains: ["4site.org"],
                                              accessToken: provider.tokenClosure(),
                                              clock: FixedClock(Date(timeIntervalSince1970: 1)))
        let page = try await client.fetchEvents(calendarId: "primary", syncToken: nil, timeMin: nil, timeMax: nil)
        XCTAssertEqual(page.nextSyncToken, "tok")
        XCTAssertEqual(http.sentRequests.last?.headers["Authorization"], "Bearer live-at")
    }
}

/// A genuine localhost socket — no internet involved, so this runs headlessly.
final class LoopbackReceiverTests: XCTestCase {
    func testReceivesTheRedirectQueryAndRepliesToTheBrowser() async throws {
        let receiver = LoopbackReceiver()
        let redirectURI = try receiver.start()
        XCTAssertTrue(redirectURI.hasPrefix("http://127.0.0.1:"), "must bind loopback, not a public interface")
        XCTAssertGreaterThan(receiver.port, 0)

        async let captured = receiver.waitForCallback(timeout: 10)

        // Simulate the browser being redirected to our listener.
        var request = URLRequest(url: URL(string: "\(redirectURI)/?code=the-code&state=the-state")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)

        let query = try await captured
        let parsed = GoogleOAuthRequests.parseCallback(query: query)
        XCTAssertEqual(parsed.code, "the-code")
        XCTAssertEqual(parsed.state, "the-state")
        // The browser gets a real page, not a hang.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Signed in"))
    }

    func testTimesOutRatherThanHangingForever() async throws {
        let receiver = LoopbackReceiver()
        _ = try receiver.start()
        do {
            _ = try await receiver.waitForCallback(timeout: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("timed out"))
        }
    }
}
