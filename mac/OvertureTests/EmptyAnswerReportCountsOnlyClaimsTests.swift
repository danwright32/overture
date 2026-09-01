import Testing
import Foundation
import SwiftData

// Milestone 61 Phase 0.5. `EmptyAnswerReport.make` counted EVERY stored `reachabilityEmptyReason` with
// no verdict test at all, but `ProspectRowView` renders that sentence only under the `.noEmailFound`
// badge. So most of what the report counted was a claim no card anywhere makes.
//
// LIVE-STORE-CLAIM verified=2026-08-31 measure="prospects carrying a reachabilityEmptyReason, split by whether their stored verdict is the one whose card renders that sentence"
// Measured 2026-08-31 against a WAL inclusive copy: 103 rows carry a reason. 43 are renderable
// (verdict `no_email_found`), 53 carry a verdict that contradicts the reason, and 7 carry a reason with
// no verdict at all. The 43 reproduces the plan's own count exactly; the other two moved with the store.
//
// The cause is a writer/reader split: `PrepImporter` writes the reason whenever no usable recipient
// survives the ingest, independent of where the cascade lands, so a show with no address but a form on
// its own site gets both `contact_form_only` AND a reason saying nobody could be reached. Both are true
// of what they describe; only one of them is a claim about reachability.
//
// The fix is at the READER and it is a precedence statement: **the VERDICT decides whether an empty
// reason is a claim; the reason only says WHICH claim.**
//
// The excluded rows are REPORTED as their own lines rather than silently vanishing, because a number
// quietly getting smaller is indistinguishable from a defect being fixed (L11, L98).
@MainActor
@Suite("The empty answer report counts only claims a card actually makes (#3356 Phase 0.5)")
struct EmptyAnswerReportCountsOnlyClaimsTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ name: String,
                      verdict: Reachability.ProbeResult?,
                      reason: Reachability.EmptyReason?) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: name, performanceDate: "2027-04-18",
                                          venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Rowan Hall",
                         performanceDate: "2027-04-18", sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        p.reachabilityResult = verdict
        p.reachabilityEmptyReason = reason
        try? ctx.save()
        return p
    }

    // The defect exactly, in the shape the live store holds most of: two rows carrying the SAME reason,
    // only one of which has a card that says it.
    @Test func onlyTheRowWhoseCardSaysItIsCounted() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Card Says It", verdict: .noEmailFound, reason: .namedButNoRoute)
        show(ctx, "Card Says Otherwise", verdict: .contactFormOnly, reason: .namedButNoRoute)

        let report = EmptyAnswerReport.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.count(of: .namedButNoRoute) == 1)
        #expect(report.total == 1)
    }

    // The excluded rows are REPORTED, not dropped. Without this the fix looks identical to the report
    // quietly losing rows, and nobody could tell a corrected count from a broken one (L11, L98).
    @Test func aRowContradictedByItsOwnVerdictIsReportedSeparately() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Card Says It", verdict: .noEmailFound, reason: .namedButNoRoute)
        show(ctx, "Card Says Otherwise", verdict: .contactFormOnly, reason: .namedButNoRoute)
        show(ctx, "Also Otherwise", verdict: .socialOnly, reason: .onlySocialProfile)

        let report = EmptyAnswerReport.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.contradictedByVerdict == 2)
    }

    // A reason with NO verdict at all is its own fault and gets its own number: a reason contradicted by
    // a verdict and a reason nothing ever judged are different findings, and folding them together would
    // make one sentence answer for two causes (L11).
    @Test func aReasonWithNoVerdictAtAllIsItsOwnFinding() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Never Judged", verdict: nil, reason: .nothingPublished)
        show(ctx, "Contradicted", verdict: .socialOnly, reason: .onlySocialProfile)

        let report = EmptyAnswerReport.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.reasonWithNoVerdict == 1)
        #expect(report.contradictedByVerdict == 1)
        #expect(report.total == 0, "neither row's card says anything, so neither is a claim")
    }

    // The cross-cut this section exists for must follow the same rule, or the accusation it makes is
    // computed over a different population from the table above it (L16).
    @Test func theCrossCutCountsOnlyClaimsToo() throws {
        let ctx = ModelContext(try container())
        let counted = show(ctx, "Counted", verdict: .noEmailFound, reason: .nothingPublished)
        counted.presenter = "Rowan Presenting"
        let excluded = show(ctx, "Excluded", verdict: .contactFormOnly, reason: .nothingPublished)
        excluded.presenter = "Rowan Presenting"
        try? ctx.save()

        let report = EmptyAnswerReport.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.nothingPublishedWithAPresenter == 1)
    }

    // A store where every reason is renderable reports nothing excluded, so the new lines cannot become
    // permanent furniture that says the same thing on every store (L36).
    @Test func aCleanStoreReportsNothingExcluded() throws {
        let ctx = ModelContext(try container())
        show(ctx, "Card Says It", verdict: .noEmailFound, reason: .namedButNoRoute)

        let report = EmptyAnswerReport.make(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(report.contradictedByVerdict == 0)
        #expect(report.reasonWithNoVerdict == 0)
        #expect(report.total == 1)
    }

    // The two numbers reach the SCREEN, and each behind its own test, so a store with nothing to
    // exclude never grows a permanent line saying nothing (L36). Source-text guards in the same shape
    // as the section's existing ones, because `EmptyAnswerSection` reads its rows through `@Query` and
    // cannot be rendered without a live container.
    @Test func bothExcludedCountsAreDrawnAndEachIsGatedOnHavingSomethingToSay() {
        let source = SourceGuardHelper.source("Overture/UI/EmptyAnswerSection.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("if report.contradictedByVerdict > 0 {", in: source),
                "the contradicted count is computed and no screen shows it")
        #expect(SourceGuardHelper.containsCode("if report.reasonWithNoVerdict > 0 {", in: source),
                "the unjudged count is computed and no screen shows it")
        #expect(SourceGuardHelper.containsCode(
            "Text(EmptyAnswerCopy.contradictedByVerdict(report.contradictedByVerdict))", in: source))
        #expect(SourceGuardHelper.containsCode(
            "Text(EmptyAnswerCopy.reasonWithNoVerdict(report.reasonWithNoVerdict))", in: source))
    }

    // They sit AFTER the cross-cut, which is what the section exists for rather than the table above
    // it. Order is a real claim about what Dan reads first, and it was wrong on the first attempt.
    @Test func theExclusionLinesFollowTheCrossCutRatherThanBuryingIt() {
        let source = SourceGuardHelper.source("Overture/UI/EmptyAnswerSection.swift")
        #expect(!source.isEmpty)
        let crossCut = source.range(of: "if report.nothingPublishedWithAPresenter > 0 {")
        let excluded = source.range(of: "if report.contradictedByVerdict > 0 {")
        #expect(crossCut != nil && excluded != nil)
        #expect(crossCut!.lowerBound < excluded!.lowerBound,
                "the caveats about what is not counted sit above the accusation the section exists to make")
    }

    // Singular and plural are different sentences, not one with an "(s)" in it, matching the rule the
    // section's existing counts follow.
    @Test func theExcludedCountsReadAsEnglishAtOne() {
        #expect(EmptyAnswerCopy.contradictedByVerdict(1).contains("1 more show stored"))
        #expect(EmptyAnswerCopy.contradictedByVerdict(4).contains("4 more shows stored"))
        #expect(EmptyAnswerCopy.reasonWithNoVerdict(1).contains("1 show stored"))
        #expect(EmptyAnswerCopy.reasonWithNoVerdict(4).contains("4 shows stored"))
    }

    // The two say DIFFERENT things, because they are different faults. If they ever collapse into one
    // sentence, one of the two causes has silently stopped being reported (L11).
    @Test func theTwoExclusionsDoNotSayTheSameThing() {
        #expect(EmptyAnswerCopy.contradictedByVerdict(3) != EmptyAnswerCopy.reasonWithNoVerdict(3))
        // The second names the fault as the CHECK's, which is what tells Dan it is not a finding about
        // those shows at all.
        #expect(EmptyAnswerCopy.reasonWithNoVerdict(3).contains("fault in the check"))
    }
}
