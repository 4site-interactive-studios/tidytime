import XCTest
import Foundation
import TidyCore
import TidyStore

/// The guardrails, enforced against the WHOLE tree rather than one type or one directory.
///
/// A QC pass demonstrated that the existing guards did not guard: a POST-to-Productive time-entry
/// writer, a ScreenCaptureKit screen reader in `TidyCapture`, and deleting the `SuggestionEngine`
/// call site all passed 401/401 tests. The G1 test only covered `ProductiveRequestBuilder`, so any
/// code constructing a `URLRequest` directly bypassed it; the G3 test only scanned one directory and
/// only looked for one symbol.
///
/// These are grep-shaped on purpose. They are cheap, they run on every commit, and they fail on the
/// thing a new contributor would actually write — which is what the previous tests did not do.
final class GuardrailEnforcementTests: XCTestCase {

    private func sources(_ relative: String) throws -> [(URL, String)] {
        let root = TestSupport.repoRoot().appendingPathComponent(relative)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(URL, String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            out.append((url, (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
        }
        XCTAssertFalse(out.isEmpty, "no sources found under \(relative)")
        return out
    }

    /// Comments explain guardrails, so they must not trip the greps that enforce them.
    private func code(_ src: String) -> String {
        src.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: G1 — v1 never writes to Productive

    /// G1 is specifically "no writes to **Productive**", not "no POST anywhere" — the Google OAuth
    /// token exchange and the AI providers legitimately POST, and conflating those with a data write
    /// produces a test that cries wolf and gets deleted.
    ///
    /// So: any file that talks to Productive must contain no mutating method. That catches the
    /// realistic violation — a "log it to Productive" feature added to the Productive client or a
    /// new file next to it — which the old builder-only test did not.
    func testNoMutatingMethodInAnyFileThatTalksToProductive() throws {
        for (url, src) in try sources("Packages/TidyKit/Sources") {
            let body = code(src)
            guard body.contains("productive.io") || url.lastPathComponent.hasPrefix("Productive") else { continue }
            for method in ["\"POST\"", "\"PUT\"", "\"PATCH\"", "\"DELETE\""] {
                // The read-only guard itself has to name the methods it rejects, so the builder and
                // its test are the one place these strings are legitimate.
                if url.lastPathComponent == "ProductiveClient.swift", body.contains("readOnlyViolation") { continue }
                XCTAssertFalse(body.contains(method),
                               "G1: \(method) in \(url.lastPathComponent), which talks to Productive. "
                             + "v1 is read-only; a write belongs in v2 with audit + undo designed properly.")
            }
        }
    }

    /// The structural half: the Productive client must reach the network ONLY through the read-only
    /// builder. A new method calling `http.send` directly would skip the guard entirely.
    func testProductiveClientOnlyRequestsThroughTheReadOnlyBuilder() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot()
                .appendingPathComponent("Packages/TidyKit/Sources/TidyIngest/ProductiveClient.swift"),
            encoding: .utf8)
        let body = code(src)
        XCTAssertTrue(body.contains("builder.get("), "the client should build requests via builder.get")
        XCTAssertFalse(body.contains("URLRequest("),
                       "G1: ProductiveClient constructs a URLRequest directly, bypassing the "
                     + "read-only builder that is the guardrail's only enforcement point.")
    }

    /// `httpMethod` is how a raw `URLRequest` write would be spelled, bypassing the builder entirely.
    func testNoRawURLRequestMutationOutsideTheHTTPLayer() throws {
        for (url, src) in try sources("Packages/TidyKit/Sources") where url.lastPathComponent != "HTTP.swift" {
            XCTAssertFalse(code(src).contains("httpMethod ="),
                           "G1: \(url.lastPathComponent) sets httpMethod directly. All requests must "
                         + "go through HTTPRequest so the read-only guard can see them.")
        }
    }

    // MARK: G3 — no Screen Recording, ever

    /// Widened from "CGWindowList in TidyCapture" to every screen-capture API in every target.
    /// ScreenCaptureKit did not exist in the original test and is the modern way to get this wrong.
    func testNoScreenCaptureAPIAnywhere() throws {
        let banned = ["CGWindowList", "ScreenCaptureKit", "SCStream", "SCShareableContent",
                      "CGDisplayCreateImage", "CGWindowListCreateImage"]
        for (url, src) in try sources("Packages/TidyKit/Sources") {
            let body = code(src)
            for symbol in banned {
                XCTAssertFalse(body.contains(symbol),
                               "G3: \(symbol) in \(url.lastPathComponent). Window titles come from "
                             + "the Accessibility API; requesting Screen Recording is a design failure.")
            }
        }
    }

    /// The entitlement/usage-description side: declaring the capability is as bad as calling it.
    func testAppDeclaresNoScreenRecordingUsage() throws {
        let plist = TestSupport.repoRoot().appendingPathComponent("App/Info.plist")
        let text = (try? String(contentsOf: plist, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.isEmpty, "App/Info.plist not found")
        for key in ["NSScreenCaptureUsageDescription", "kTCCServiceScreenCapture"] {
            XCTAssertFalse(text.contains(key), "G3: Info.plist declares \(key)")
        }
    }

    // MARK: G6 — secrets live in the Keychain only

    /// Config is the file a user hand-edits and might paste into a ticket. It must have no field
    /// that could hold a credential.
    func testConfigHasNoSecretShapedFields() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot()
                .appendingPathComponent("Packages/TidyKit/Sources/TidyCore/Config.swift"),
            encoding: .utf8)
        for banned in ["token", "secret", "apiKey", "api_key", "password", "credential"] {
            let hits = code(src).lowercased().components(separatedBy: banned.lowercased()).count - 1
            // `google.client_secret` is referenced in a comment as living in the Keychain; code must
            // not declare a stored property for any of these.
            XCTAssertEqual(hits, 0,
                           "G6: Config.swift mentions '\(banned)' in code. Secrets belong in the "
                         + "Keychain via SecretStore — config.json is plaintext and gitignored, not safe.")
        }
    }

    /// Nothing credential-shaped may be committed.
    ///
    /// Matches a prefix followed by enough characters to be a real token — the bare prefixes appear
    /// legitimately in UI copy ("paste your xoxp-… token") and in docs, and failing on those would
    /// make this test noise that someone deletes rather than a guard someone trusts.
    func testNoCredentialShapedLiteralsInSources() throws {
        let prefixes = ["xoxp-", "xoxb-", "sk-ant-api", "AIzaSy", "fw_"]
        for (url, src) in try sources("Packages/TidyKit/Sources") {
            for prefix in prefixes {
                var search = src[...]
                while let r = search.range(of: prefix) {
                    let tail = search[r.upperBound...].prefix(12)
                    let realistic = tail.count >= 12 && tail.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                    XCTAssertFalse(realistic,
                                   "G6: credential-shaped literal starting '\(prefix)' in \(url.lastPathComponent)")
                    search = search[r.upperBound...]
                }
            }
            for pem in ["-----BEGIN RSA", "-----BEGIN PRIVATE", "-----BEGIN OPENSSH"] {
                XCTAssertFalse(src.contains(pem), "G6: private key material in \(url.lastPathComponent)")
            }
        }
    }

    // MARK: The class defect — jobs that exist and are never invoked

    /// Every job below was written, tested, and never called in production; six were discovered that
    /// way and wired. Nothing in the suite noticed, because a job that is never invoked cannot fail.
    /// This pins the call sites so deleting one is a test failure rather than a silent regression.
    func testPipelineJobsHaveProductionCallSites() throws {
        let env = try String(
            contentsOf: TestSupport.repoRoot()
                .appendingPathComponent("Packages/TidyKit/Sources/TidySurface/AppEnvironment.swift"),
            encoding: .utf8)
        let body = code(env)
        for job in ["SessionBuildJob(", "DayClassifier(", "EntityBootstrap(",
                    "SuggestionEngine(", "ResolutionQuestionGenerator(", "RetentionJob("] {
            XCTAssertTrue(body.contains(job),
                          "\(job) has no call site in runPipelineOnce. The table it writes will sit "
                        + "at zero rows and nothing will report it — this repo's signature failure.")
        }
    }
}
