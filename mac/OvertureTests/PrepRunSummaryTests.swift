import Testing
import Foundation

// The actual sentences a finished Prep run says to Dan.
//
// These were built inside RootView's SwiftUI body, where no test could reach them (#863: a rule computed
// in a view has already drifted twice here under a green suite). #876 pulled them out, so the copy Dan
// reads is now guarded like any other rule.
@Suite("What a finished Prep run tells Dan (#876)")
struct PrepRunSummaryTests {

    private func outcome(drafted: Int = 0, skippedEdited: Int = 0, unmatched: [String] = [],
                         missing: [String] = [], saveFailed: Bool = false,
                         matchDataWarning: String? = nil) -> PrepImporter.Outcome {
        var o = PrepImporter.Outcome()
        o.drafted = drafted
        o.skippedEdited = skippedEdited
        o.unmatchedKeys = unmatched
        o.missingKeys = missing
        o.saveFailed = saveFailed
        o.matchDataWarning = matchDataWarning
        return o
    }

    // THE issue. The run was given 5 and answered 3, and the 2 it dropped now have a sentence.
    @Test func aRunThatCameBackShortSaysSoAndPromisesTheRetry() {
        let notes = PrepRunSummary.notes(for: outcome(drafted: 3, missing: ["b", "d"]))

        #expect(notes == ["3 drafted", "2 didn't come back, they'll be retried"])
    }

    // A run that answered everything must not mention a shortfall at all. The whole value of this warning
    // is that it means something when it appears.
    @Test func aRunThatAnsweredEverythingSaysNothingAboutAShortfall() {
        let notes = PrepRunSummary.notes(for: outcome(drafted: 5))

        #expect(notes == ["5 drafted"])
        #expect(!notes.contains { $0.contains("didn't come back") })
    }

    // A dropped show and a result matching no prospect are DIFFERENT failures and read as different
    // sentences. Collapsing them would tell Dan the wrong story about which half broke.
    @Test func aDroppedShowAndAnUnmatchedResultAreToldApart() {
        let notes = PrepRunSummary.notes(for: outcome(drafted: 1, unmatched: ["ghost"], missing: ["b"]))

        #expect(notes == ["1 drafted", "1 didn't match", "1 didn't come back, they'll be retried"])
    }

    // The failure paths still speak, and the good news comes first so a mostly-fine run does not read as
    // a disaster.
    @Test func aRunThatSavedNothingStillSaysWhatItDraftedAndThatItFailed() {
        let notes = PrepRunSummary.notes(for: outcome(drafted: 2, saveFailed: true,
                                                      matchDataWarning: "past clients unreadable"))

        #expect(notes == ["2 drafted", "couldn't save, try again", "past clients unreadable"])
    }

    // A run with nothing to report says nothing at all, rather than an empty "Prep:" prefix.
    @Test func aRunWithNothingToReportSaysNothing() {
        #expect(PrepRunSummary.notes(for: outcome()).isEmpty)
    }

    @Test func aRunThatKeptDansEditsSaysSo() {
        #expect(PrepRunSummary.notes(for: outcome(drafted: 1, skippedEdited: 2))
                == ["1 drafted", "2 kept your edits"])
    }

    // Dan (2026-07-18): the toolbar status slot also carries an unattended scout's warning, so a routine "N drafted"
    // tally (the shows already show it) doesn't belong there. A run that only drafted, with nothing else
    // to say, has nothing worth the toolbar's attention.
    @Test func aRoutineRunHasNoAttentionMessage() {
        let message = PrepRunSummary.attentionMessage(for: outcome(drafted: 3, skippedEdited: 1),
                                                       voiceGuidanceLeaked: false, guidanceNotesRestored: false)
        #expect(message == nil)
    }

    // The shortfall promise still has to reach him, just without the routine "N drafted" ahead of it.
    @Test func aShortfallStillProducesAnAttentionMessageWithoutTheRoutineTally() {
        let message = PrepRunSummary.attentionMessage(for: outcome(drafted: 3, missing: ["b", "d"]),
                                                       voiceGuidanceLeaked: false, guidanceNotesRestored: false)
        #expect(message == "Prep: 2 didn't come back, they'll be retried")
    }

    @Test func aSaveFailureStillProducesAnAttentionMessage() {
        let message = PrepRunSummary.attentionMessage(for: outcome(drafted: 2, saveFailed: true),
                                                       voiceGuidanceLeaked: false, guidanceNotesRestored: false)
        #expect(message == "Prep: couldn't save, try again")
    }

    @Test func aVoiceGuidanceLeakStillProducesAnAttentionMessageEvenWithNoOtherConcern() {
        let message = PrepRunSummary.attentionMessage(for: outcome(drafted: 4),
                                                       voiceGuidanceLeaked: true, guidanceNotesRestored: false)
        #expect(message == "Prep: voice guidance leaked a name, quarantined")
    }

    @Test func restoredGuidanceNotesStillProducesAnAttentionMessage() {
        let message = PrepRunSummary.attentionMessage(for: outcome(drafted: 4),
                                                       voiceGuidanceLeaked: false, guidanceNotesRestored: true)
        #expect(message == "Prep: restored your guidance notes")
    }
}
