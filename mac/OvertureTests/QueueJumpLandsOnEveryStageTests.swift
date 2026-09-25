import Testing
import Foundation
import SwiftData
import SwiftUI

// #4062: a jump to a show must land on EVERY list the show can be on, not only the ones it was built for.
//
// Reported by Dan, 2026-09-20, and reproduced live the same day: an OmniFocus follow-up link brought
// Overture forward and switched to the Reached out stage, and then the show was nowhere in sight. The
// routing was right. All three things meant to LAND the jump missed at once on that one stage, because it
// identifies its rows by the contact rather than the show, groups them by reach out date rather than
// performance date, and wraps them in a row that never read the jump mark. The same link to a Scout show,
// minutes later, scrolled to it and marked it. And every show with a live OmniFocus task is on Reached
// out by construction, so the one stage the jump missed was the one every such task points at (#4062).
//
// So this drives the jump on EVERY stage the queue can land on (L500), rather than only the broken one:
// all three mechanisms had failed silently while a green suite said nothing.
@MainActor
@Suite("A queue jump lands on every stage the show can be on (#4062)")
struct QueueJumpLandsOnEveryStageTests {
    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }

    private func item(key: String, date: String?) -> QueueItem {
        QueueItem(
            id: key, groupName: "Group \(key)", discipline: "music", venue: "Weill Recital Hall",
            performanceDate: date, sourceListingURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
        )
    }

    private func prospect(key: String, performanceDate: String, recipient: Recipient) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Group \(key)", discipline: "music", venue: "V",
                         performanceDate: performanceDate, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.recipients = [recipient]
        return p
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The stages a jump can land on. Follow-ups is left out because it is not a queue list at all: its
    // pill opens FollowUpsView, and `StageNavigation.stage(containing:)` never answers it for a show.
    private var landableStages: [StageFocus] { StageFocus.allCases.filter { $0 != .followUps } }

    // The ids a stage's list actually draws, derived from the SAME grouping each list renders from, so
    // this cannot agree with the resolver by sharing its mistake.
    private func drawnGroupIDs(on stage: StageFocus, items: [QueueItem],
                               reachedOut: [ReachedOutEntry]) -> Set<String> {
        if stage == .reachedOut {
            return Set(QueueModel.reachOutDateGroups(reachedOut, reachDate: { $0.next })
                .map { QueueModel.reachOutGroupScrollID($0.id) })
        }
        return Set(QueueModel.groupByDate(items).map { QueueModel.showGroupScrollID($0.id) })
    }

    // The regression test for what Dan hit, run over every stage. The show is next due on
    // 2026-09-17 but performs on 2026-09-25, exactly the shape of the reproduction, so a resolver that
    // reads the PERFORMANCE date names a group the Reached out list never draws.
    @Test func aJumpNamesAGroupAndARowTheTargetStageDraws() throws {
        let ctx = ModelContext(try container())
        let r = Recipient(id: "mail@moonjapan.net", email: "mail@moonjapan.net", name: "Them", provenance: .act)
        let key = "kempire after dark|2026-09-25|the green room 42"
        let p = prospect(key: key, performanceDate: "2026-09-25", recipient: r)
        ctx.insert(p)
        let items = [item(key: "other", date: "2026-09-02"), item(key: key, date: "2026-09-25")]
        let reachedOut = [ReachedOutEntry.prospect(prospect: p, recipient: r, next: day("2026-09-17"))]

        for stage in landableStages {
            guard let group = QueueModel.jumpScrollGroupID(for: key, onStage: stage, items: items,
                                                           reachedOut: reachedOut) else {
                Issue.record("a jump to a show on \(stage) should name a group to scroll to")
                continue
            }
            #expect(drawnGroupIDs(on: stage, items: items, reachedOut: reachedOut).contains(group),
                    "a jump on \(stage) named \(group), which that stage's list never draws")
            // And the ROW answers to the same key the jump carries, which is what the final scroll and
            // the jump mark both address.
            if stage == .reachedOut {
                #expect(reachedOut.contains { $0.showKey == key },
                        "a Reached out row must carry the show's key, not its contact's")
            } else {
                #expect(items.contains { $0.id == key })
            }
        }
    }

    // The failure path: a key no row on the stage answers to yields nothing, rather than a plausible
    // group belonging to some other show.
    @Test func aKeyTheStageDoesNotHoldResolvesToNothing() throws {
        let ctx = ModelContext(try container())
        let r = Recipient(id: "a@x.org", email: "a@x.org", name: "A", provenance: .act)
        let p = prospect(key: "k", performanceDate: "2026-10-01", recipient: r)
        ctx.insert(p)
        let reachedOut = [ReachedOutEntry.prospect(prospect: p, recipient: r, next: day("2026-09-17"))]
        for stage in landableStages {
            #expect(QueueModel.jumpScrollGroupID(for: "absent", onStage: stage, items: [],
                                                 reachedOut: reachedOut) == nil)
        }
    }

    // A Reached out group and a show group on the same date are different targets, in the same way the
    // show and inquiry groups are (#1573).
    @Test func theReachOutGroupIDIsItsOwnNamespace() {
        #expect(QueueModel.reachOutGroupScrollID("2026-09-17") != QueueModel.showGroupScrollID("2026-09-17"))
        #expect(QueueModel.reachOutGroupScrollID("2026-09-17") != QueueModel.inquiryGroupScrollID("2026-09-17"))
        #expect(QueueModel.reachOutGroupScrollID("2026-09-17") != "2026-09-17")
    }

    // The row's identity is the SHOW. The same address pitched about two performances is one Recipient id
    // on both shows (Recipient.id is deliberately not unique), so the old contact keyed identity gave two
    // Reached out rows one id.
    @Test func twoShowsPitchedToOneAddressAreTwoRows() throws {
        let ctx = ModelContext(try container())
        let r1 = Recipient(id: "box@venue.org", email: "box@venue.org", name: "Box", provenance: .act)
        let r2 = Recipient(id: "box@venue.org", email: "box@venue.org", name: "Box", provenance: .act)
        let a = prospect(key: "a|2026-10-01|v", performanceDate: "2026-10-01", recipient: r1)
        let b = prospect(key: "b|2026-10-08|v", performanceDate: "2026-10-08", recipient: r2)
        ctx.insert(a)
        ctx.insert(b)
        let first = ReachedOutEntry.prospect(prospect: a, recipient: r1, next: day("2026-09-17"))
        let second = ReachedOutEntry.prospect(prospect: b, recipient: r2, next: day("2026-09-17"))
        #expect(first.id != second.id)
        #expect(first.showKey == "a|2026-10-01|v")
        #expect(second.showKey == "b|2026-10-08|v")
    }

    // The mark. The Reached out row's wrapper hands its content whether THIS row is the one a jump is
    // marking, so the list can draw the same gold mark every other stage draws. Behavioural, through the
    // wrapper's own body, rather than a search of its source.
    @Test func theReachedOutRowIsToldWhenAJumpIsMarkingIt() {
        let state = SendProgressState()
        var seen: [String: Bool] = [:]
        func render(_ key: String) {
            _ = ReachedOutSendAwareRow(sendState: state, key: key) { _, _, highlighted in
                seen[key] = highlighted
                return EmptyView()
            }.body
        }

        state.highlight("target")
        render("target")
        render("neighbour")
        #expect(seen["target"] == true)
        #expect(seen["neighbour"] == false)

        state.clearHighlight(ifStill: "target")
        render("target")
        #expect(seen["target"] == false)
    }
}

// The half no pure function can reach: that the lists actually DRAW with the identities resolved above.
// Scoped to the functions that draw each list, never the whole file, so another list cannot answer for
// the Reached out one (the failure mode QueueInvalidationGuardTests measured for the departure).
@Suite("Every queue list draws the identities a jump resolves to (#4062)")
struct QueueJumpIdentityWiringGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    @Test func theReachedOutListDrawsItsGroupsAndRowsAsJumpTargets() {
        guard let list = SourceGuardHelper.bodyOfFunction(named: "reachedOutList", in: queueView) else {
            Issue.record("expected to find reachedOutList in QueueView")
            return
        }
        #expect(list.contains(".id(QueueModel.reachOutGroupScrollID(group.id))"),
                "each reach out date group must be tagged with the id a jump resolves to")
        #expect(list.contains(".scrollTargetLayout()"),
                "the groups must be scroll targets, or the scroll position cannot be driven to one")
        #expect(list.contains(".jumpMark(key:"),
                "each show row must carry the show's key and draw the jump mark")
    }

    @Test func theDateGroupedCardsUseTheSameMark() {
        let factory = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        #expect(!factory.isEmpty)
        #expect(factory.contains(".jumpMark(key: item.id"),
                "the other stages' cards and the Reached out rows share one mark, not two copies of it")
    }

    @Test func theDeepLinkResolvesItsGroupPerStage() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "navigateToLead", in: queueView) else {
            Issue.record("expected to find navigateToLead")
            return
        }
        #expect(body.contains("QueueModel.jumpScrollGroupID("),
                "the deep link must resolve its group against the list the stage actually draws")
    }
}
