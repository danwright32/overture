import Testing
import Foundation
import SwiftData

// #1880: a per-row Re-prep shows the same phase label the batch launch does.
//
// A Re-prep reached `PrepQueueService.startPrep` directly, so the takeover's listing progress stayed
// unset and the modal fell through to "Prepping" for the whole time the app was rendering the show's own
// listing page in a hidden browser. #1824 added that phase precisely so a launch spending tens of seconds
// there would not read as a dead button, and one of the three ways a run starts still read that way.
//
// The two phases have different ceilings and different failure meanings, which is why one label for both
// is not a cosmetic complaint.
@MainActor
@Suite("A per-row Re-prep reports the listing phase like every other launch (#1880)")
struct ReprepListingPhaseWiringTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(in ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "aurora|2026-11-14|carnegie", groupName: "Aurora Strings",
                         discipline: "music", venue: "Carnegie Hall", performanceDate: "2026-11-14",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.status = .approved
        ctx.insert(p)
        return p
    }

    // The seam is used: whatever launch it is handed is the one that runs, so a caller supplying the
    // takeover-aware launch gets it rather than the raw service call.
    @Test func thelaunchItIsHandedIsTheOneItUses() async throws {
        let ctx = ModelContext(try container())
        let p = show(in: ctx)
        var launched: Set<String> = []

        await ProspectMutations.reprep(QueueItem(p), mode: .draftOnly, prospects: [p], context: ctx,
                                       feedback: ActionFeedback(),
                                       startPrep: { _, _, keys in launched = keys })

        #expect(launched == [p.naturalKey], "the Re-prep has to launch through the seam it was given")
    }

    // And RootView supplies a real one. The default on `QueueView.onLaunchPrep` is the unwired behaviour,
    // kept so the view stays constructible without a takeover, so what makes the shipping path correct is
    // that RootView passes something. A default silently standing in for the wiring is exactly how this
    // phase went missing on one entry point in the first place (L46).
    @Test func rootViewSuppliesTheTakeoverAwareLaunch() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!root.isEmpty, "the guard read no source, so it asserts nothing")
        // The LAUNCH, not the label. `onLaunchPrep: nil` compiles and would satisfy a check for the
        // argument name while leaving the Re-prep exactly as unwired as before, so the guard asks for the
        // call that carries the phase.
        #expect(root.contains("onLaunchPrep: { ctx, now, keys in"),
                "RootView has to hand QueueView a real launch, or a Re-prep falls back to the default")
        #expect(root.contains("try await launchPrep(context: ctx"),
                "and that launch has to be the takeover-aware core, not something else")
        #expect(root.contains("func launchPrep("),
                "the shared launch core is what carries the listing phase")

        // One core, not two: the batch launch has to go through it as well, or the two entry points can
        // drift apart again, which is the whole defect.
        #expect(root.contains("try await launchPrep(context: context"),
                "the batch launch has to use the same core it hands to the Re-prep")
    }

    // The core is what raises the phase. Asserted on its body so a launch that stopped reporting progress
    // would be caught here rather than by somebody watching a modal.
    @Test func thelaunchCoreRaisesAndClearsTheListingPhase() throws {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        guard let body = SourceGuardHelper.between("func launchPrep(", and: "\n    private func startPrep",
                                                   in: root) else {
            Issue.record("launchPrep moved, so this guard reads nothing")
            return
        }
        for step in ["takeover.startListingRead(.prep", "takeover.finishListingRead(.prep",
                     "takeover.recordListingProgress(.prep"] {
            #expect(body.contains(step),
                    Comment(rawValue: "the launch core no longer does \(step), so the phase it exists to "
                            + "report is missing again"))
        }
    }
}
