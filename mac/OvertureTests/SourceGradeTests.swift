import Testing
import Foundation
@testable import Overture

// #800: how a source READS in the Sources sheet.
//
// This is a domain rule and not a view detail, because getting it wrong is the one mistake in this
// feature that cannot be taken back. If a source that asked Dan to stop is ever rendered as merely
// "broken", the natural next action is to go and fix it. So the grade is computed by one pure function
// with its own tests, and the view has no logic of its own to get wrong.
@Suite("How a watched source reads (#800)")
struct SourceGradeTests {
    @Test func anActiveHealthySourceIsWatched() {
        #expect(SourceGrade(isActive: true, inactiveReason: nil, health: .ok) == .watching)
    }

    @Test func anActiveBrokenSourceIsFailingAndIsStillWatched() {
        #expect(SourceGrade(isActive: true, inactiveReason: nil, health: .failing) == .failing)
    }

    @Test func aSourceAddedButNotYetCheckedSaysSoRatherThanClaimingHealth() {
        #expect(SourceGrade(isActive: true, inactiveReason: nil, health: .neverChecked) == .neverChecked)
    }

    @Test func aRefusalReadsAsARefusal() {
        #expect(SourceGrade(isActive: false, inactiveReason: .orgRefusal, health: .ok)
                == .stoppedAtTheirRequest)
    }

    // A dead source Dan chose to stop watching is not an org that refused him, and the two must not be
    // presented as the same thing: one is a decision he can revisit, the other is a line he must not
    // cross.
    @Test func aSourceDanRemovedIsNotARefusal() {
        #expect(SourceGrade(isActive: false, inactiveReason: .removedByDan, health: .failing) == .removed)
    }

    // THE test. An org that refused Dan and whose website is ALSO broken must read as refused, never as
    // failing. Health is scout-owned and says nothing about consent, so it cannot be allowed to speak
    // for it: "stopped" always wins.
    @Test func aRefusalWhoseSiteIsAlsoBrokenStillReadsAsARefusalAndNeverAsBroken() {
        let grade = SourceGrade(isActive: false, inactiveReason: .orgRefusal, health: .failing)

        #expect(grade == .stoppedAtTheirRequest)
        #expect(grade != .failing)
        #expect(grade.isStopped)
        #expect(grade.isBroken == false)
    }

    // A row with no reason recorded is still stopped. It is not quietly promoted back to being watched.
    @Test func anInactiveSourceWithNoRecordedReasonIsStillStopped() {
        let grade = SourceGrade(isActive: false, inactiveReason: nil, health: .ok)
        #expect(grade.isStopped)
        #expect(grade != .watching)
    }

    // Every grade says what it is in words, not by color alone.
    @Test func everyGradeCarriesAWordDanCanRead() {
        for grade in SourceGrade.allCases {
            #expect(grade.label.isEmpty == false)
        }
        #expect(SourceGrade.stoppedAtTheirRequest.label.lowercased().contains("request"))
        #expect(SourceGrade.failing.label.lowercased().contains("failing"))
    }

    // #841/#843: an explanation only where the heading does not already carry the meaning. "Watching" and
    // "Not checked yet" both say it in full in the heading, so their lines only restated it. The rest
    // keep theirs, because those are the readings that cost something when they are wrong.
    @Test func everyGradeWhoseMeaningIsNotObviousExplainsItself() {
        let selfEvident: Set<SourceGrade> = [.watching, .neverChecked]
        for grade in selfEvident {
            #expect(grade.explanation == nil)
        }
        for grade in SourceGrade.allCases where !selfEvident.contains(grade) {
            #expect(grade.explanation?.isEmpty == false)
        }
    }
}

// The Sources sheet renders exactly what this returns, in exactly this order, so the sheet has no
// judgement of its own to get wrong and the whole of its behaviour is testable without a UI.
@MainActor
@Suite("The Sources sheet's sections (#800)")
struct SourceSectionsTests {
    private func source(_ id: String, health: SourceHealth = .ok, active: Bool = true,
                        reason: SourceInactiveReason? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: id, kind: .html)
        s.health = health
        s.isActive = active
        s.inactiveReason = reason
        return s
    }

    @Test func sectionsReadInTheOrderDanShouldReadThem() {
        let sections = SourceGrade.sections([
            source("stopped", active: false, reason: .orgRefusal),
            source("broken", health: .failing),
            source("fine"),
        ])

        // What is working, then what needs him, then what he must leave alone.
        #expect(sections.map(\.grade) == [.watching, .failing, .stoppedAtTheirRequest])
    }

    // A heading with nothing under it reads like something failed to load.
    @Test func anEmptySectionIsOmittedEntirely() {
        let sections = SourceGrade.sections([source("fine")])

        #expect(sections.count == 1)
        #expect(sections.first?.grade == .watching)
        #expect(sections.contains { $0.grade == .failing } == false)
    }

    @Test func noSourcesMeansNoSections() {
        #expect(SourceGrade.sections([]).isEmpty)
    }

    // THE test, at the level Dan actually sees. An org that refused him, whose site is also broken,
    // appears under "Stopped at their request" and appears NOWHERE in the failing section.
    @Test func anOrgThatRefusedNeverAppearsInTheFailingSection() {
        let refused = source("refused", health: .failing, active: false, reason: .orgRefusal)
        let sections = SourceGrade.sections([refused, source("broken", health: .failing)])

        let failing = sections.first { $0.grade == .failing }?.sources ?? []
        let stopped = sections.first { $0.grade == .stoppedAtTheirRequest }?.sources ?? []

        #expect(failing.map(\.sourceId) == ["broken"])
        #expect(stopped.map(\.sourceId) == ["refused"])
    }

    // Every source lands in exactly one section: none is silently dropped from the sheet.
    @Test func everySourceAppearsExactlyOnce() {
        let all = [
            source("a"), source("b", health: .failing), source("c", health: .neverChecked),
            source("d", active: false, reason: .orgRefusal),
            source("e", active: false, reason: .removedByDan),
        ]
        let shown = SourceGrade.sections(all).flatMap(\.sources).map(\.sourceId)

        #expect(shown.sorted() == ["a", "b", "c", "d", "e"])
        #expect(shown.count == Set(shown).count)
    }
}

// The sheet has to be reachable, and it has to be reading the live store rather than a stale copy.
@Suite("The Sources sheet is wired into the app (#800)")
struct SourcesViewWiringTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }
    private var sourcesView: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    @Test func theToolbarOpensTheSourcesSheet() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("showSources = true"))          // a button sets it
        // #970 gave the sheet a `readOne:` argument, so this matches the presentation rather than an
        // exact empty-argument call.
        #expect(rootView.contains("$showSources) { SourcesView("))   // and a sheet presents it
    }

    // A @Query, not a snapshot passed in: the sheet must reflect what the scout wrote on this run, not
    // what the store held when the window opened.
    @Test func theSheetReadsTheLiveStore() {
        #expect(sourcesView.contains("@Query"))
        #expect(sourcesView.contains("WatchedSource"))
    }
}

// #1440: the Sources sheet used to pin its scroll to the top-visible SECTION on every tick (#974, to hold
// place across a scout rebuild). With only a few coarse section anchors, that continuous re-pin fought a
// fast drag into a jump to the bottom and a feedback-loop freeze, and #1429's caching alone did not cure
// it. The sheet now scrolls freely (no pin) and restores Dan's place only when the list actually rebuilds.
// Two pure helpers make that logic testable without a UI: which section is on top right now, and whether
// the list changed in a way that would reset the scroll.
@MainActor
@Suite("The Sources sheet's scroll restore (#1440)")
struct SourcesScrollRestoreTests {
    private func source(_ id: String, health: SourceHealth = .ok, checkedAt: Date? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: id, kind: .html)
        s.health = health
        s.isActive = true
        s.lastCheckedAt = checkedAt
        return s
    }

    // The top-visible section is the one whose top edge has just crossed the viewport top (minY at or just
    // above 0); among those, the one closest to the top (greatest minY). That is where the sheet restores to
    // after a rebuild.
    @Test func picksTheSectionWhoseTopHasJustPassedTheViewportTop() {
        let top = SourcesScrollRestore.topSection(
            [(.watching, -120), (.failing, -10), (.stoppedAtTheirRequest, 200)])
        #expect(top == .failing)
    }

    // Before any scrolling every section sits below the top (minY > 0); the top one is simply the first.
    @Test func atRestTheTopSectionIsTheFirstOne() {
        #expect(SourcesScrollRestore.topSection([(.watching, 8), (.failing, 300)]) == .watching)
    }

    @Test func noSectionsMeansNoTopSection() {
        #expect(SourcesScrollRestore.topSection([]) == nil)
    }

    // The restore fires when a scout could have reset the scroll (a source moved grade, its checked time was
    // restamped, or one was added or removed) and stays put otherwise, so the restore neither misfires on a
    // no-op redraw nor misses a real rebuild.
    @Test func theRestoreSignatureTracksWhatResetsTheScroll() {
        let base = [source("x", checkedAt: Date(timeIntervalSince1970: 100)),
                    source("y", checkedAt: Date(timeIntervalSince1970: 100))]
        let same = [source("x", checkedAt: Date(timeIntervalSince1970: 100)),
                    source("y", checkedAt: Date(timeIntervalSince1970: 100))]
        #expect(SourcesScrollRestore.signature(base) == SourcesScrollRestore.signature(same))

        let gradeMoved = [source("x", health: .failing, checkedAt: Date(timeIntervalSince1970: 100)),
                          source("y", checkedAt: Date(timeIntervalSince1970: 100))]
        #expect(SourcesScrollRestore.signature(base) != SourcesScrollRestore.signature(gradeMoved))

        let rechecked = [source("x", checkedAt: Date(timeIntervalSince1970: 200)),
                         source("y", checkedAt: Date(timeIntervalSince1970: 100))]
        #expect(SourcesScrollRestore.signature(base) != SourcesScrollRestore.signature(rechecked))

        let added = base + [source("z", checkedAt: Date(timeIntervalSince1970: 100))]
        #expect(SourcesScrollRestore.signature(base) != SourcesScrollRestore.signature(added))
    }
}
