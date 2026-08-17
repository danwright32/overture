import Testing
import Foundation

// #2616: "lookup" meant two different things on two surfaces Dan reads back to back, and on 2026-08-13
// that collision is the whole reason he asked what a run summary was telling him.
//
// He pressed "Check again" on one show, whose help says "It costs one lookup". Three minutes later the
// run summary said "18 web lookups for 1 show, more than expected". Both sentences were true and they
// contradict each other as read: the honest reading of the pair is that a control promising one lookup
// spent eighteen and went over its allowance. The "web" prefix was carrying the entire distinction, and
// it does not survive being read as English, because a lookup on the web is what anybody would call the
// thing the button just bought.
//
// WHICH WORD MOVED, and why it is not the one the issue proposed. The issue suggested renaming the SHOW
// sense to "check". That was tried and rejected: "check" is already what the app calls the whole RUN (the
// button, the badge, "Check reachability for these 3 shows?"), so a cost line reading "5 checks, about 3
// minutes" would say five actions for the one action Dan is about to start. It trades one collision for
// another.
//
// So the SMALL unit moved instead, which is also the smaller change (three sentences rather than six) and
// the one that puts the visible words back in step with the stored ones: the run file has always called
// the show unit `lookups`, and the code has always called the small one `webCalls`. Only the copy was out
// of step.
//
// The vocabulary now nests, largest to smallest, one word each:
//
//   check      the action Dan starts. One press, one run, however many shows.
//   lookup     one show's research. The unit the allowance is sized in and the run file stores.
//   web call   one request inside a lookup. The thing there are eighteen of.
@Suite("One word per counted thing (#2616)")
struct OneWordPerCountedThingTests {

    private func summary(shows: Int, research: Int) -> ProbeSelection.Summary {
        ProbeSelection.Summary(dateCount: 1, showCount: shows, researchCount: research,
                               organisationCount: 1, performerHuntCount: 0, alreadyAnsweredCount: 0,
                               previouslyMissedCount: 0, estimatedSeconds: 120)
    }

    // Every sentence in the run summary that counts the small unit. Built through the real producer so
    // the guard cannot pass on a sentence nobody assembles.
    private func summaryNotes(total: Int?, denied: Int?, items: Int = 1) -> [String] {
        var outcome = PrepImporter.Outcome()
        outcome.webCalls = PrepResults.WebCalls(recorded: true, total: total, denied: denied,
                                                items: items, parties: items, capPerItem: 15,
                                                allowance: 15, overCap: total != nil)
        return PrepRunSummary.concernNotes(for: outcome)
    }

    // MARK: - The pair, read in the order Dan meets it

    // The contradiction itself, as one assertion. This is the ONLY ordering that shows it: each sentence
    // is perfectly clear alone, which is why neither diff could ever have caught this (L118).
    @Test func theButtonHelpAndTheSummaryThatFollowsItCountDifferentThings() {
        let help = ReachabilityCopy.checkAgainHelp
        let summary = summaryNotes(total: 18, denied: 1).joined(separator: " ")

        #expect(help.contains("one lookup"))
        #expect(summary.contains("18 web calls for 1 show"))
        // The word that collided appears in exactly one of the two, and it is the one whose unit the
        // allowance and the stored run file both use.
        #expect(!summary.contains("lookup"), "the summary is counting web calls, not lookups")
    }

    // MARK: - The rule, stated over every sentence rather than the pair

    // "lookup" is the show unit everywhere it appears, so every sentence using it is talking about the
    // thing the button buys. Enumerated over the real producers rather than by grepping the source,
    // because a source grep would pass on a comment ABOUT the word (L103).
    @Test func everySentenceSayingLookupMeansOneShowsResearch() {
        let showSense = [
            ReachabilityCopy.checkAgainHelp,
            ReachabilityProbeCopy.confirmMessage(dateLabel: "Tuesday", count: 1),
            ReachabilityProbeCopy.confirmMessage(dateLabel: "Tuesday", count: 3),
            ReachabilityProbeCopy.cancelSpendCaveat,
            ReachabilityProbeCopy.stoppingSpendNote,
            ProbeSelectionCopy.costLine(summary(shows: 3, research: 2)),
        ]
        // At least one of them has to actually use the word, or this test passes by describing nothing.
        #expect(showSense.contains { $0.contains("lookup") })
        for sentence in showSense {
            #expect(!sentence.contains("web call"),
                    "a show-unit sentence is counting web calls: \(sentence)")
        }
    }

    // And the small unit is never called a lookup, on any of the three sentences that count it.
    @Test func noSentenceCountingWebCallsCallsThemLookups() {
        // #2362: the refused line now needs a complete count and a meaningful share to speak at all, so
        // the fixtures here carry both. `total: nil` said nothing and left this asserting over one sentence.
        let counting = summaryNotes(total: 47, denied: 2) + summaryNotes(total: 2, denied: 1)
        #expect(!counting.isEmpty, "the producer said nothing, so this asserts nothing")
        for note in counting {
            #expect(!note.contains("lookup"), "still calling a web call a lookup: \(note)")
        }
    }

    // MARK: - The sentences themselves

    // Singular and plural, because the refused line reads for one as well as several and "1 web calls"
    // is the kind of thing a rename produces.
    @Test func theRefusedLineReadsForOneAndForSeveral() {
        #expect(summaryNotes(total: 2, denied: 1)
            .contains("1 web call refused: that research never happened"))
        #expect(summaryNotes(total: 4, denied: 2)
            .contains("2 web calls refused: that research never happened"))
    }

    // The measured run that prompted the issue: 18 calls for 1 show against an allowance of 15.
    @Test func theRunThatPromptedThisReadsHonestlyNow() {
        #expect(summaryNotes(total: 18, denied: nil)
            .contains("18 web calls for 1 show, more than expected"))
    }
}
