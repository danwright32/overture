import Testing
import Foundation
import SwiftData

// #4317: what each date heading asks about reachability (its tick box, its Check button, its finished
// marker and the day that marker names) is taken ONCE by the render pass, per date group, and published on
// `RenderData.dateProbeHeadings`. `ADateHeadingAsksNoGeographyPerBodyTests` (hosted) pins that the heading's
// body asks nothing; this suite pins that moving the answer changed NOTHING about it.
//
// THE EQUALITY is against the four functions the heading and `ReachabilityProbeControl` used to call, with
// the arguments they used to call them with: the group's rows and Dan's refusals UNRESOLVED, which is what
// the body's computed `geo` was. The pass answers from its own resolved geography, a memo of the same pure
// verdict (#1962), so the two must agree on every date. Each expected value is computed here from those
// functions directly, never through `DateProbeHeading`'s own initialiser, so the comparison cannot agree
// with itself (L70).
//
// THE FIXTURE holds one date for each way a heading can go (L159): one offering a check, and on it a show
// only geography refuses; one fully checked, which names its day and re-offers its answered show to the
// tick box; and one with nothing to decide, which is bare. It is drawn in LEADS mode (the #308 away-alert
// path, `focusedKeys`), because that is the one route on which a geography-refused row reaches a date
// heading at all (#1609): every stage list drops such a row before grouping. The positive control shows the
// comparison can see a wrong answer: with the refusal dropped, the refused show comes back as a candidate.
//
// Both ends of every date relationship pinned (L130). Invented names throughout (L155).
@MainActor
@Suite("A date heading's reachability answers come from the pass, unchanged (#4317)")
struct DateProbeHeadingsFromThePassTests {
    private let today = "2026-08-16"
    private var now: Date { EasternDate.date(from: today)!.addingTimeInterval(15 * 3_600) }
    private let geo = GeoRefusals(userExcludedTowns: ["poughkeepsie"])
    private let offering = "2026-10-03"
    private let checked = "2026-10-10"
    private let bare = "2026-10-17"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, _ key: String, on date: String, location: String,
                      status: ReviewStatus = .new, probedAt: Date? = nil) {
        let p = Prospect(naturalKey: key, groupName: "Brackenfold \(key)", discipline: "theater",
                         venue: "Quillmere Playhouse", performanceDate: date,
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        p.location = location
        p.reachabilityProbedAt = probedAt
        ctx.insert(p)
    }

    private var keys: [String] { ["open", "refused", "answered", "drafted"] }

    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        show(ctx, "open", on: offering, location: "New York, NY")
        show(ctx, "refused", on: offering, location: "Poughkeepsie, NY")
        show(ctx, "answered", on: checked, location: "New York, NY", probedAt: now.addingTimeInterval(-86_400))
        show(ctx, "drafted", on: bare, location: "New York, NY", status: .drafted)
        try ctx.save()
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func pass(_ rows: [Prospect]) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: .at(today, now: now, geo: geo), focusedStage: nil, focusedKeys: keys))
    }

    // What the heading's body used to ask, over one group, exactly as it asked it.
    private func old(_ group: QueueModel.DateGroup, geo: GeoRefusals)
        -> (tick: [String], candidates: [String], fullyChecked: Bool, checkedOn: Date?) {
        (QueueModel.probeKeysForTickedDate(group.items, now: now, today: today, geo: geo),
         QueueModel.reachabilityProbeCandidateKeys(group.items, now: now, today: today, geo: geo),
         QueueModel.dateReachabilityIsFullyChecked(group.items, now: now, today: today, geo: geo),
         QueueModel.dateReachabilityCheckedOn(group.items, now: now, today: today, geo: geo))
    }

    // The fixture must reach each branch, or the equality below is vacuous (L159).
    @Test func theFixtureDrawsEveryWayAHeadingCanGo() throws {
        let data = pass(try seed(try context()))
        #expect(Set(data.dateGroups.map(\.id)) == [offering, checked, bare],
                "the leads pass did not draw the three fixture dates, so nothing below compares a heading")
        let byDate = Dictionary(uniqueKeysWithValues: data.dateGroups.map { ($0.id, $0) })
        let offer = try #require(byDate[offering]), done = try #require(byDate[checked])
        let none = try #require(byDate[bare])
        #expect(old(offer, geo: GeoRefusals(userExcludedTowns: ["poughkeepsie"])).candidates == ["open"])
        #expect(old(done, geo: .none).fullyChecked && old(done, geo: .none).checkedOn != nil)
        #expect(old(done, geo: .none).tick == ["answered"], "the checked date re-offers nothing to its tick box")
        let empty = old(none, geo: .none)
        #expect(empty.tick.isEmpty && empty.candidates.isEmpty && !empty.fullyChecked)
    }

    @Test func thePassPublishesTheHeadingEachDateUsedToDerive() throws {
        let data = pass(try seed(try context()))
        // The refusals as the body's computed `geo` built them: a fresh value, never resolved.
        let unresolved = GeoRefusals(userExcludedTowns: ["poughkeepsie"])
        #expect(data.dateProbeHeadings.count == data.dateGroups.count,
                "the pass published \(data.dateProbeHeadings.count) headings for \(data.dateGroups.count) date groups")
        for group in data.dateGroups {
            let heading = try #require(data.dateProbeHeadings[group.id],
                                       "the pass published no heading for \(group.id)")
            let was = old(group, geo: unresolved)
            #expect(heading.tickKeys == was.tick, "\(group.id): the tick box's keys differ from the body's old answer")
            #expect(heading.candidateKeys == was.candidates,
                    "\(group.id): the Check button's keys differ from the control's old answer")
            #expect(heading.fullyChecked == was.fullyChecked,
                    "\(group.id): the finished marker differs from the control's old answer")
            #expect(heading.checkedOn == was.checkedOn, "\(group.id): the marker's day differs from the old answer")
        }
    }

    // THE POSITIVE CONTROL. The comparison above would pass on a pass that ignored geography only if the
    // fixture could not tell; with the refusal dropped, the refused show must come back as a candidate.
    @Test func theComparisonCanSeeAHeadingThatIgnoredGeography() throws {
        let data = pass(try seed(try context()))
        let offer = try #require(data.dateGroups.first { $0.id == offering })
        let heading = try #require(data.dateProbeHeadings[offering])
        let ignoringGeography = old(offer, geo: .none)
        #expect(Set(ignoringGeography.candidates) == ["open", "refused"])
        #expect(heading.candidateKeys != ignoringGeography.candidates,
                "the pass's heading cannot be told from one that ignored Dan's refusals")
    }
}
