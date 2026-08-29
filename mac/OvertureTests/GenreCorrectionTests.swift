import Testing
import Foundation
import SwiftData

// #2688: a genre Dan corrects teaches the classifier nothing, so the same unreadable title comes back
// next week.
//
// His question, 2026-08-13: "does it learn from it at all? Like would setting it on every event help
// make the genre classifier better moving forward?" No. `EventClassifier` is a fixed keyword matcher
// with no input but its own vocabulary, and a correction did exactly two things: it locked that one row
// (every reader of `classificationOverriddenByDan` uses it to leave the row alone) and it moved one cell
// of the outcomes report.
//
// This is deliberately the cheapest useful version, NOT a learning loop. The classifier stays
// deterministic and reviewable; what was missing is the REPORT saying which words to add to it.
//
// Every test injects `now` (L130).
@MainActor
@Suite("Learning which words the genre classifier is missing (#2688)")
struct GenreCorrectionTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        GenreCorrection.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    @discardableResult
    private func show(_ ctx: ModelContext, title: String, presenter: String? = nil,
                      venue: String = "Merkin Hall", discipline: String = "other") -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title,
                                                             performanceDate: "2026-09-01",
                                                             venue: venue),
                         groupName: title, discipline: discipline, venue: venue,
                         performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.presenter = presenter
        ctx.insert(p)
        return p
    }

    // MARK: recording the correction

    // The row already stores the corrected value and the FACT of a correction. What was missing is the
    // classifier's original answer and the text it was judging, and neither can be recovered later:
    // `classificationOverriddenByDan` is a bare boolean, and re-running the classifier over an old row
    // would answer with TODAY's rules, which is a different question.
    @Test("correcting a genre records what the classifier read and what Dan said instead")
    func aCorrectionIsRecorded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, title: "Il Trittico", presenter: "Regina Opera Company")

        ClassificationOverride.correct(p, discipline: .opera, now: now, in: ctx)

        let recorded = try #require(GenreCorrection.all(in: ctx).first)
        #expect(recorded.classifierRead == "other")
        #expect(recorded.danSaid == "opera")
        #expect(recorded.title == "Il Trittico")
        #expect(recorded.presenter == "Regina Opera Company")
        #expect(recorded.correctedAt == now)
    }

    // A correction that agrees with the classifier teaches nothing and must not be counted as evidence
    // of a missing word: it would pad every group with rows where the vocabulary already worked.
    @Test("correcting a genre to the one already read records nothing")
    func agreeingWithTheClassifierRecordsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, title: "A Night of Opera", discipline: "opera")

        ClassificationOverride.correct(p, discipline: .opera, now: now, in: ctx)

        #expect(GenreCorrection.all(in: ctx).isEmpty)
    }

    // Assume it runs twice. Dan changing his mind on one row is one correction, not two votes.
    @Test("correcting the same show again replaces its record rather than adding a second")
    func correctingTwiceRecordsOnce() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, title: "Il Trittico")
        ClassificationOverride.correct(p, discipline: .opera, now: now, in: ctx)

        ClassificationOverride.correct(p, discipline: .music, now: now.addingTimeInterval(60), in: ctx)

        let all = GenreCorrection.all(in: ctx)
        #expect(all.count == 1)
        #expect(all.first?.danSaid == "music")
        #expect(all.first?.classifierRead == "other",
                "still what the CLASSIFIER read, not what he said a minute ago")
    }

    // MARK: the report

    // The point of the whole issue: which words to add to `EventClassifier`, in the order they would pay
    // off. Grouped on the text the classifier ACTUALLY JUDGED, so a correction Dan made from a page the
    // classifier never saw cannot propose vocabulary for a title that does not contain it.
    @Test("a word that repeatedly appears on rows Dan calls opera is proposed as opera vocabulary")
    func aRepeatedWordIsProposed() throws {
        let ctx = ModelContext(try container())
        for title in ["Verismo Double Bill", "Verismo Gala", "An Evening of Verismo"] {
            ClassificationOverride.correct(show(ctx, title: title), discipline: .opera, now: now, in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        let top = try #require(report.suggestions.first)
        #expect(top.word == "verismo")
        #expect(top.discipline == .opera)
        #expect(top.count == 3)
    }

    // A one-off is not a pattern. Dan reading a genre off a page the classifier never saw is not a
    // missing word, it is missing input, and a report that proposed vocabulary from single corrections
    // would fill up with words from titles that genuinely do not carry the signal.
    //
    // The title carries a DISTINCTIVE word on purpose. The first version of this test used a title made
    // entirely of ordinary words, so there were no candidate words at all and the floor never ran: a
    // mutation deleting the floor left the suite green. The test has to offer the report something it
    // would otherwise take (L1, L144).
    @Test("a word seen on only one correction is not proposed")
    func aSingleCorrectionProposesNothing() throws {
        let ctx = ModelContext(try container())
        ClassificationOverride.correct(show(ctx, title: "Zarzuela Evening"),
                                       discipline: .opera, now: now, in: ctx)

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.suggestions.isEmpty, "one correction is not a pattern: \(report.suggestions)")
    }

    // A word the classifier ALREADY knows is not a missing word. Proposing "opera" as opera vocabulary
    // would be the report telling Dan to add something that is there, every time, which is how a report
    // stops being read.
    @Test("a word the classifier already matches on is never proposed")
    func aKnownWordIsNotProposed() throws {
        let ctx = ModelContext(try container())
        // These read as opera ALREADY, so the correction here is about something else entirely; what
        // matters is that "opera" cannot come out of the report as a suggestion.
        for title in ["Opera Night One", "Opera Night Two", "Opera Night Three"] {
            let p = show(ctx, title: title, discipline: "opera")
            ClassificationOverride.correct(p, discipline: .dance, now: now, in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.suggestions.contains { $0.word == "opera" } == false)
    }

    @Test("ordinary words that name no genre are never proposed")
    func stopwordsAreNotProposed() throws {
        let ctx = ModelContext(try container())
        for title in ["An Evening of Verismo", "An Evening of Verismo Again", "An Evening of Verismo Too"] {
            ClassificationOverride.correct(show(ctx, title: title), discipline: .opera, now: now, in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.suggestions.map(\.word) == ["verismo"])
    }

    // The presenter is part of what the classifier judges, so a company name that repeats is as good a
    // signal as a title word.
    @Test("a presenter's own word counts, because the classifier reads the presenter too")
    func thePresenterCounts() throws {
        let ctx = ModelContext(try container())
        for title in ["Programme One", "Programme Two", "Programme Three"] {
            ClassificationOverride.correct(show(ctx, title: title, presenter: "Teatro Grattacielo"),
                                           discipline: .opera, now: now, in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.suggestions.contains { $0.word == "teatro" })
    }

    // Ranked by how much they would pay off, so the top of the list is where to start.
    //
    // The words are chosen so COUNT order and ALPHABETICAL order disagree. The first version had
    // "verismo" as the more common one, which sorts first either way, so a mutation replacing the ranking
    // with a plain alphabetical sort left the suite green: the test asserted an order it could not
    // distinguish from the wrong one (L1, L144).
    @Test("suggestions are ranked by how many corrections they would have caught")
    func suggestionsAreRanked() throws {
        let ctx = ModelContext(try container())
        for title in ["Zarzuela A", "Zarzuela B", "Zarzuela C", "Zarzuela D"] {
            ClassificationOverride.correct(show(ctx, title: title), discipline: .opera, now: now, in: ctx)
        }
        for title in ["Verismo A", "Verismo B"] {
            ClassificationOverride.correct(show(ctx, title: title), discipline: .opera, now: now, in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.suggestions.map(\.word) == ["zarzuela", "verismo"],
                "the more common word leads, even though it sorts later alphabetically")
    }

    // A word Dan uses for two different genres is not vocabulary for either: proposing it would make the
    // classifier confidently wrong half the time, which is worse than leaving the row unread.
    @Test("a word Dan corrects to two different genres is not proposed for either")
    func anAmbiguousWordIsNotProposed() throws {
        let ctx = ModelContext(try container())
        for title in ["Rusalka One", "Rusalka Two"] {
            ClassificationOverride.correct(show(ctx, title: title), discipline: .opera, now: now, in: ctx)
        }
        for title in ["Rusalka Three", "Rusalka Four"] {
            ClassificationOverride.correct(show(ctx, title: title), discipline: .dance, now: now, in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.suggestions.contains { $0.word == "rusalka" } == false)
    }

    // The venue is stored, because it is part of what the classifier judged and worth having when
    // diagnosing a wrong reading, but it is never mined for vocabulary. Every show at one room shares
    // its name, so a room Dan corrects several shows at would put its own name at the top of the report
    // ahead of every real signal. Measured on the first run of this report: "merkin" and "hall" outranked
    // the word the test existed to find.
    @Test("the room's own name is never proposed as genre vocabulary")
    func theVenueIsNeverProposed() throws {
        let ctx = ModelContext(try container())
        for title in ["Verismo A", "Verismo B", "Verismo C"] {
            ClassificationOverride.correct(show(ctx, title: title, venue: "Kaufman Music Center"),
                                           discipline: .opera, now: now, in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.suggestions.map(\.word) == ["verismo"])
        #expect(GenreCorrection.all(in: ctx).first?.venue == "Kaufman Music Center",
                "still recorded, because it is part of what the classifier read")
    }

    // #2733 renamed the Theater genre to "Performing Arts" for display while deliberately keeping
    // `theater` as the stored value, so a report printing the raw value would show Dan a genre name that
    // appears nowhere else in the app. One word must name one thing across the product (L118). Caught by
    // reading the generated copy inventory cold, which is the only thing that catches it.
    @Test("a suggestion names the genre the way the rest of the app names it")
    func aSuggestionUsesTheDisplayName() throws {
        let ctx = ModelContext(try container())
        for title in ["Vaudeville A", "Vaudeville B"] {
            ClassificationOverride.correct(show(ctx, title: title), discipline: .theater, now: now,
                                           in: ctx)
        }

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))
        let line = GenreCorrectionReportCopy.suggestion(discipline: .theater, count: 2)

        #expect(report.suggestions.first?.word == "vaudeville")
        #expect(line.contains("Performing Arts"))
        #expect(line.contains("theater") == false, "the stored value is not what Dan calls it")
    }

    // MARK: the report says what it cannot know

    // The corrections already made are not recoverable: `classificationOverriddenByDan` is a bare
    // boolean, and re-running the classifier over those rows today would answer with the CURRENT rules,
    // which is not the same question. So this starts collecting from the day it ships, and the report
    // must say so rather than presenting a partial history as a complete one (L11).
    @Test("the report says it only knows about corrections made since it shipped")
    func theReportSaysWhatItCannotKnow() throws {
        let ctx = ModelContext(try container())
        ClassificationOverride.correct(show(ctx, title: "Il Trittico"), discipline: .opera, now: now,
                                       in: ctx)

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.provenance.contains("since"))
        #expect(report.correctionsSeen == 1)
    }

    // An empty report is not the same as a report with nothing to suggest. "Nobody has corrected
    // anything yet" and "corrections came in and no pattern emerged" are different facts, and only the
    // second says anything about the classifier (L98).
    @Test("no corrections at all is a different answer from no pattern found")
    func nothingYetIsNotNoPattern() {
        let empty = GenreCorrectionReport.build(from: [])

        #expect(empty.correctionsSeen == 0)
        #expect(empty.suggestions.isEmpty)
        #expect(empty.summary == GenreCorrectionReportCopy.nothingRecordedYet)
    }

    @Test("corrections with no pattern say so, rather than reading as nothing recorded")
    func noPatternSaysSo() throws {
        let ctx = ModelContext(try container())
        ClassificationOverride.correct(show(ctx, title: "One Off Thing"), discipline: .opera, now: now,
                                       in: ctx)

        let report = GenreCorrectionReport.build(from: GenreCorrection.all(in: ctx))

        #expect(report.correctionsSeen == 1)
        #expect(report.suggestions.isEmpty)
        #expect(report.summary != GenreCorrectionReportCopy.nothingRecordedYet)
    }
}
