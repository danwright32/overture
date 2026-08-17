import Testing
import Foundation
import SwiftData

// #1657 (Phase B of #1591): an unread genre reads as unread.
//
// 53% of prospects carry `discipline == other`, which means no genre word was found in the title or the
// presenter. Two surfaces stated that as though it were an answer: the row's own genre line said
// "Performance", and the fit reason interpolated the raw enum value into a sentence ("Self-produced other
// group, a strong-fit target").
//
// The line is also the affordance: #1662 made it the button that opens the genre editor. So on more than
// half the queue the app was inviting a correction while asserting there was nothing to correct.
@Suite("An unread genre says so (#1657)")
struct UnreadGenreIsSaidPlainlyTests {

    @Test func theGenreLineSaysTheGenreWasNotRead() {
        #expect(QueueModel.disciplineLabel("other") == Discipline.other.label)
        #expect(Discipline.other.label == "No genre read")
    }

    // Two or more words of two-plus letters, or `CopyInventory.isCopy` never sees it and the most
    // prominent line on every queue row goes on never being read cold (the reason it was wrong for so
    // long). This asserts the property rather than the string, so a later rewording cannot quietly drop
    // back below the bar.
    @Test func theLabelIsShapedSoTheCopyInventoryCanSeeIt() {
        let words = Discipline.other.label.split(separator: " ").filter { $0.count >= 2 }
        #expect(words.count >= 2, "a single-token label never enters the copy inventory")
    }

    // A genre that WAS read keeps its own word, and the words are the ones the picker and the row line
    // have always shown.
    @Test func everyReadGenreKeepsItsOwnLabel() {
        let expected: [Discipline: String] = [.dance: "Dance", .opera: "Opera", .theater: "Performing Arts",
                                              .music: "Music", .band: "Band", .comedy: "Comedy"]
        for (discipline, label) in expected {
            #expect(discipline.label == label)
            #expect(QueueModel.disciplineLabel(discipline.rawValue) == label)
        }
    }

    // A raw value no longer in the enum (the "choral" rows #350 folded into music, until the launch
    // migration reaches them) is a genre this app cannot state, which is the same answer as an unread one.
    @Test func aRetiredRawValueReadsAsUnreadRatherThanInventingALabel() {
        #expect(QueueModel.disciplineLabel("choral") == Discipline.other.label)
    }

    // The fit reason: no sentence may carry a raw enum value. An unread genre drops the word entirely
    // rather than naming itself, because "Self-produced group" is true and "Self-produced other group" is
    // not English.
    @Test func theFitReasonNamesAGenreOnlyWhenOneWasRead() {
        let unread = EventClassifier.derived(discipline: .other, production: .selfProduced,
                                             profile: .strong, venue: nil).fitReason
        #expect(unread.contains("other") == false)
        #expect(unread == "Self-produced group, a strong-fit target.")

        let read = EventClassifier.derived(discipline: .music, production: .selfProduced,
                                           profile: .strong, venue: nil).fitReason
        #expect(read == "Self-produced music group, a strong-fit target.")
    }

    @Test func theWorthALookSentenceDropsTheWordToo() {
        let unread = EventClassifier.derived(discipline: .other, production: .selfProduced,
                                             profile: .neutral, venue: nil).fitReason
        #expect(unread == "Self-produced; worth a look once the fit is confirmed.")

        // #2733: the genre is named by its LABEL now, not by the stored raw value, so this sentence
        // renamed with the picker instead of drifting away from it.
        let read = EventClassifier.derived(discipline: .theater, production: .selfProduced,
                                           profile: .neutral, venue: nil).fitReason
        #expect(read == "Self-produced performing arts; worth a look once the fit is confirmed.")
    }

    // No sentence this classifier can produce may contain a raw enum value that is not also an English
    // word for the genre. Exhaustive over the enum rather than a list repeated here, so a genre added
    // later is covered without editing this test.
    @Test func noSentenceCarriesARawEnumValueThatIsNotAWord() {
        for discipline in Discipline.allCases {
            for profile in [Profile.strong, .neutral, .weak] {
                for production in [Production.selfProduced, .agency, .unknown] {
                    let reason = EventClassifier.derived(discipline: discipline, production: production,
                                                         profile: profile, venue: nil).fitReason
                    if discipline == .other {
                        #expect(reason.contains("other") == false,
                                "an unread genre must not name itself: \(reason)")
                    }
                }
            }
        }
    }
}

// The stored half. `fitReason` is a snapshot, so changing the classifier alone leaves the old sentence on
// every row until a hash-gated scout happens to re-emit it.
@Suite("The stored fit reason is realigned with the row it describes (#1657)")
struct FitReasonRealignmentTests {

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func prospect(_ key: String, discipline: String, reason: String,
                          production: String = "self", profile: String = "strong") -> Prospect {
        Prospect(naturalKey: key, groupName: key, discipline: discipline, venue: "The Example Room",
                 performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: production, profile: profile,
                 coverage: "likely_uncovered", fitScore: 10, tier: "high", fitReason: reason,
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    @MainActor
    @Test func aSentenceNamingARawEnumValueIsRewritten() throws {
        let ctx = try context()
        let row = prospect("k1", discipline: "other",
                           reason: "Self-produced other group, a strong-fit target, likely without its own photographer.")
        ctx.insert(row)

        let changed = FitReasonRealignment.run(in: ctx)
        #expect(changed == 1)
        #expect(row.fitReason.contains("other") == false)
    }

    // The row #1657 measured: `DisciplineMigration` rewrote the discipline and left the sentence naming a
    // genre this app no longer has.
    @MainActor
    @Test func aSentenceLeftBehindByAnEarlierMigrationIsRewritten() throws {
        let ctx = try context()
        let row = prospect("k2", discipline: "music",
                           reason: "Self-produced choral group, a strong-fit target.")
        ctx.insert(row)

        _ = FitReasonRealignment.run(in: ctx)
        #expect(row.fitReason == "Self-produced music group, a strong-fit target.")
    }

    // Idempotent BY CONSTRUCTION rather than by a flag: the condition is "the stored sentence differs from
    // the one this row's own axes produce", and the pass writes that sentence, so a second run changes
    // nothing.
    @MainActor
    @Test func asecondRunChangesNothing() throws {
        let ctx = try context()
        ctx.insert(prospect("k3", discipline: "other", reason: "Self-produced other; worth a look once the fit is confirmed."))
        _ = FitReasonRealignment.run(in: ctx)
        #expect(FitReasonRealignment.run(in: ctx) == 0)
    }

    // An empty reason is a deliberate state (#1600 retired the catch-all sentence and put nothing in its
    // place), and the row hides an empty line. Realigning must not resurrect a sentence there.
    @MainActor
    @Test func aRowThatDeliberatelyHasNoReasonKeepsNone() throws {
        let ctx = try context()
        let row = prospect("k4", discipline: "music", reason: "", production: "unknown", profile: "neutral")
        ctx.insert(row)

        _ = FitReasonRealignment.run(in: ctx)
        #expect(row.fitReason == "")
    }

    // Dan's own correction, which is where the stale sentence is easiest to hit: the genre editor is one
    // tap from the line, so a corrected row must not keep a reason describing the genre it no longer has.
    @MainActor
    @Test func correctingTheGenreRewritesTheReasonWithIt() throws {
        let ctx = try context()
        let row = prospect("k5", discipline: "other",
                           reason: "Self-produced other group, a strong-fit target.")
        ctx.insert(row)

        ClassificationOverride.correct(row, discipline: .music, now: Date())
        #expect(row.fitReason == "Self-produced music group, a strong-fit target.")
    }
}

// #2022. Dan, reading the card for "The Pumpkin Singalong at Sakura Park" (Every Voice Choirs, Oct 25
// 2026): "I'm literally their photographer. We can see I've worked with them for years."
//
// The card said "Self-produced other group, a strong-fit target, likely without its own photographer." two
// lines under "Pitch will say you've photographed a few shows here" and one line above a gold "Worked
// together before" pill. Three things on one screen, one of them contradicting the other two.
//
// The clause is composed from three axes (production, profile, discipline) plus the coverage they imply,
// and `derived` marks any Weill show or any self-produced strong-profile show as `likelyUncovered`, which
// is exactly the shape a long-standing client of Dan's takes. So the group he has shot three times is the
// group most likely to be told it has no photographer.
//
// Dan's call, 2026-08-16: DROP THE CLAUSE. It is a guess on every row, not only on the ones where it is
// visibly wrong; the "Likely uncovered" pill beside it already carries the same claim, so the sentence was
// also restating its neighbour (#843); and dropping it removes the whole class rather than the instance.
// Losing the weak signal on groups he has no history with is the accepted trade.
//
// What deliberately does NOT change: `Coverage.likelyUncovered` itself. It feeds the fit SCORE and the
// pill, and neither was what he read as a contradiction. Only the sentence stops saying it.
@Suite("The fit reason does not guess at coverage (#2022)")
struct FitReasonDropsTheCoverageGuessTests {

    // The sentence Dan read, as it reads now. No stranded comma, no doubled space, still one full stop.
    @Test func astrongSelfProducedGroupIsNotToldItHasNoPhotographer() {
        let reason = EventClassifier.derived(discipline: .music, production: .selfProduced,
                                             profile: .strong, venue: "Weill Recital Hall").fitReason
        #expect(reason == "Self-produced music group, a strong-fit target.")
    }

    // The same sentence for the row whose genre was never read, which is more than half the queue: the
    // clause used to be the only thing after "target" there too.
    @Test func anunreadGenreGetsTheSameSentence() {
        let reason = EventClassifier.derived(discipline: .other, production: .selfProduced,
                                             profile: .strong, venue: "Weill Recital Hall").fitReason
        #expect(reason == "Self-produced group, a strong-fit target.")
    }

    // The clause was appended on a coverage verdict, so the two branches it made are now one sentence.
    // Asserted as equality between them rather than twice against a literal, because what this is really
    // saying is that coverage no longer reaches the sentence at all.
    @Test func thesentenceIsTheSameWhicheverCoverageWasDerived() {
        let atWeill = EventClassifier.derived(discipline: .music, production: .selfProduced,
                                              profile: .strong, venue: "Weill Recital Hall")
        let elsewhere = EventClassifier.derived(discipline: .music, production: .selfProduced,
                                                profile: .neutral, venue: "The Example Room")
        #expect(atWeill.coverage == .likelyUncovered)
        #expect(elsewhere.coverage == .unknown)
        #expect(!atWeill.fitReason.contains("photographer"))
        #expect(!elsewhere.fitReason.contains("photographer"))
    }

    // No sentence this classifier can produce says it, over every combination rather than the three the
    // issue happened to name (L30: the class, not the instance).
    @Test func nosentenceThisClassifierComposesMentionsAPhotographer() {
        for discipline in Discipline.allCases {
            for profile in [Profile.strong, .neutral, .weak] {
                for production in [Production.selfProduced, .agency, .unknown] {
                    for venue in ["Weill Recital Hall", "The Example Room", ""] {
                        let reason = EventClassifier.derived(discipline: discipline, production: production,
                                                             profile: profile, venue: venue).fitReason
                        #expect(!reason.contains("photographer"), "still guessing at coverage: \(reason)")
                        // And no sentence was left ending on its own comma by the removal.
                        #expect(!reason.contains(", ."))
                        #expect(!reason.contains("  "))
                    }
                }
            }
        }
    }

    // The pill stays. Dan's reasoning for dropping the clause was that the pill beside it already says
    // this, so a change that quietly took both would leave the coverage guess with no surface at all.
    @Test func thelikelyUncoveredPillIsUnchanged() {
        #expect(QueueModel.coverageLabel("likely_uncovered") == "Likely uncovered")
    }

    // The 86 stored rows. `fitReason` is a snapshot and the scout is hash-gated, so changing the composer
    // alone would leave the sentence on whichever rows nothing has re-emitted, for weeks. `FitReasonRealignment`
    // already recomputes every stored reason from that row's own axes on every launch, so it sweeps these
    // by construction rather than needing a migration of its own. Measured on the live store 2026-08-03:
    // 86 rows carry the clause, 11 of them on groups whose prior relationship is already `booked`.
    @MainActor
    @Test func astoredRowCarryingTheClauseIsRewrittenAtLaunch() throws {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        let row = Prospect(naturalKey: "sakura", groupName: "Every Voice Choirs", discipline: "music",
                           venue: "Sakura Park", performanceDate: "2026-10-25", sourceListingURL: nil,
                           websiteURL: nil, priorRelationship: "booked", production: "self",
                           profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                           fitReason: "Self-produced music group, a strong-fit target, likely without its own photographer.",
                           matchedClientName: "Every Voice Choirs", possibleMatchSource: nil,
                           possibleMatchName: nil)
        ctx.insert(row)

        let changed = FitReasonRealignment.run(in: ctx)
        #expect(changed == 1)
        #expect(row.fitReason == "Self-produced music group, a strong-fit target.")
    }
}
