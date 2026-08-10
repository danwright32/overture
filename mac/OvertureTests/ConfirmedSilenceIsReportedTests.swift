import Testing
import Foundation

// #2251: #2112 gave a closed-out silence its own value (`neverHeardBack`), stored apart from the default
// every sent show carries, precisely because a silence and a no are different results. Nothing read it.
// `OutcomeTally.lostReasons` was written on every pass and had no reader anywhere in the app, which is
// the shape L46 names: the write path really runs, so every is-this-used check says the field is alive
// while the purpose it was added for silently never happens.
@Suite("A confirmed silence is reported apart from a refusal (#2251)")
struct ConfirmedSilenceIsReportedTests {

    private func sample(_ outcome: ShowOutcome, contacted: Bool = true) -> OutcomeSample {
        OutcomeSample(wasContacted: contacted, outcome: .noResponse, dimension: "music",
                      showOutcome: outcome)
    }

    @Test func aSilenceAndARefusalAreCountedApart() {
        let tally = OutcomeStats.tally([sample(.neverHeardBack), sample(.neverHeardBack),
                                        sample(.theySaidNo)])

        #expect(tally.lost == 3)
        #expect(tally.lostReasons[.neverHeardBack] == 2)
        #expect(tally.lostReasons[.theySaidNo] == 1)
    }

    // The reader, which is what this issue is actually about.
    @Test func theReportNamesTheSilenceSeparately() throws {
        let tally = OutcomeStats.tally([sample(.neverHeardBack), sample(.neverHeardBack),
                                        sample(.theySaidNo)])

        let line = try #require(OutcomePatterns.lostSplitLine(tally))

        #expect(line == "2 never heard back · 1 they said no")
    }

    // The ORDER is the vocabulary's, not this line's, so the report cannot reshuffle between redraws or
    // disagree with the menu Dan closed the show out from.
    @Test func theOrderIsTheVocabularysOwn() throws {
        let tally = OutcomeStats.tally([sample(.turnedThemDown), sample(.theySaidNotNow),
                                        sample(.neverHeardBack)])

        let line = try #require(OutcomePatterns.lostSplitLine(tally))

        #expect(line == "1 never heard back · 1 they said not now · 1 I turned them down")
    }

    // A group with nothing lost says nothing, rather than a line of zeroes.
    @Test func nothingLostSaysNothing() {
        #expect(OutcomePatterns.lostSplitLine(OutcomeStats.tally([sample(.booked)])) == nil)
        #expect(OutcomePatterns.lostSplitLine(OutcomeTally()) == nil)
    }

    // An OPEN pitch is not a lost one, which is the distinction in the issue's title: the silence Dan
    // confirmed by closing the show out, against a pitch that simply has not heard back yet.
    @Test func aPitchStillWaitingIsNotACountedSilence() {
        let open = OutcomeSample(wasContacted: true, outcome: .noResponse, dimension: "music",
                                 showOutcome: nil)

        let tally = OutcomeStats.tally([open, sample(.neverHeardBack)])

        #expect(tally.noResponse == 1, "the open pitch is still waiting")
        #expect(tally.lostReasons[.neverHeardBack] == 1, "the closed-out one is a confirmed silence")
        #expect(OutcomePatterns.lostSplitLine(tally) == "1 never heard back")
    }

    // Counts, not a rate, so the low-sample suppression that hides a percentage over two shows must not
    // hide these. A pair of numbers is honest at any size.
    @Test func aSmallGroupStillReportsItsEndings() {
        let tally = OutcomeStats.tally([sample(.neverHeardBack)])

        #expect(OutcomePatterns.isLowSample(tally), "one show is below the rate threshold")
        #expect(OutcomePatterns.lostSplitLine(tally) == "1 never heard back")
    }

    // The counted phrase is the LABEL's own words, cased for use after a number, never a second phrasing
    // of the same fact: two wordings for one ending is #843 from the naming direction, and the report and
    // the menu would drift apart with nothing to notice.
    @Test func theCountedPhraseIsTheLabelsOwnWords() {
        for outcome in ShowOutcome.pitched {
            #expect(outcome.countedPhrase.lowercased() == outcome.label.lowercased(),
                    "\(outcome) says one thing on the menu and another in the report")
        }
    }

    // Both halves of the funnel end in the SAME value, so a year-end total can add them together, which
    // is the check the issue asked for on the inquiry side.
    @Test func anInquiryAndAShowRecordTheSameSilence() {
        let inquiry = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@example.test",
                              eventName: "A Recital")
        inquiry.sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        inquiry.outcome = .lostSoft

        #expect(InquiryReporting.ending(for: inquiry) == .neverHeardBack)
        #expect(ShowOutcome.neverHeardBack.rawValue == "never_heard_back")
    }
}

// The line is worth nothing if the report does not draw it. A guard and its wiring are two claims
// (#887), and a SwiftUI body cannot be reached from a test.
@Suite("The outcome report draws the lost split (#2251)")
struct LostSplitWiringTests {
    private var view: String { SourceGuardHelper.source("Overture/UI/OutcomePatternsView.swift") }

    @Test func theRowRendersTheLostSplit() {
        #expect(!view.isEmpty)
        #expect(view.contains("OutcomePatterns.lostSplitLine(tally)"))
    }

    // Outside the low-sample branch, deliberately: counts are honest where a percentage is not.
    @Test func theLostSplitIsNotSuppressedAtLowSample() throws {
        let row = try #require(SourceGuardHelper.between("private func patternRow(",
                                                          and: "private func bookingSplit(", in: view))
        let suppressed = try #require(SourceGuardHelper.between("if OutcomePatterns.isLowSample(tally)",
                                                                and: "if let lost =", in: row))
        #expect(!suppressed.contains("lostSplitLine"),
                "the split must sit outside the branch that hides a rate over a tiny group")
    }
}
