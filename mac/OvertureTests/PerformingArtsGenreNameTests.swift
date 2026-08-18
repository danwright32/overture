import Testing
import Foundation
import SwiftData

// #2733, Dan 2026-08-14 from the genre picker: rename the Theater genre to Performing Arts.
//
// His site's galleries are Music, Performing Arts, Bands, Comedy and Dance, and a staged opera or play
// already maps to the Performing Arts gallery, so the rename puts the app's vocabulary in step with the
// portfolio he pitches with.
//
// The rename itself is one line, because #1657 made `Discipline.label` the single place a genre is NAMED.
// What these tests are about is everything that said the word WITHOUT going through it, because a one
// line rename would leave the app calling one genre two names on the same card, and each sentence reads
// perfectly alone (L118).
@MainActor
@Suite("Performing Arts genre name (#2733)")
struct PerformingArtsGenreNameTests {

    // MARK: the display name

    @Test func theGenreIsCalledPerformingArts() {
        #expect(Discipline.theater.label == "Performing Arts")
        // Through the row's own resolver too, which is what the queue line actually renders.
        #expect(QueueModel.disciplineLabel("theater") == "Performing Arts")
    }

    // MARK: what must NOT change

    // The STORED value stays `theater`. Every read resolves through `Discipline(rawValue:) ?? .other`, so
    // renaming it would silently degrade every stored theater row to "No genre read" and cost each one 2
    // fit points. It is also the vocabulary the scout writes (`docs/scout-runbook.md`) and the value
    // `fixtures/ranker/cases.json` and `fixtures/discipline-corpus/` carry.
    @Test func theStoredValueIsUntouched() {
        #expect(Discipline.theater.rawValue == "theater")
        #expect(Discipline(rawValue: "theater") == .theater)
    }

    // And the two rules keyed on the CASE are unaffected by a label change, which is the whole reason a
    // rename is safe. Asserted rather than assumed, because "not affected" is exactly the claim nobody
    // re-checks after the next rename.
    @Test func scoringAndGeographyAreKeyedOnTheCaseNotTheName() {
        #expect(Ranker.disciplinePoints(.theater) == Ranker.disciplinePoints(.opera))
        #expect(Ranker.disciplinePoints(.theater) > Ranker.disciplinePoints(.other))
        // Music stops at the five boroughs; this genre travels.
        #expect(!Discipline.theater.staysInTheBoroughs)
        #expect(Discipline.music.staysInTheBoroughs)
    }

    // MARK: the sentences that said the word without asking

    // The fit reason built itself from `discipline.rawValue`, so the card read "Self-produced theater
    // group, a strong-fit target." while the picker one line above offered Performing Arts. It now comes
    // from `.label`, lowercased because it sits mid-sentence.
    @Test func theFitReasonUsesTheGenresName() {
        let derived = EventClassifier.derived(discipline: .theater, production: .selfProduced,
                                              profile: .strong, venue: "The Example Room")

        #expect(derived.fitReason.contains("performing arts"))
        #expect(!derived.fitReason.lowercased().contains("theater"))
    }

    // Every other genre still reads as English in that sentence, which is the half that keeps the change
    // from being "it works for the one I looked at". `.other` names no genre at all, deliberately (#1657).
    //
    // #2813: matched case-insensitively, because `.notALivePerformance` is the dominant fact about its
    // row and therefore OPENS its sentence rather than sitting mid-clause. The claim being asserted is
    // unchanged (the genre is named in its own reason) and it still fails on a genre that is not.
    @Test func everyGenreStillReadsAsASentence() {
        // #2813: `.notALivePerformance` joins `.other` in naming no genre in this sentence, for the
        // neighbouring reason. `.other` is silent because no genre was read; this one is silent because
        // the row's genre line already says it and a sentence could only restate it (#843).
        for genre in Discipline.allCases where genre != .other && genre != .notALivePerformance {
            let reason = EventClassifier.derived(discipline: genre, production: .selfProduced,
                                                 profile: .strong, venue: "V").fitReason
            #expect(reason.lowercased().contains(genre.label.lowercased()),
                    "\(genre) is not named in its own fit reason")
        }
        let unread = EventClassifier.derived(discipline: .other, production: .selfProduced,
                                             profile: .strong, venue: "V").fitReason
        #expect(!unread.lowercased().contains("no genre read"))
        #expect(unread.hasPrefix("Self-produced group"))
    }

    // The stored sentences are realigned rather than left on a shrinking arbitrary subset. `fitReason` is
    // a snapshot written at classify time and a source whose bytes have not changed is skipped, so
    // without this the old wording would sit on rows for weeks. `FitReasonRealignment` recomputes from
    // the row's own axes rather than pattern matching the old text, and is idempotent by construction.
    @Test func storedFitReasonsAreRealigned() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "theater", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "Self-produced theater group, a strong-fit target, likely without its own photographer.",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)

        #expect(FitReasonRealignment.run(in: ctx) == 1)
        #expect(p.fitReason.contains("performing arts"))
        // Idempotent: a second pass changes nothing, so this cannot become a write that runs every launch.
        #expect(FitReasonRealignment.run(in: ctx) == 0)
    }

    // The geographic explanation names both genres as literals, so the copy inventory carries a sentence
    // Dan can READ rather than an expression. This is what catches the next rename instead: it asserts the
    // sentence still names both genres by their CURRENT labels, so the literal cannot drift away from the
    // picker without something going red.
    @Test func theTooFarSentenceNamesBothGenresByTheirCurrentNames() {
        let sentence = try! #require(
            QueueModel.tooFarReasonSentence(.outsideTheBoroughs),
            "the outside-the-boroughs explanation was not found")

        #expect(sentence.lowercased().contains(Discipline.music.label.lowercased()))
        #expect(sentence.lowercased().contains(Discipline.theater.label.lowercased()))
    }
}
