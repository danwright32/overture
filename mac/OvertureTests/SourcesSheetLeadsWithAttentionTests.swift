import Testing
import Foundation
@testable import Overture

// #1541: the toolbar says a source needs a look, and the sheet it opens gives no way to reach it.
//
// Measured on Dan's store 2026-07-26 (66 active sources, badge reading 1): the source being counted was
// The Players Theatre, sitting under T about fifty rows down an alphabetical list, visually identical to
// every healthy row. No source was `.failing`, so the Failing section that would at least have grouped it
// was absent entirely. Meanwhile the FIRST row on screen, 54 Below, carried a prominent "Fix the address"
// button and was NOT the source the badge meant: it is the shrunken-feed self-healing hold that
// `SourceAttention` deliberately excludes (#1428). The most actionable-looking thing in the sheet pointed
// away from the one row Dan was summoned for.
//
// The badge exists for the failure with no symptom of its own (#805): a source whose fetch succeeded and
// whose health reads `ok`, but whose event pages came back unreadable often enough that it has forfeited
// the right to say a show is gone. That source grades as `.watching`, so it lands in the big Watching
// section at whatever alphabetical position its name gives it. On the current watchlist it is the ONLY
// case, so the badge's whole value rested on the one state the sheet had no route to.
//
// Dan's call, given the choice between putting them at the top and adding a filter: "It should either be
// at the top or have a button to filter for them, whatever's easier, I don't really have a preference."
// Top, because it needs no click, does not have to compose with the existing search (#1432) or decide
// what happens to the coverage section, and has no empty state to design: with nothing needing a look the
// section is simply absent, exactly as every other empty section already is.
//
// The set it shows is `SourceAttention.needsALook`, the SAME predicate the toolbar counts, never a
// re-derived approximation. #805, #863 and #885 all turn on the badge's number and the rows behind it
// being one number by construction. A section showing 2 rows under a badge reading 1 would be worse than
// the scrolling it replaces.
@MainActor
@Suite("The Sources sheet leads with what needs a look (#1541)")
struct SourcesSheetLeadsWithAttentionTests {

    private func source(_ name: String, active: Bool = true) -> WatchedSource {
        let s = WatchedSource(sourceId: name.lowercased(), orgName: name,
                              listingsURL: "https://\(name.lowercased()).example/events", kind: .html)
        s.isActive = active
        s.lastCheckedAt = Date()
        s.health = .ok
        return s
    }

    // The silent state the badge exists for: it fetched fine and reads healthy, but too many of its event
    // pages came back unreadable, so it can no longer say a show is gone. This is Dan's Players Theatre.
    private func forfeitedAbsence(_ name: String) -> WatchedSource {
        let s = source(name)
        s.lastReadableCount = 0
        s.lastUnreadableCount = 149
        return s
    }

    // #1428: a feed that simply came back SMALLER, every show read cleanly, is a self-healing hold that
    // re-baselines on its own. It is disclosed on the row but is NOT work Dan owes anyone. This is 54
    // Below, the row that used to sit at the top looking like the answer.
    private func shrunkenHold(_ name: String) -> WatchedSource {
        let s = source(name)
        s.lastReadableCount = 4
        s.lastUnreadableCount = 0
        s.baselineFeedCount = 30
        return s
    }

    private func failing(_ name: String) -> WatchedSource {
        let s = source(name)
        s.health = .failing
        s.lastFailure = .fetch(.unreachable)
        return s
    }

    // The whole point. The source the badge counts comes FIRST, not fifty rows down under its own initial.
    @Test func theSourceTheBadgeCountsLeadsTheSheet() {
        let rows = [source("54 Below"), source("Abrons"), forfeitedAbsence("The Players Theatre"),
                    source("Zankel")]

        let split = SourceAttention.split(rows)

        #expect(split.needsALook.map(\.orgName) == ["The Players Theatre"])
        #expect(split.rest.map(\.orgName) == ["54 Below", "Abrons", "Zankel"])
    }

    // The promise the whole feature rests on: the number on the badge and the rows in the section are one
    // number, by construction, because they are the same predicate. A section of 2 under a badge of 1
    // would be worse than the scrolling it replaces.
    @Test func theSectionAndTheBadgeCanNeverDisagree() {
        let rows = [source("A"), forfeitedAbsence("B"), failing("C"), shrunkenHold("D"),
                    forfeitedAbsence("E")]

        let split = SourceAttention.split(rows)

        #expect(split.needsALook.count == SourceAttention.count(rows))
        #expect(Set(split.needsALook.map(\.orgName)) == Set(["B", "C", "E"]))
    }

    // Nothing may appear twice. A failing source is real attention AND grades as Failing, so without this
    // it would be listed in both places, which is the duplicate-copy defect this sheet keeps being fixed
    // for (#840/#843).
    @Test func aSourceIsNeverListedInTwoSectionsAtOnce() {
        let broken = failing("Broken")
        let rows = [source("Fine"), broken]

        let split = SourceAttention.split(rows)

        #expect(split.needsALook.map(\.orgName) == ["Broken"])
        #expect(split.rest.contains { $0.orgName == "Broken" } == false)
        #expect(SourceGrade.sections(split.rest).contains { $0.grade == .failing } == false)
    }

    // #1428, held: a shrunken feed that read every show cleanly re-baselines on its own after three stable
    // reads with no input from Dan. Promoting it to the top would make the sheet cry wolf, which is the
    // exact thing that issue fixed. It stays disclosed on its row, in the ordinary section.
    @Test func aSelfHealingShrunkenFeedIsNotPromoted() {
        let rows = [shrunkenHold("54 Below"), source("Abrons")]

        let split = SourceAttention.split(rows)

        #expect(split.needsALook.isEmpty)
        #expect(split.rest.map(\.orgName) == ["54 Below", "Abrons"])
    }

    // #800: an org that asked Dan to stop, or a source he removed, is never work he owes anyone whatever
    // its scraper is doing. Re-checking a refusal is the one mistake in this feature that cannot be taken
    // back, so it must not be promoted to the top of the sheet either.
    @Test func aStoppedSourceIsNeverPromotedHoweverBrokenItLooks() {
        let stopped = forfeitedAbsence("Asked Us To Stop")
        stopped.isActive = false
        let rows = [stopped, source("Fine")]

        let split = SourceAttention.split(rows)

        #expect(split.needsALook.isEmpty)
        #expect(split.rest.contains { $0.orgName == "Asked Us To Stop" })
    }

    // The zero case, which is the ordinary one. No section, no heading, nothing saying "0": an empty
    // heading reads like something failed to load, which is why every other section is omitted when empty.
    @Test func nothingNeedingALookAddsNothingToTheSheet() {
        let rows = [source("A"), source("B")]

        let split = SourceAttention.split(rows)

        #expect(split.needsALook.isEmpty)
        #expect(split.rest.count == 2)
    }

    // The order within the section is stable and not the store's row order, so the sheet cannot reshuffle
    // between redraws.
    @Test func theSectionIsOrderedStably() {
        let rows = [forfeitedAbsence("Zankel"), forfeitedAbsence("Abrons")]

        #expect(SourceAttention.split(rows).needsALook.map(\.orgName) == ["Abrons", "Zankel"])
    }

    // The guard and its wiring are two claims (#887): all of the above is true on screen only if the sheet
    // actually renders this section, ahead of the graded ones, from this split.
    @Test func theSheetRendersTheAttentionSectionFirst() {
        let view = SourceGuardHelper.source("Overture/UI/SourcesView.swift")

        #expect(view.contains("SourceAttention.split"))
        #expect(view.contains("SourceAttention.sectionLabel"))
    }
}
