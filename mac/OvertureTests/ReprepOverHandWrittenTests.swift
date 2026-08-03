import Testing
import Foundation

// #2007, decision 2 (Dan, 2026-08-03): re-prep IS offered on a draft he wrote himself, and it confirms
// before replacing hand-written text, because clobbering text he typed is the one unrecoverable outcome
// on this path.
//
// Note #2014: the BULK re-prep has no per-show confirm at all, so this covers only the single-row
// control until that is done.
@MainActor
@Suite("Re-prepping over a hand-written draft (#2007)")
struct ReprepOverHandWrittenTests {
    private func prospect() -> Prospect {
        Prospect(naturalKey: "k", groupName: "Bargemusic", discipline: "classical", venue: "Boathouse",
                 performanceDate: "2026-11-14", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "booked", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - What is confirmed, and why

    @Test func redraftingHandWrittenTextAsksFirstAndSaysWhatItWillReplace() {
        #expect(ReprepRequest.confirmation(mode: .draftOnly, writtenByDan: true,
                                           lastServedAt: nil, now: now)
                == "This replaces the email you wrote yourself with an AI draft. Replace it?")
    }

    // Finding contacts never touches the text, so there is nothing to warn about.
    @Test func findingContactsOnlyNeedsNoConfirmationOnHandWrittenText() {
        #expect(ReprepRequest.confirmation(mode: .contactsOnly, writtenByDan: true,
                                           lastServedAt: nil, now: now) == nil)
    }

    // The hand-written warning outranks the cooldown one: losing his own words is the worse outcome, and
    // two alerts in a row for one click is not a warning, it is a habit of clicking through.
    @Test func theHandWrittenWarningWinsOverTheCooldownWarning() {
        #expect(ReprepRequest.confirmation(mode: .both, writtenByDan: true,
                                           lastServedAt: now.addingTimeInterval(-60), now: now)
                == "This replaces the email you wrote yourself with an AI draft. Replace it?")
    }

    @Test func anAiDraftInsideTheCooldownStillAsksTheCooldownQuestion() {
        #expect(ReprepRequest.confirmation(mode: .draftOnly, writtenByDan: false,
                                           lastServedAt: now.addingTimeInterval(-60), now: now)
                == "This was re-prepped just now. Redo it anyway?")
    }

    @Test func anOrdinaryRedraftAsksNothing() {
        #expect(ReprepRequest.confirmation(mode: .draftOnly, writtenByDan: false,
                                           lastServedAt: nil, now: now) == nil)
    }

    // MARK: - What happens once he confirms

    // Having confirmed, the redraft has to actually LAND. The marker is what makes a Prep run refuse to
    // overwrite this text, so asking for an AI draft and leaving the marker in place would spend a run
    // whose result is then thrown away: a request that looks granted and silently does nothing.
    @Test func askingForARedraftReleasesTheTextToTheRun() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")

        ReprepRequest.apply(.draftOnly, to: p)

        #expect(p.reprepDraftRequested)
        #expect(p.draftWrittenByDan == false)
    }

    // Contacts-only never touches the words, so the text stays his and stays protected.
    @Test func askingOnlyForContactsLeavesTheTextHisAndStillProtected() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")

        ReprepRequest.apply(.contactsOnly, to: p)

        #expect(p.reprepContactsRequested)
        #expect(p.draftWrittenByDan)
    }

    // A draft request the send gate REFUSES (something has already gone out under this body) must not
    // release the text either: nothing is going to redraft it, so dropping the protection would leave the
    // next unrelated run free to overwrite words he wrote.
    @Test func aRefusedRedraftLeavesTheProtectionInPlace() {
        let p = prospect()
        p.writeManualDraft(subject: "s", body: "b")
        p.sentAt = now

        ReprepRequest.apply(.both, to: p)

        #expect(p.reprepDraftRequested == false)
        #expect(p.draftWrittenByDan)
    }
}
