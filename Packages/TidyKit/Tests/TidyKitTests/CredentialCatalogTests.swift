import XCTest
import Foundation
import TidyCore
import TidySurface

/// The Credentials tab renders `CredentialCatalog` verbatim — these tests pin its completeness and
/// the lock-once-set picker rules the user asked for.
final class CredentialCatalogTests: XCTestCase {
    func testCatalogCoversEverySecretKeyExactly() {
        XCTAssertEqual(Set(CredentialCatalog.all.map(\.key)), Set(SecretKey.all))
        XCTAssertEqual(CredentialCatalog.all.count, SecretKey.all.count,
                       "an 8th SecretKey needs catalog metadata before it ships")
    }

    func testEveryEntryHasNamePurposeAndSteps() {
        for info in CredentialCatalog.all {
            XCTAssertFalse(info.displayName.isEmpty, "\(info.key) has no display name")
            XCTAssertFalse(info.purpose.isEmpty, "\(info.key) has no purpose line")
            XCTAssertFalse(info.steps.isEmpty, "\(info.key) has no steps")
            XCTAssertNotEqual(info.displayName, info.key, "\(info.key) display name is the raw key")
            if info.pastable {
                XCTAssertFalse(info.links.isEmpty, "\(info.key) is pastable but links nowhere")
            }
        }
    }

    /// The steps must speak human, not developer: no raw dotted key names inside step prose.
    func testStepsAvoidRawDottedKeys() {
        for info in CredentialCatalog.all {
            let prose = info.steps.joined(separator: " ")
            for key in SecretKey.all {
                XCTAssertFalse(prose.contains(key),
                               "\(info.key) steps leak the raw key name \(key)")
            }
        }
    }

    func testRefreshTokenIsNotPastableAndPointsAtSignIn() {
        let info = CredentialCatalog.info(for: SecretKey.googleRefreshToken)!
        XCTAssertFalse(info.pastable)
        XCTAssertTrue(info.steps.joined(separator: " ").contains("Sign in with Google"))
    }

    // MARK: lock-once-set (the user's requirement 2)

    func testPickerExcludesPresentKeys() {
        let choices = CredentialCatalog.pickerChoices(present: [SecretKey.productiveToken])
        XCTAssertFalse(choices.contains(SecretKey.productiveToken), "a set key must be locked")
        XCTAssertTrue(choices.contains(SecretKey.fathomKey))
    }

    func testPickerNeverOffersRefreshToken() {
        XCTAssertFalse(CredentialCatalog.pickerChoices(present: []).contains(SecretKey.googleRefreshToken))
    }

    func testPickerEmptyWhenEverythingSet() {
        XCTAssertTrue(CredentialCatalog.pickerChoices(present: SecretKey.all).isEmpty)
    }

    func testRemovalUnlocksTheKeyAgain() {
        let locked = CredentialCatalog.pickerChoices(present: [SecretKey.slackUserToken])
        XCTAssertFalse(locked.contains(SecretKey.slackUserToken))
        let unlocked = CredentialCatalog.pickerChoices(present: [])
        XCTAssertTrue(unlocked.contains(SecretKey.slackUserToken))
    }

    func testNextSelectionAdvancesAndTerminates() {
        // Saving productive with nothing else present → next open slot is fathom.
        XCTAssertEqual(CredentialCatalog.nextSelection(afterSaving: SecretKey.productiveToken, present: []),
                       SecretKey.fathomKey)
        // Saving the LAST open key → nil (the view shows "Everything is set up ✓").
        let allButAnthropic = SecretKey.all.filter { $0 != SecretKey.anthropicKey }
        XCTAssertNil(CredentialCatalog.nextSelection(afterSaving: SecretKey.anthropicKey,
                                                     present: allButAnthropic))
    }

    /// Doctor tips and the Credentials tab must use the same names forever.
    func testNamingShimDelegatesToCatalog() {
        for info in CredentialCatalog.all {
            XCTAssertEqual(CredentialCatalogNaming.displayName(for: info.key), info.displayName)
        }
    }
}
