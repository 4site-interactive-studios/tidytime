import XCTest
import Foundation
import GRDB
import TidyCore
import TidyStore
import TidyCapture
import TidyIngest

/// G10 — captured and mirrored content is credential-scrubbed before the insert.
///
/// The 2026-09-08 audit found third-party credentials in the live database: OAuth authorization
/// codes in `activity_samples.url`, a Google client secret in a `pd_tasks.description`. None of the
/// prior reviews saw it, because every review read code and tests, and a verbatim store looks
/// correct in code. These tests seed credential-shaped input through the real capture and ingest
/// paths and then assert the database does not contain it — the assertion that was missing.
final class CredentialScrubTests: XCTestCase {

    // Realistic shapes, none real. Long enough to satisfy the "this is a token" length floors.
    // Built at runtime, never written as literals: GitHub push protection (and this repo's own
    // guardrail) reject token-shaped strings in source, fake or not.
    private let authCode = ["4/0A", "VG7fiQ3bZ9kL2mNpQrStUvWxYz01234567890abcdefghijklmnop"].joined()
    private let clientSecret = ["GOCSPX", "AbCdEfGhIjKlMnOpQrStUvWxYz01"].joined(separator: "-")
    private let googleAPIKey = ["AIzaSy", "A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R"].joined()
    private let slackToken = ["xoxp", "1234567890", "1234567890", "1234567890", "abcdefabcdefabcdef"].joined(separator: "-")

    // MARK: URLScrubber — the rule

    func testQueryStringIsDroppedByDefault() {
        let s = URLScrubber()
        XCTAssertEqual(s.scrub("https://claude.ai/login/popup-google-auth?code=\(authCode)&state=xyz"),
                       .store("https://claude.ai/login/popup-google-auth"))
    }

    func testFragmentIsAlwaysDropped() {
        // The OAuth implicit flow delivers the token in the fragment.
        let s = URLScrubber(identityQueryKeys: ["v"])
        XCTAssertEqual(s.scrub("https://app.example/cb#access_token=ya29.abc&token_type=bearer"),
                       .store("https://app.example/cb"))
    }

    func testAllowlistedIdentityKeysSurvive() {
        let s = URLScrubber(identityQueryKeys: ["v", "project"])
        XCTAssertEqual(s.scrub("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&code=\(authCode)"),
                       .store("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testDenylistedKeysCannotBeAllowlisted() {
        // A config mistake must not reopen the hole.
        let s = URLScrubber(identityQueryKeys: ["token", "code", "v"])
        XCTAssertEqual(s.scrub("https://x.example/p?token=abcdefgh12345678&v=1&code=\(authCode)"),
                       .store("https://x.example/p?v=1"))
    }

    func testUserinfoIsDropped() {
        XCTAssertEqual(URLScrubber().scrub("https://bryan:hunter22@host.example/path"),
                       .store("https://host.example/path"))
    }

    func testLoopbackWithQueryIsDroppedEntirely() {
        // TidyTime's own Google sign-in redirect.
        let s = URLScrubber()
        XCTAssertEqual(s.scrub("http://127.0.0.1:53211/?code=\(authCode)&state=abc"), .drop)
        XCTAssertEqual(s.scrub("http://localhost:3000/callback?code=\(authCode)"), .drop)
        XCTAssertEqual(s.scrub("http://localhost:3000/#access_token=x"), .drop)
    }

    func testLoopbackWithoutQueryIsRecorded() {
        // A local dev server is real work — `web:localhost` carries hours of sessions.
        XCTAssertEqual(URLScrubber().scrub("http://localhost:3000/dashboard"),
                       .store("http://localhost:3000/dashboard"))
    }

    func testOddURLsStillLoseTheQuery() {
        // Whether Foundation parses these (newer releases percent-encode a space) or the fallback
        // cuts at `?`, the property is the same: nothing after the path survives.
        for url in ["https://x.example/a b?code=\(authCode)", "https://x.example/a|b?code=\(authCode)#f",
                    "not a url at all?code=\(authCode)"] {
            guard case .store(let out) = URLScrubber().scrub(url) else { return XCTFail("dropped \(url)") }
            XCTAssertFalse(out.contains("code="), out)
            XCTAssertFalse(out.contains("?"), out)
            XCTAssertFalse(out.contains("#"), out)
        }
        XCTAssertEqual(URLScrubber.fallbackStrip("x?y#z"), "x")
    }

    func testCleanURLsAreUntouched() {
        for url in ["https://app.productive.io/2650-4site/tasks/task/18609405",
                    "https://docs.google.com/document/d/abc123/edit",
                    "chrome-extension://abcdefghijklmnop/popup.html"] {
            XCTAssertEqual(URLScrubber().scrub(url), .store(url), url)
        }
        XCTAssertEqual(URLScrubber().scrub(nil), .store(""))
    }

    func testConfigKnobFeedsTheScrubber() {
        var capture = Config.Capture()
        capture.identityQueryKeys = ["doc"]
        XCTAssertEqual(URLScrubber(capture).scrub("https://x.example/?doc=9&code=\(authCode)"),
                       .store("https://x.example/?doc=9"))
    }

    // MARK: Redactor — the new shapes

    func testRedactorCoversTheShapesFoundLive() {
        for sample in [clientSecret, googleAPIKey, authCode, ["4%2F0A", "VG7fiQ3bZ9kL2mNpQrStUvWxYz0123456789"].joined(),
                       ["ghp", "abcdefghijklmnopqrstuvwxyz0123456789"].joined(separator: "_"),
                       ["fw", "abcdefghijklmnopqrstuvwxyz"].joined(separator: "_"),
                       ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "abcdefghijklmnop"].joined(separator: "."),
                       "https://x.example/?access_token=abcdefgh12345678"] {
            let out = Redactor.redact("prefix \(sample) suffix")
            XCTAssertFalse(out.contains(sample), "not redacted: \(sample)")
            XCTAssertTrue(out.hasPrefix("prefix "), out)
        }
    }

    func testRedactorLeavesProseAlone() {
        for text in ["the access token expired, ask for a new code",
                     "postcode=SW1A 1AA for the office", "Define RaiseMore: Single Step Lightbox MVP Metrics",
                     "password reset flow — needs a ticket"] {
            XCTAssertEqual(Redactor.redact(text), text)
        }
    }

    // MARK: Capture path — the row never exists

    private func capture(tab: BrowserTab, pageText: String? = nil, scrubber: URLScrubber = URLScrubber())
        throws -> (AppDatabase, CaptureCoordinator) {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1000))
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.google.Chrome",
                                                             appName: "Chrome", isBrowser: true))
        let adapter = FakeBrowserAdapter(tab: tab, pageText: pageText)
        let coord = CaptureCoordinator(reader: reader, browser: adapter,
                                       recorder: SampleRecorder(db: db, clock: clock, scrubber: scrubber),
                                       scrubber: scrubber)
        return (db, coord)
    }

    func testOwnOAuthRedirectIsNeverRecorded() throws {
        let (db, coord) = try capture(tab: BrowserTab(url: "http://127.0.0.1:53211/?code=\(authCode)&state=s",
                                                       title: "TidyTime — signed in"),
                                       pageText: "You can close this window. code=\(authCode)")
        XCTAssertFalse(try coord.poll())
        try coord.captureContent()
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 0)
        XCTAssertEqual(try db.tableRowCounts()["page_snapshots"], 0)
    }

    func testThirdPartySignInKeepsThePathAndLosesTheCode() throws {
        let (db, coord) = try capture(tab: BrowserTab(url: "https://claude.ai/login/popup-google-auth?code=\(authCode)&state=s",
                                                       title: "Claude"),
                                       pageText: "Signing you in… \(clientSecret)")
        XCTAssertTrue(try coord.poll())
        try coord.captureContent()
        let samples = try db.samples(from: 0, to: 2000)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].url, "https://claude.ai/login/popup-google-auth")
        let snapshotURLs = try db.writer.read { try String.fetchAll($0, sql: "SELECT url FROM page_snapshots") }
        XCTAssertEqual(snapshotURLs, ["https://claude.ai/login/popup-google-auth"])
        let texts = try db.pageTexts(from: 0, to: 2000)
        XCTAssertEqual(texts.count, 1)
        XCTAssertFalse(texts[0].contains(clientSecret))
        XCTAssertTrue(texts[0].contains(Redactor.mask))
        XCTAssertEqual(try CredentialScrub.violations(db), [:])
    }

    func testSampleRecorderScrubsWithoutTheCoordinator() throws {
        // The last line: a caller that bypasses the coordinator still cannot store a credential.
        let db = try AppDatabase.inMemory()
        let recorder = SampleRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 1000)))
        let id = try recorder.record(FrontmostContext(
            appBundleId: "com.google.Chrome", appName: "Chrome",
            windowTitle: "paste: \(slackToken)", isBrowser: true,
            url: "https://svc.eu01.miro.com/api/sign-in?code=\(authCode)"))
        _ = try recorder.recordPageText(sampleId: id, url: "https://svc.eu01.miro.com/api/sign-in?code=\(authCode)",
                                        title: nil, rawText: "key \(googleAPIKey) end")
        let sample = try db.samples(from: 0, to: 2000)[0]
        XCTAssertEqual(sample.url, "https://svc.eu01.miro.com/api/sign-in")
        XCTAssertFalse(sample.windowTitle?.contains(slackToken) ?? false)
        XCTAssertEqual(try CredentialScrub.violations(db), [:])
    }

    func testStoredURLIsStableWhenOnlyTheQueryChurns() throws {
        // Dedup keys on the stored URL, so a scrubbed URL must not create a snapshot per query.
        let (db, coord) = try capture(tab: BrowserTab(url: "https://x.example/p?msg=1", title: "X"),
                                       pageText: "body")
        _ = try coord.poll()
        try coord.captureContent()
        try coord.captureContent()
        XCTAssertEqual(try db.tableRowCounts()["page_snapshots"], 1)
    }

    // MARK: Ingest path — mirrored text is redacted

    func testProductiveTaskDescriptionAndNoteAreRedacted() async throws {
        let tasks = """
        { "data": [ {"id":"t1","type":"tasks","attributes":{"title":"Set up OAuth",
          "description":"client secret is \(clientSecret) and key \(googleAPIKey)","task_number":"1"},
          "relationships":{"project":{"data":{"type":"projects","id":"p1"}}}} ]}
        """
        let entries = """
        { "data": [ {"id":"te1","type":"time_entries","attributes":{"date":"2026-07-22","time":60,
          "note":"used \(slackToken)"},
          "relationships":{"person":{"data":{"type":"people","id":"me"}}}} ]}
        """
        let builder = ProductiveRequestBuilder(baseURL: URL(string: "https://api.productive.io/api/v2/")!,
                                               organizationId: "42", token: "t")
        let client = LiveProductiveClient(http: FakeHTTPClient([.json(tasks), .json(entries)]), builder: builder,
                                          clock: FixedClock(Date(timeIntervalSince1970: 1000)), sleeper: { _ in })
        let task = try await client.fetchTasks(assigneeId: nil)[0]
        XCTAssertFalse(task.description?.contains(clientSecret) ?? false)
        XCTAssertFalse(task.description?.contains(googleAPIKey) ?? false)
        XCTAssertTrue(task.description?.hasPrefix("client secret is ") ?? false, task.description ?? "nil")
        let entry = try await client.fetchTimeEntries(personId: "me", after: "2026-07-01", before: "2026-08-01")[0]
        XCTAssertFalse(entry.note?.contains(slackToken) ?? false)
    }

    // MARK: The one-shot purge — what was already stored

    func testMigrationRewritesExistingRows() throws {
        let db = try AppDatabase.inMemory()
        // Simulate pre-G10 rows by writing verbatim through SQL, as the old recorder did.
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO activity_samples (id, started_at, app_bundle_id, app_name, window_title, is_browser, url, source, created_at)
                VALUES (1, 1, 'com.google.Chrome', 'Chrome', 'Claude', 1, 'https://claude.ai/login?code=\(self.authCode)&state=s', 'switch', 1),
                       (2, 2, 'com.google.Chrome', 'Chrome', 'TidyTime', 1, 'http://127.0.0.1:5000/?code=\(self.authCode)', 'switch', 2),
                       (3, 3, 'com.google.Chrome', 'Chrome', 'Dev', 1, 'http://localhost:3000/app', 'switch', 3),
                       (4, 4, 'com.google.Chrome', 'Chrome', 'Docs', 1, 'https://docs.google.com/d/1/edit', 'switch', 4)
                """)
            try d.execute(sql: """
                INSERT INTO page_snapshots (sample_id, captured_at, url, title, content_hash, text, text_bytes)
                VALUES (2, 2, 'http://127.0.0.1:5000/?code=\(self.authCode)', 't', 'h', 'body', 4),
                       (1, 1, 'https://claude.ai/login?code=\(self.authCode)', 't', 'h2', 'secret \(self.clientSecret)', 4)
                """)
            try d.execute(sql: """
                INSERT INTO pd_tasks (id, project_id, title, description, closed, synced_at)
                VALUES ('t1', 'p1', 'OAuth', 'paste \(self.clientSecret) here', 0, 1)
                """)
        }
        let report = try db.writer.write { try CredentialScrub.apply($0) }
        XCTAssertEqual(report.rowsDropped, 2, "the loopback sample and its snapshot")
        XCTAssertEqual(report.urlsRewritten, 2, "the claude.ai sample and its snapshot")
        XCTAssertEqual(report.textsRedacted, 2, "the snapshot text and the task description")

        let urls = try db.writer.read { try String.fetchAll($0, sql: "SELECT url FROM activity_samples ORDER BY id") }
        XCTAssertEqual(urls, ["https://claude.ai/login", "http://localhost:3000/app", "https://docs.google.com/d/1/edit"])
        XCTAssertEqual(try db.tableRowCounts()["page_snapshots"], 1)
        let description = try db.writer.read { try String.fetchOne($0, sql: "SELECT description FROM pd_tasks") }
        XCTAssertEqual(description, "paste \(Redactor.mask) here")
        XCTAssertEqual(try CredentialScrub.violations(db), [:])
    }

    func testMigrationIsRegisteredAndIdempotent() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v3-credential-scrub"))
        let second = try db.writer.write { try CredentialScrub.apply($0) }
        XCTAssertEqual(second, CredentialScrub.Report())
    }

    // MARK: The guardrail — every text column, discovered not listed

    func testViolationScanCoversEveryTextColumnInTheSchema() throws {
        let db = try AppDatabase.inMemory()
        let columns = try db.writer.read { try CredentialScrub.textColumns($0) }
        let names = Set(columns.map { "\($0.table).\($0.column)" })
        for expected in ["activity_samples.url", "activity_samples.window_title", "page_snapshots.text",
                         "pd_tasks.description", "pd_time_entries.note", "slack_messages.text",
                         "sessions.title", "suggestions.note"] {
            XCTAssertTrue(names.contains(expected), "scan does not cover \(expected)")
        }
        // And it actually detects: plant one and watch it fire.
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO pd_tasks (id, project_id, title, description, closed, synced_at)
                VALUES ('t9', 'p1', 'x', 'leak \(self.clientSecret)', 0, 1)
                """)
        }
        XCTAssertEqual(try CredentialScrub.violations(db), ["pd_tasks.description": 1])
    }
}

private extension AppDatabase {
    func pageTexts(from: Int64, to: Int64) throws -> [String] {
        try pageTexts(from: from, to: to, limit: 10, host: nil)
    }
}

private extension CredentialScrub {
    static func violations(_ db: AppDatabase) throws -> [String: Int] {
        try db.writer.read { try violations($0) }
    }
}
