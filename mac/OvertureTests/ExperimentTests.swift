import Testing
import Foundation
import SwiftData

// #5 (opener A/B testing), Phase 1: the experiment model, one-active lifecycle, and app-side 50/50
// assignment. Every decision lives in a pure/testable function (never a view), so these prove behavior
// directly: the coin, the one-active invariant, and sticky/forward-only/active-gated assignment.
@MainActor
struct ExperimentTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Experiment.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeProspect(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: nil,
                 performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "", profile: "", coverage: "",
                 fitScore: 50, tier: "B", fitReason: "", matchedClientName: nil,
                 possibleMatchSource: nil, possibleMatchName: nil)
    }

    // MARK: - Vocabulary

    @Test func theOpenerArchetypesAreTheKebabTokensTheDrafterEchoes() {
        #expect(OpenerArchetype.allCases.map(\.rawValue).sorted()
                == ["credential-first", "direct-intent", "observation-first", "reason-first"])
    }

    // Dan retired credential-first and observation-first on 2026-07-31. Credential-first led with venues
    // before the reader knew what Dan does, the job the fixed self-introduction now owns; observation-first
    // had only the show's own material to observe, which the "name the show, describe nothing" rule
    // forbids, and reached for scarcity once that was gone. Both raw values SURVIVE in the enum: a stored
    // experiment's arms and every past prospect's assignedArm are raw strings the report reads back
    // through it, so history stays readable. What changes is that neither may be CHOSEN again.
    @Test func aRetiredArchetypeIsNotOfferedForANewExperiment() {
        #expect(OpenerArchetype.selectable.map(\.rawValue).sorted() == ["direct-intent", "reason-first"])
        #expect(OpenerArchetype.observationFirst.isRetired)
        #expect(OpenerArchetype.credentialFirst.isRetired)
        #expect(!OpenerArchetype.reasonFirst.isRetired)
        #expect(!OpenerArchetype.directIntent.isRetired)
    }

    // The picker is not the enforcement: a rule that lives only in a SwiftUI body is a rule no test can
    // reach (#863). start() itself must refuse a retired arm, in either slot, and create nothing.
    @Test func startingAnExperimentOnARetiredArmIsRefused() throws {
        let ctx = ModelContext(try container())
        let asVariantA = try ExperimentEditing.start(variantA: .credentialFirst, variantB: .reasonFirst,
                                                     startedAt: Date(timeIntervalSince1970: 0), in: ctx)
        #expect(asVariantA == nil)
        let asVariantB = try ExperimentEditing.start(variantA: .reasonFirst, variantB: .observationFirst,
                                                     startedAt: Date(timeIntervalSince1970: 10), in: ctx)
        #expect(asVariantB == nil)
        #expect(try ctx.fetch(FetchDescriptor<Experiment>()).isEmpty)   // nothing created either time
        // The two live shapes still start normally, so the refusal is specific and not a blanket break.
        let live = try ExperimentEditing.start(variantA: .reasonFirst, variantB: .directIntent,
                                               startedAt: Date(timeIntervalSince1970: 20), in: ctx)
        #expect(live != nil)
    }

    // A retired token still has to render as a label wherever a past experiment or a past prospect's arm
    // is displayed, or retiring the shape would silently turn the report's history into raw kebab tokens.
    @Test func aStoredExperimentOnARetiredArmStillLabels() {
        #expect(OpenerArchetype(rawValue: "observation-first")?.label == "Observation First")
        #expect(OpenerArchetype(rawValue: "credential-first")?.label == "Credential First")
    }

    // MARK: - The coin (pure)

    @Test func aLowCoinPicksVariantAAndAHighCoinPicksVariantB() {
        let exp = Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst)
        #expect(ExperimentAssignment.arm(forCoin: 0.0, experiment: exp) == "reason-first")
        #expect(ExperimentAssignment.arm(forCoin: 0.49, experiment: exp) == "reason-first")
        // The boundary belongs to B, so a fair 50/50 split is exactly [0,0.5) vs [0.5,1).
        #expect(ExperimentAssignment.arm(forCoin: 0.5, experiment: exp) == "credential-first")
        #expect(ExperimentAssignment.arm(forCoin: 0.99, experiment: exp) == "credential-first")
    }

    // MARK: - One active at a time

    @Test func activatingAnExperimentRetiresEveryOtherActiveOne() throws {
        let ctx = ModelContext(try container())
        let a = Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst, isActive: true)
        let b = Experiment(dimension: .openerShape, variantA: .observationFirst, variantB: .directIntent)
        ctx.insert(a)
        ctx.insert(b)
        try ctx.save()

        try ExperimentLifecycle.activate(b, in: ctx)

        let all = try ctx.fetch(FetchDescriptor<Experiment>())
        #expect(all.filter(\.isActive).count == 1)
        #expect(all.first { $0.isActive }?.experimentId == b.experimentId)
    }

    @Test func activatingTheAlreadyActiveExperimentIsIdempotent() throws {
        let ctx = ModelContext(try container())
        let a = Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst)
        ctx.insert(a)
        try ctx.save()

        try ExperimentLifecycle.activate(a, in: ctx)
        try ExperimentLifecycle.activate(a, in: ctx)

        let all = try ctx.fetch(FetchDescriptor<Experiment>())
        #expect(all.filter(\.isActive).count == 1)
        #expect(all.first { $0.isActive }?.experimentId == a.experimentId)
    }

    // MARK: - Assignment (sticky, forward-only, active-gated)

    @Test func withNoActiveExperimentNothingIsAssigned() throws {
        let ctx = ModelContext(try container())
        // An experiment exists but is NOT active.
        ctx.insert(Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst))
        let p = makeProspect("k1")
        ctx.insert(p)
        try ctx.save()

        try ExperimentAssignment.assignArms(to: [p], in: ctx, coin: { 0.1 })

        #expect(p.assignedArm == nil)
        #expect(p.experimentID == nil)
    }

    @Test func anUnassignedProspectUnderTheActiveExperimentGetsTheCoinsArmAndTheExperimentId() throws {
        let ctx = ModelContext(try container())
        let exp = Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst, isActive: true)
        ctx.insert(exp)
        let p = makeProspect("k1")
        ctx.insert(p)
        try ctx.save()

        try ExperimentAssignment.assignArms(to: [p], in: ctx, coin: { 0.9 })

        #expect(p.assignedArm == "credential-first")   // high coin -> variant B
        #expect(p.experimentID == exp.experimentId)
    }

    @Test func anAlreadyAssignedProspectIsNeverReRolled() throws {
        let ctx = ModelContext(try container())
        let exp = Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst, isActive: true)
        ctx.insert(exp)
        let p = makeProspect("k1")
        p.assignedArm = "reason-first"
        p.experimentID = "an-earlier-experiment"
        ctx.insert(p)
        try ctx.save()

        // A coin that WOULD choose the other arm must not change a prospect that already carries one.
        try ExperimentAssignment.assignArms(to: [p], in: ctx, coin: { 0.99 })

        #expect(p.assignedArm == "reason-first")
        #expect(p.experimentID == "an-earlier-experiment")
    }

    // MARK: - Wiring into the real Prep path

    @Test func startPrepStampsTheActiveExperimentsArmOntoEligibleProspects() async throws {
        let ctx = ModelContext(try container())
        let exp = Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst, isActive: true)
        ctx.insert(exp)
        // A kept-undrafted prospect: needs-prep-eligible, so it is queued and thus assignment-eligible.
        let toPrep = Prospect(naturalKey: "to-prep", groupName: "G", discipline: "music", venue: "V",
                              performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                              priorRelationship: "none", production: "self", profile: "strong",
                              coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                              status: .queued)
        ctx.insert(toPrep)
        try ctx.save()

        let tmp = FileManager.default.temporaryDirectory
        let queueURL = tmp.appendingPathComponent("q-\(UUID().uuidString).json")
        let marker = tmp.appendingPathComponent("m-\(UUID().uuidString)")
        let feedbackURL = tmp.appendingPathComponent("vf-\(UUID().uuidString).json")
        let openersURL = tmp.appendingPathComponent("ro-\(UUID().uuidString).json")
        defer { [queueURL, marker, feedbackURL, openersURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        try await PrepQueueService.startPrep(from: ctx, now: Date(timeIntervalSince1970: 0),
                                             queueURL: queueURL, markerURL: marker,
                                             voiceFeedbackURL: feedbackURL, recentOpenersURL: openersURL,
                                             launch: {})

        #expect(["reason-first", "credential-first"].contains(toPrep.assignedArm))
        #expect(toPrep.experimentID == exp.experimentId)
    }

    // #5 Phase 2: the assigned arm reaches the drafter over the queue. A prospect carrying an assignedArm
    // produces a queue item whose experimentArmInstruction is that arm; an unassigned one carries nil.
    @Test func buildQueueCarriesTheAssignedArmAsTheItemInstruction() throws {
        let ctx = ModelContext(try container())
        let assigned = Prospect(naturalKey: "assigned", groupName: "G", discipline: "music", venue: "V",
                                performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                                priorRelationship: "none", production: "self", profile: "strong",
                                coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                                matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                status: .queued)
        assigned.assignedArm = "credential-first"
        let plain = Prospect(naturalKey: "plain", groupName: "G2", discipline: "music", venue: "V",
                             performanceDate: "2026-08-02", sourceListingURL: nil, websiteURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .queued)
        ctx.insert(assigned)
        ctx.insert(plain)
        try ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "2026-06-25T00:00:00.000Z")
        let byKey = Dictionary(uniqueKeysWithValues: queue.items.map { ($0.naturalKey, $0) })
        #expect(byKey["assigned"]?.experimentArmInstruction == "credential-first")
        #expect(byKey["plain"]?.experimentArmInstruction == nil)
    }

    // MARK: - Phase 4: experiment management (create / end)

    @Test func startCreatesAndActivatesAnExperimentFromTwoDistinctArms() throws {
        let ctx = ModelContext(try container())
        let exp = try ExperimentEditing.start(variantA: .reasonFirst, variantB: .directIntent,
                                              startedAt: Date(timeIntervalSince1970: 0), in: ctx)
        #expect(exp != nil)
        let all = try ctx.fetch(FetchDescriptor<Experiment>())
        #expect(all.count == 1)
        #expect(all.first?.isActive == true)
        #expect(all.first?.variantA == "reason-first")
        #expect(all.first?.variantB == "direct-intent")
    }

    @Test func startRefusesTwoIdenticalArms() throws {
        let ctx = ModelContext(try container())
        let exp = try ExperimentEditing.start(variantA: .reasonFirst, variantB: .reasonFirst,
                                              startedAt: Date(timeIntervalSince1970: 0), in: ctx)
        #expect(exp == nil)
        #expect(try ctx.fetch(FetchDescriptor<Experiment>()).isEmpty)   // nothing created
    }

    @Test func startingANewExperimentRetiresThePreviousActiveOne() throws {
        let ctx = ModelContext(try container())
        _ = try ExperimentEditing.start(variantA: .reasonFirst, variantB: .directIntent,
                                        startedAt: Date(timeIntervalSince1970: 0), in: ctx)
        _ = try ExperimentEditing.start(variantA: .directIntent, variantB: .reasonFirst,
                                        startedAt: Date(timeIntervalSince1970: 10), in: ctx)
        let active = try ctx.fetch(FetchDescriptor<Experiment>()).filter(\.isActive)
        #expect(active.count == 1)
        #expect(active.first?.variantA == "direct-intent")
    }

    @Test func endingAnExperimentDeactivatesItButKeepsItAsHistory() throws {
        let ctx = ModelContext(try container())
        let exp = try #require(try ExperimentEditing.start(variantA: .reasonFirst, variantB: .directIntent,
                                                           startedAt: Date(timeIntervalSince1970: 0), in: ctx))
        try ExperimentEditing.end(exp, at: Date(timeIntervalSince1970: 100), in: ctx)
        let all = try ctx.fetch(FetchDescriptor<Experiment>())
        #expect(all.count == 1)                         // NOT deleted: history retained
        #expect(all.first?.isActive == false)
        #expect(all.first?.endedAt == Date(timeIntervalSince1970: 100))
    }

    // MARK: - Phase 4: the reporting logic (ExperimentReport)

    // A prospect that was SENT under an experiment arm, with a given outcome and drafter echo.
    private func sentProspect(_ key: String, experimentId: String, arm: String, outcome: Outcome,
                              draftVariant: String, edited: Bool = false) -> Prospect {
        let p = makeProspect(key)
        p.experimentID = experimentId
        p.assignedArm = arm
        p.gmailMessageId = "msg-\(key)"           // wasProvablyContacted == gmailMessageId != nil
        p.outcomeRaw = outcome.rawValue
        p.draftVariant = draftVariant
        p.experimentOpenerEdited = edited
        return p
    }

    @Test func armReportCountsOnlySentNonEditedIntoTheRateAndSeparatesEdited() {
        let e = "exp1"
        let prospects = [
            sentProspect("a", experimentId: e, arm: "reason-first", outcome: .replied, draftVariant: "reason-first"),
            sentProspect("b", experimentId: e, arm: "reason-first", outcome: .noResponse, draftVariant: "reason-first"),
            sentProspect("c", experimentId: e, arm: "reason-first", outcome: .replied, draftVariant: "reason-first", edited: true),
        ]
        let arm = ExperimentReport.armReport(arm: "reason-first", in: prospects)
        #expect(arm.tally.contacted == 2)                 // the edited one is excluded from the rate
        #expect(arm.tally.replied == 1)
        #expect(arm.editedExcluded == 1)                  // but still counted, visibly
    }

    @Test func armReportComplianceCountsEchoMatchesAgainstTheAssignedArm() {
        let e = "exp1"
        let prospects = [
            sentProspect("a", experimentId: e, arm: "reason-first", outcome: .noResponse, draftVariant: "reason-first"),
            // Drifted: the drafter produced a different shape than assigned.
            sentProspect("b", experimentId: e, arm: "reason-first", outcome: .noResponse, draftVariant: "credential-first"),
        ]
        let arm = ExperimentReport.armReport(arm: "reason-first", in: prospects)
        #expect(arm.complianceMatched == 1)
        #expect(arm.complianceTotal == 2)
        #expect(arm.complianceRate == 0.5)
    }

    @Test func reportScopesToTheExperimentAndBuildsAnArmPerVariant() {
        let exp = Experiment(experimentId: "exp1", dimension: .openerShape,
                             variantA: .reasonFirst, variantB: .credentialFirst, isActive: true)
        let prospects = [
            sentProspect("a", experimentId: "exp1", arm: "reason-first", outcome: .replied, draftVariant: "reason-first"),
            sentProspect("b", experimentId: "exp1", arm: "credential-first", outcome: .noResponse, draftVariant: "credential-first"),
            // A prospect in a DIFFERENT experiment must not leak in.
            sentProspect("c", experimentId: "other", arm: "reason-first", outcome: .booked, draftVariant: "reason-first"),
        ]
        let report = ExperimentReport.report(for: exp, allProspects: prospects)
        #expect(report.arms.map(\.arm) == ["reason-first", "credential-first"])
        #expect(report.arms[0].tally.contacted == 1)      // only the exp1 reason-first prospect, not "c"
        #expect(report.arms[1].tally.contacted == 1)
    }

    @Test func bothArmsMustClearTheHighBarBeforeItIsNotTooFewToTell() {
        func armAt(_ contacted: Int) -> ExperimentReport.ArmReport {
            var t = OutcomeTally(); t.contacted = contacted
            return ExperimentReport.ArmReport(arm: "x", tally: t, editedExcluded: 0, complianceMatched: contacted, complianceTotal: contacted)
        }
        let bar = ExperimentReport.experimentCallThreshold
        let bothClear = ExperimentReport.Report(experimentId: "e", arms: [armAt(bar), armAt(bar)])
        #expect(bothClear.tooFewToTell == false)
        // One arm one short: still too few to tell (never ride one thin arm on the other's volume).
        let oneShort = ExperimentReport.Report(experimentId: "e", arms: [armAt(bar), armAt(bar - 1)])
        #expect(oneShort.tooFewToTell == true)
    }

    @Test func displayLinesHidePercentBelowTheBarAndSuppressEmptyCounts() {
        var t = OutcomeTally(); t.contacted = 2; t.replied = 1
        let arm = ExperimentReport.ArmReport(arm: "reason-first", tally: t, editedExcluded: 0,
                                             complianceMatched: 0, complianceTotal: 0)
        // Below the bar: the reply line names the count but NOT a percentage.
        #expect(ExperimentReport.replyLine(arm, tooFewToTell: true) == "1 replied of 2")
        // No edited sends and no counted sends: neither line appears.
        #expect(ExperimentReport.editedExcludedLine(arm) == nil)
        #expect(ExperimentReport.complianceLine(arm) == nil)
        // No sends at all: the #4-gate send-volume line stays silent too (never "0 of 30").
        #expect(ExperimentReport.sendVolumeLine(arm) == nil)
    }

    @Test func sendVolumeLineShowsProgressTowardTheBarThenMarksItCleared() {
        // #1396: surface countedSends (the deferred-#4 gate number) as per-arm progress toward the
        // sample bar, which the reply line and the global banner never frame per arm.
        func arm(counted: Int) -> ExperimentReport.ArmReport {
            var t = OutcomeTally(); t.contacted = counted
            return ExperimentReport.ArmReport(arm: "reason-first", tally: t, editedExcluded: 0,
                                              complianceMatched: counted, complianceTotal: counted)
        }
        let bar = ExperimentReport.experimentCallThreshold
        #expect(ExperimentReport.sendVolumeLine(arm(counted: 12)) == "12 of \(bar) sends toward a reliable read")
        // At or past the bar it must not read "30 of 30" / "35 of 30"; it flips to a cleared line.
        #expect(ExperimentReport.sendVolumeLine(arm(counted: bar)) == "\(bar) sends in, enough for the rate to mean something")
        #expect(ExperimentReport.sendVolumeLine(arm(counted: bar + 5)) == "\(bar + 5) sends in, enough for the rate to mean something")
    }

    @Test func editedExcludedLineCarriesTheRewriteRate() {
        // #1396: the raw edited count is already shown, so the NEW gate number is the rewrite rate (%),
        // folded into this one line rather than a duplicate line about the same edits (#843).
        // 3 edited of (12 counted + 3 edited) = 3/15 = 20%.
        var t = OutcomeTally(); t.contacted = 12
        let arm = ExperimentReport.ArmReport(arm: "reason-first", tally: t, editedExcluded: 3,
                                             complianceMatched: 12, complianceTotal: 12)
        #expect(arm.rewriteRate == 0.2)
        #expect(ExperimentReport.editedExcludedLine(arm) == "3 edited (20% of sends), excluded from the rate")
    }

    @Test func tooFewToTellLineNamesTheSampleBar() {
        // The honest banner must state the actual bar, so a future threshold change updates the words too.
        #expect(ExperimentReport.tooFewToTellLine().contains("\(ExperimentReport.experimentCallThreshold)"))
    }

    // MARK: - Phase 3: send-time opener-edit detection

    @Test func openerEditIsFalseWhenDanNeverEdited() {
        // originalDraftBody nil == Dan never substantively edited, so the assigned opener is unchanged.
        #expect(Prospect.experimentOpenerWasEdited(originalDraftBody: nil, draftBody: "Any body. Rest.") == false)
    }

    @Test func openerEditIsFalseWhenOnlyTheBodyTailChanged() {
        // The opener SENTENCE is identical; only later text differs, so the arm's opener was NOT changed.
        let ai = "I photograph performing arts in New York. Original tail sentence."
        let sent = "I photograph performing arts in New York. A completely different tail sentence."
        #expect(Prospect.experimentOpenerWasEdited(originalDraftBody: ai, draftBody: sent) == false)
    }

    @Test func openerEditIsTrueWhenTheOpenerSentenceChanged() {
        let ai = "I photograph performing arts in New York. Tail."
        let sent = "Your Carnegie Hall run caught my eye. Tail."
        #expect(Prospect.experimentOpenerWasEdited(originalDraftBody: ai, draftBody: sent) == true)
    }

    @Test func freezeStampsOpenerEditedForAnExperimentSendWhoseOpenerChanged() {
        let p = makeProspect("k1")
        p.assignedArm = "reason-first"
        p.originalDraftBody = "I photograph performing arts in New York. Tail."   // the AI's produced body
        p.draftBody = "Your Carnegie Hall run caught my eye. Tail."               // Dan rewrote the opener
        // The passed `body` is a performer-style override; the stamp must ignore it and judge the shared body.
        p.freezeSentCopy(subject: "S", body: "A second-person override body Dan cannot edit. Tail.")
        #expect(p.experimentOpenerEdited == true)
    }

    @Test func freezeLeavesOpenerEditedFalseWhenTheOpenerWasNotChanged() {
        let p = makeProspect("k1")
        p.assignedArm = "reason-first"
        p.originalDraftBody = "I photograph performing arts in New York. Old tail."
        p.draftBody = "I photograph performing arts in New York. New tail."
        p.freezeSentCopy(subject: "S", body: "eff")
        #expect(p.experimentOpenerEdited == false)
    }

    @Test func freezeDoesNotStampOpenerEditedForANonExperimentSend() {
        let p = makeProspect("k1")
        // No assignedArm: not under an experiment, so the flag stays false even if the opener changed.
        p.originalDraftBody = "I photograph performing arts in New York. Tail."
        p.draftBody = "Totally different opener. Tail."
        p.freezeSentCopy(subject: "S", body: "eff")
        #expect(p.experimentOpenerEdited == false)
    }

    @Test func assignmentPersistsSoAReFetchSeesTheStampedArm() throws {
        let ctx = ModelContext(try container())
        let exp = Experiment(dimension: .openerShape, variantA: .reasonFirst, variantB: .credentialFirst, isActive: true)
        ctx.insert(exp)
        ctx.insert(makeProspect("k1"))
        try ctx.save()

        let eligible = try ctx.fetch(FetchDescriptor<Prospect>())
        try ExperimentAssignment.assignArms(to: eligible, in: ctx, coin: { 0.1 })

        let refetched = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(refetched.first?.assignedArm == "reason-first")   // low coin -> variant A
    }
}
