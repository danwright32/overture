import Testing
import Foundation

// #2883 / #2884: what an OmniFocus sync failure IS, so the line can say why and the button can stop
// offering a retry that cannot work.
//
// The masthead said one sentence for every failure ("OmniFocus sync failing, so follow-up tasks may not
// be getting created") and always carried a "Sync now" button. For a deterministic fault that button
// re-runs identical work against identical state and fails identically, and the line does not change, so
// from Dan's side it looks like it did nothing (L148). Meanwhile the real reason was already stored under
// `omniFocusLastSyncError` and reachable only by reading the app's preferences from a terminal (L80).
//
// Classified ONCE, explicitly, rather than each surface reading the message its own way (L35).
@Suite("What kind of OmniFocus failure this is (#2883, #2884)")
struct OmniFocusFailureKindTests {

    // Permission is recorded as its own flag, so it is evidence rather than inference, and it is asked
    // FIRST: a denial recorded while some older message is still stored must not read as that message.
    @Test func permissionIsReadFromItsOwnFlagAndWinsOverAnyStoredText() {
        #expect(OmniFocusFailureKind.of(message: "OmniFocus needs Automation permission",
                                        permissionNeeded: true) == .permissionNeeded)
        #expect(OmniFocusFailureKind.of(message: "something else entirely",
                                        permissionNeeded: true) == .permissionNeeded)
    }

    // The #2882 partial failure: the run got through and OmniFocus refused specific shows. Deterministic
    // by nature, since nothing about those shows changes on a retry.
    @Test func aRunThatCouldNotUpdateNamedShowsIsDeterministic() {
        let message = OmniFocusSync.partialFailureMessage(
            failures: [OmniFocusSync.TaskFailure(action: .complete, naturalKey: "aurora|2026-11-14|carnegie",
                                                 recipientId: "r1", reason: "Invalid index")],
            attempted: 4)
        let kind = OmniFocusFailureKind.of(message: try! #require(message), permissionNeeded: false)

        #expect(kind == .refusedSomeShows)
        #expect(!kind.aRetryCouldClearIt,
                "nothing about those shows changes on a retry, so offering one is a control that cannot work")
    }

    // OmniFocus not being open is the transient one, and the only remedy is outside Overture.
    // The typed case is what a NEW failure carries: the client throws `.notRunning` on AppleScript's
    // -600, where the code is known, and the runner stores `"\(error)"`. The three AppleScript wordings
    // below it are for failures recorded BEFORE that case existed, which are still on disk.
    @Test func omniFocusNotRunningIsTransient() {
        for message in ["notRunning",
                        "Application isn't running.", "Can't get application \"OmniFocus\".",
                        "OmniFocus got an error: Application isn't running. (-600)"] {
            let kind = OmniFocusFailureKind.of(message: message, permissionNeeded: false)
            #expect(kind == .omniFocusNotRunning, Comment(rawValue: "\(message) read as \(kind)"))
            #expect(kind.aRetryCouldClearIt)
        }
    }

    // The mapping at its SOURCE, which the classifier tests above cannot reach: they feed strings, and a
    // string only carries `notRunning` because the client decided to throw it. Measured with
    // `scripts/mutate.sh`: deleting the -600 line was reported SURVIVED until this existed.
    @Test func theAppleScriptCodesAreTypedWhereTheyAreKnown() {
        #expect(AppleScriptOmniFocusClient.error(forAppleScriptCode: -600, message: "anything")
                == .notRunning)
        for denied in [-1743, -1744] {
            #expect(AppleScriptOmniFocusClient.error(forAppleScriptCode: denied, message: nil)
                    == .notPermitted)
        }
        // Anything else keeps its message, and a missing message names the code rather than nothing: an
        // empty reason is indistinguishable from a failure that recorded none (L67).
        #expect(AppleScriptOmniFocusClient.error(forAppleScriptCode: -1719, message: "Invalid index")
                == .scriptFailed("Invalid index"))
        #expect(AppleScriptOmniFocusClient.error(forAppleScriptCode: -42, message: nil)
                == .scriptFailed("code -42"))
    }

    // And the whole chain in one: what the client throws, rendered the way the runner stores it, read
    // back by the classifier. Each half is pinned above; this is that they FIT.
    @Test func whatTheClientThrowsIsWhatTheClassifierReads() {
        let thrown = AppleScriptOmniFocusClient.error(forAppleScriptCode: -600, message: "whatever")
        #expect(OmniFocusFailureKind.of(message: "\(thrown)", permissionNeeded: false)
                == .omniFocusNotRunning)
    }

    // Anything else is UNEXPLAINED, and unexplained keeps the retry. Not because a retry will work, but
    // because nothing here established that it cannot, and refusing on a guess would take away the one
    // remedy Dan has for a fault nobody has classified yet (L11).
    @Test func anythingElseIsUnexplainedAndKeepsTheRetry() {
        let kind = OmniFocusFailureKind.of(message: "AppleEvent timed out", permissionNeeded: false)
        #expect(kind == .unexplained)
        #expect(kind.aRetryCouldClearIt)
    }

    // An empty stored message is not a kind of failure, it is a missing reason, and it must not be read
    // as one of the specific ones.
    @Test func anEmptyMessageIsUnexplainedRatherThanAnything() {
        #expect(OmniFocusFailureKind.of(message: "", permissionNeeded: false) == .unexplained)
        #expect(OmniFocusFailureKind.of(message: "   ", permissionNeeded: false) == .unexplained)
    }

    // Every kind says something different, or the classification buys nothing: the whole complaint was
    // one sentence for four situations.
    @Test func everyKindReadsDifferently() {
        let lines = OmniFocusFailureKind.allCases.map { $0.line(reason: "the stored reason") }
        #expect(Set(lines).count == OmniFocusFailureKind.allCases.count)
        for line in lines { #expect(!line.isEmpty) }
    }

    // The deterministic one is the only one that withholds the button, and that is asserted over ALL of
    // them rather than sampled, so a kind added later has to answer the question.
    @Test func onlyTheDeterministicKindWithholdsTheRetry() {
        for kind in OmniFocusFailureKind.allCases {
            #expect(kind.aRetryCouldClearIt == (kind != .refusedSomeShows),
                    Comment(rawValue: "\(kind) disagrees with the rule about which failures a retry clears"))
        }
    }

    // The line for a refused run carries the STORED reason, because that reason already names the shows
    // and is the only actionable part. The others do not, because their reason is the kind itself.
    @Test func therefusedLineCarriesTheStoredReason() {
        let reason = "OmniFocus updated 3 of 4 reminders. It could not update Aurora Strings."
        #expect(OmniFocusFailureKind.refusedSomeShows.line(reason: reason).contains(reason))
    }
}
