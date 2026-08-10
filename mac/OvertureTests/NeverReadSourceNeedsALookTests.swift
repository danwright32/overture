import Testing
import Foundation

// #2231: a source that has NEVER succeeded was not counted as work anywhere, so one that silently never
// works was indistinguishable from one added this morning. Measured 2026-08-06: theplayerstheatre-com sat
// at `neverChecked`, zero successful checks, contributing zero shows, with its routing broken (#2229),
// under the "Not checked yet" heading beside sources added minutes earlier. Nothing was ever going to
// make anybody notice, which is what made the broken routing survive.
@Suite("A source that has never read needs a look (#2231)")
struct NeverReadSourceNeedsALookTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func source(addedDaysAgo: Double, succeeded: Bool = false, active: Bool = true,
                        health: SourceHealth = .neverChecked,
                        inactiveReason: SourceInactiveReason? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: "s-\(addedDaysAgo)-\(succeeded)", orgName: "A Theatre",
                              listingsURL: "https://example.test/events", kind: .html,
                              addedAt: now.addingTimeInterval(-addedDaysAgo * 86_400))
        s.isActive = active
        s.inactiveReason = inactiveReason
        s.health = health
        if succeeded {
            s.successfulCheckCount = 1
            s.lastSucceededAt = now.addingTimeInterval(-3_600)
        }
        return s
    }

    // The case the issue was filed for.
    @Test func aSourceThatHasNeverReadIsWorkOnceItIsPastTheGrace() {
        #expect(SourceAttention.needsALook(source(addedDaysAgo: 10), now: now))
    }

    // And the state this must NOT shout about: a source added minutes ago has never read either, and
    // saying so would be the cry-wolf failure #1428 and #1498 both pulled back from.
    @Test func aSourceAddedTodayIsNotWorkYet() {
        #expect(!SourceAttention.needsALook(source(addedDaysAgo: 0), now: now))
        #expect(!SourceAttention.needsALook(source(addedDaysAgo: 2.9), now: now))
    }

    // The boundary itself, from both sides, so the grace is a real number rather than a comment.
    @Test func theGraceIsThreeDays() {
        #expect(SourceAttention.neverReadGrace == 3 * 24 * 60 * 60)
        #expect(!SourceAttention.needsALook(source(addedDaysAgo: 3), now: now), "exactly three days is still waiting")
        #expect(SourceAttention.needsALook(source(addedDaysAgo: 3.1), now: now))
    }

    // One successful read ever is enough to leave this state: whatever the source does afterwards is the
    // business of the other two conditions, which judge a source that HAS read.
    @Test func oneSuccessfulReadEndsIt() {
        #expect(!SourceAttention.needsALook(source(addedDaysAgo: 100, succeeded: true), now: now))
    }

    // Consent still outranks everything (#800). A source Dan stopped, or one whose org asked him to stop,
    // never appears as work however long it has failed to read, because the natural end of "go and fix
    // it" is pitching an org that asked him not to.
    @Test func consentStillOutranksIt() {
        #expect(!SourceAttention.needsALook(
            source(addedDaysAgo: 100, active: false, inactiveReason: .orgRefusal), now: now))
        #expect(!SourceAttention.needsALook(
            source(addedDaysAgo: 100, active: false, inactiveReason: .removedByDan), now: now))
    }

    // The count and the rows behind it come from one predicate (#805/#863), so the clock has to reach
    // both or the badge would say one number while the section held another.
    @Test func theCountAndTheSectionSeeTheSameSources() {
        let sources = [source(addedDaysAgo: 10), source(addedDaysAgo: 0),
                       source(addedDaysAgo: 100, succeeded: true)]

        #expect(SourceAttention.count(sources, now: now) == 1)
        let split = SourceAttention.split(sources, now: now)
        #expect(split.needsALook.count == 1)
        #expect(split.rest.count == 2)
        #expect(!split.rest.contains { $0.sourceId == split.needsALook[0].sourceId },
                "a row lifted into the section must not also be left in the rest")
    }

    // Every row in that section says why it is there, more specifically than the heading could. This one
    // names the AGE, which is the whole difference between it and the legitimate state it looks like.
    @Test func theRowSaysHowLongItHasBeenSilent() {
        let line = SourceAttention.neverReadLine(addedAt: now.addingTimeInterval(-6 * 86_400), now: now)
        #expect(line.contains("6 days"))
        #expect(line.contains("never read"))
    }

    @Test func oneDayIsNotSaidAsDays() {
        let line = SourceAttention.neverReadLine(addedAt: now.addingTimeInterval(-86_400), now: now)
        #expect(line.contains("1 day and"))
    }

    // The sentence and the badge read the SAME rule, so a row cannot be lifted into the section without a
    // sentence, nor carry one while sitting somewhere else.
    @Test func theRowsSentenceAppearsExactlyWhereTheRuleFires() {
        let flagged = source(addedDaysAgo: 10)
        let fresh = source(addedDaysAgo: 1)
        let read = source(addedDaysAgo: 100, succeeded: true)

        #expect(flagged.neverReadNote(now: now) != nil)
        #expect(fresh.neverReadNote(now: now) == nil)
        #expect(read.neverReadNote(now: now) == nil)
        for s in [flagged, fresh, read] {
            #expect((s.neverReadNote(now: now) != nil) == SourceAttention.needsALook(s, now: now)
                    || SourceGrade(s) == .failing)
        }
    }

    // The tooltip names three reasons now, not two, or the badge would count a state it never explains.
    @Test func theBadgeHelpNamesTheNewReason() {
        let help = SourceAttention.help(count: 2)
        #expect(help.contains("never read at all"))
        #expect(help.contains("failing"))
        #expect(SourceAttention.help(count: 0).contains("never read at all") == false,
                "with nothing wrong, the tooltip describes the sheet rather than listing faults")
    }
}

// The rule is worth nothing if the row does not draw the sentence. A guard and its wiring are two claims
// (#887), and a SwiftUI body cannot be reached from a test.
@Suite("The Sources row draws the never-read sentence (#2231)")
struct NeverReadSourceRowWiringTests {
    private var sourcesView: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    @Test func theRowRendersTheNote() {
        #expect(!sourcesView.isEmpty)
        #expect(sourcesView.contains("if let neverRead = source.neverReadNote()"))
    }

    // Gold, unlike the two informational notes beside it: this one is squarely work Dan can act on, and
    // #1428/#1472/#1498 drew that line deliberately.
    @Test func theNoteIsPaintedAsWorkNotAsDisclosure() {
        guard let region = SourceGuardHelper.between("if let neverRead = source.neverReadNote()",
                                                      and: "#1544", in: sourcesView) else {
            Issue.record("could not scope to the never-read note")
            return
        }
        #expect(region.contains("OVColor.gold"))
    }
}
