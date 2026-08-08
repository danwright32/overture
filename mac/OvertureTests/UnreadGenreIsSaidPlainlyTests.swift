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
        let expected: [Discipline: String] = [.dance: "Dance", .opera: "Opera", .theater: "Theater",
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
        #expect(unread == "Self-produced group, a strong-fit target, likely without its own photographer.")

        let read = EventClassifier.derived(discipline: .music, production: .selfProduced,
                                           profile: .strong, venue: nil).fitReason
        #expect(read == "Self-produced music group, a strong-fit target, likely without its own photographer.")
    }

    @Test func theWorthALookSentenceDropsTheWordToo() {
        let unread = EventClassifier.derived(discipline: .other, production: .selfProduced,
                                             profile: .neutral, venue: nil).fitReason
        #expect(unread == "Self-produced; worth a look once the fit is confirmed.")

        let read = EventClassifier.derived(discipline: .theater, production: .selfProduced,
                                           profile: .neutral, venue: nil).fitReason
        #expect(read == "Self-produced theater; worth a look once the fit is confirmed.")
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
        #expect(row.fitReason == "Self-produced music group, a strong-fit target, likely without its own photographer.")
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
        #expect(row.fitReason == "Self-produced music group, a strong-fit target, likely without its own photographer.")
    }
}
