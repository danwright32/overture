import Testing
import Foundation

// #2989: a contact check that comes home empty records WHY, and nothing counted them.
//
// The vocabulary is not shades of one thing. `nothing_published` asserts that this show's act,
// performers and presenter publish no address anywhere, which is a claim about searches actually run.
// `no_one_identified` admits the run could not work out who to write to. Dan does a different thing with
// each, and the difference between them is the difference between a finished search and an untested
// claim.
//
// #2983 is what that costs. Twelve of twenty three empty answers were wrong: six shows claimed
// `nothing_published` about an organisation whose name the run had never been given, so the strongest
// available claim was made about the weakest available search. It was found because Dan happened to look
// at one card, recognise the company, and open its website.
//
// THE CROSS-CUT IS THE POINT. A list of counts by reason is a table nobody reads. What accuses is the
// one contradiction visible without opening a single card: a show whose check says nobody publishes an
// address, sitting next to the name of the producing organisation.
@Suite("Empty contact answers are counted by the reason they claim (#2989)")
struct EmptyAnswerReportTests {

    private func show(_ key: String, reason: Reachability.EmptyReason?, presenter: String? = nil,
                      verdict: Reachability.ProbeResult? = .noEmailFound,
                      probedAt: Date? = Date(timeIntervalSince1970: 1_780_000_000)) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "The Example Room",
                         performanceDate: "2026-12-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.presenter = presenter
        p.reachabilityProbedAt = probedAt
        p.reachabilityEmptyReason = reason
        // #3356 Phase 0.5: the verdict too, because the report now counts a reason only where the card
        // actually renders it, which is under `.noEmailFound` (`ProspectRowView`). These fixtures set a
        // reason and no verdict, which the old rule did not care about; under the new one that is a row
        // nothing ever judged rather than a claim, and every count here would read zero.
        //
        // Setting it makes the fixture the row it always meant: a show whose card says the sentence.
        // The cases where a reason sits under a DIFFERENT verdict, and where it sits under none, are
        // covered by `EmptyAnswerReportCountsOnlyClaimsTests` rather than by loosening this rule.
        p.reachabilityResult = verdict
        return p
    }

    // MARK: - The counts

    @Test func areportOverNoShowsIsEmptyRatherThanAllZeroes() {
        let report = EmptyAnswerReport.make(from: [])
        #expect(report.total == 0)
        #expect(report.byReason.isEmpty,
                "a row per reason over an empty store states nine zeroes, and a zero whose only input is a value nothing wrote is indistinguishable from a measurement (L90)")
    }

    @Test func eachReasonIsCountedUnderItself() {
        let report = EmptyAnswerReport.make(from: [
            show("a", reason: .nothingPublished),
            show("b", reason: .nothingPublished),
            show("c", reason: .noOneIdentified),
            show("d", reason: .onlyVenueContact),
        ])

        #expect(report.total == 4)
        #expect(report.count(of: .nothingPublished) == 2)
        #expect(report.count(of: .noOneIdentified) == 1)
        #expect(report.count(of: .onlyVenueContact) == 1)
        #expect(report.count(of: .onlyPressContact) == 0)
    }

    // A show with no empty reason is not an empty answer. It either has a contact or was never checked,
    // and counting it here would make every number an overstatement.
    @Test func ashowWithNoEmptyReasonIsNotCounted() {
        let report = EmptyAnswerReport.make(from: [show("a", reason: nil), show("b", reason: .nothingPublished)])
        #expect(report.total == 1)
    }

    // Ordered by count, biggest first, so the reason that dominates is the first thing read rather than
    // whichever happens to sort first alphabetically.
    @Test func thereasonsAreOrderedByHowManyClaimThem() {
        let report = EmptyAnswerReport.make(from: [
            show("a", reason: .noOneIdentified),
            show("b", reason: .nothingPublished),
            show("c", reason: .nothingPublished),
            show("d", reason: .nothingPublished),
            show("e", reason: .noOneIdentified),
            show("f", reason: .onlySocialProfile),
        ])
        #expect(report.byReason.map(\.reason) == [.nothingPublished, .noOneIdentified, .onlySocialProfile])
    }

    // MARK: - The cross-cut that accuses

    // #2983 exactly: a show whose check says nobody publishes an address, carrying the name of the
    // producing organisation. Six of those were wrong.
    @Test func nothingPublishedIsSplitByWhetherTheShowNamesAProducingOrganisation() {
        let report = EmptyAnswerReport.make(from: [
            show("a", reason: .nothingPublished, presenter: "Underbelly Theatre Company"),
            show("b", reason: .nothingPublished, presenter: "Sable Trio Presents"),
            show("c", reason: .nothingPublished, presenter: nil),
            // A presenter on a DIFFERENT reason is not part of this cross-cut: only
            // `nothingPublished` makes the claim this contradicts.
            show("d", reason: .noOneIdentified, presenter: "Meridian Arts"),
        ])

        #expect(report.nothingPublishedWithAPresenter == 2)
        #expect(report.nothingPublishedWithNoPresenter == 1)
    }

    // A presenter that is present and blank is no presenter. A stored empty string would otherwise be
    // counted as a named organisation and the accusation would be about nothing.
    @Test func ablankPresenterIsNoPresenter() {
        let report = EmptyAnswerReport.make(from: [
            show("a", reason: .nothingPublished, presenter: "   "),
            show("b", reason: .nothingPublished, presenter: ""),
        ])
        #expect(report.nothingPublishedWithAPresenter == 0)
        #expect(report.nothingPublishedWithNoPresenter == 2)
    }

    // MARK: - What it says out loud

    // Every reason gets a sentence, and the mapping is EXHAUSTIVE over the vocabulary, so a reason added
    // later breaks the build here rather than silently rendering as a raw string or as nothing (L113).
    @Test func everyReasonInTheVocabularyHasALabel() {
        for reason in Reachability.EmptyReason.allCases {
            #expect(!EmptyAnswerReport.label(for: reason).isEmpty,
                    Comment(rawValue: "\(reason.rawValue) has no sentence"))
        }
    }

    // MARK: - Built is not wired (L3)

    // The section exists and is rendered by the analytics sheet, so the counts above are numbers Dan can
    // reach rather than a report only this test has ever asked for (L46).
    @Test func theanalyticsSheetRendersTheSection() {
        let source = SourceGuardHelper.source("Overture/UI/OutcomePatternsView.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("EmptyAnswerSection()", in: source),
                "the empty answer counts are built and no screen shows them (#2989)")
    }

    // And it renders in EVERY branch of that sheet, which is the half a wiring check misses. It used to
    // be reachable only once the store had outcomes: a fresh store showed one sentence and neither
    // report, so the section Dan most needs early was the one he could not find (#1547).
    @Test func thesectionIsReachableBeforeThereAreAnyOutcomes() {
        let source = SourceGuardHelper.source("Overture/UI/OutcomePatternsView.swift")
        #expect(!source.isEmpty)
        let scrollFirst = source.range(of: "ScrollView {")
        let emptyLine = source.range(of: "No outcomes yet.")
        #expect(scrollFirst != nil && emptyLine != nil)
        #expect(scrollFirst!.lowerBound < emptyLine!.lowerBound,
                "the no-outcomes branch stands outside the scroll again, so neither report renders for a store with no outcomes (#1547)")
    }

    // The section says something in BOTH of its own states too. A heading over nothing reads as broken
    // rather than as nothing to report.
    @Test func thesectionSpeaksWhenThereAreNoEmptyAnswersAtAll() {
        #expect(!EmptyAnswerCopy.nothingEmpty.isEmpty)
        #expect(EmptyAnswerCopy.nothingEmpty != EmptyAnswerCopy.title,
                "the empty state restates the heading, which tells Dan nothing the line above it did not (#843)")
    }

    // Singular and plural are different sentences, not one with an "(s)" in it.
    @Test func thecountsReadAsEnglishAtOne() {
        #expect(EmptyAnswerCopy.summary(count: 1).contains("1 show has"))
        #expect(EmptyAnswerCopy.summary(count: 4).contains("4 shows have"))
        #expect(EmptyAnswerCopy.withAPresenter(1).contains("1 of those is"))
        #expect(EmptyAnswerCopy.withAPresenter(3).contains("3 of those are"))
    }

    // The cross-cut adds the CONTRADICTION, not the claim: the claim is on the row directly above it, so
    // repeating it there tells Dan nothing the line next to it did not (#843).
    @Test func thecrossCutDoesNotRestateTheRowAboveIt() {
        #expect(!EmptyAnswerCopy.withAPresenter(2).contains("publishes an address"),
                "the cross-cut repeats the reason label it sits under")
    }

    // The report says what it CANNOT tell, rather than letting the number imply it. Whether the run was
    // told the presenter's name is not recorded anywhere, so a row checked before #2983's fix and one
    // checked after are indistinguishable here, and a reader who assumes otherwise reads this as an
    // accusation about every one of them.
    @Test func thecrossCutSaysWhatItCannotSeparate() {
        let line = EmptyAnswerReport.presenterCaveat
        #expect(line.contains("told"),
                "the cross-cut does not say that whether the run was TOLD the name is not recorded")
    }
}
