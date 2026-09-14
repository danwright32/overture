import Testing
import Foundation
import SwiftData

// #3690: what a press-time resolution ACTUALLY does when the array it walks holds a row that has since
// been deleted. The issue's case rests on this being a crash rather than a stale answer, and that claim
// was read out of the code rather than measured, so it is measured here before anything is changed (L1,
// L177: make the environment print the fact before shipping a theory built from the symptom).
//
// `ProspectMutations.model(forKey:org:in:feedback:)` walks a caller-supplied array with
// `first(where: { $0.naturalKey == naturalKey })`, which reads a property off EVERY element it passes.
// `QueueView.swift:1565` supplies `data.queueScope`, captured when the render pass ran, and deletes run
// on the main context throughout a session.
@Suite("Resolving a press against a stale scope (#3690)")
@MainActor
struct PressTimeResolutionTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, key: String, name: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-10-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    // THE MEASUREMENT. Two rows, both captured in an array the way a render pass captures its scope. One
    // is deleted and the delete is SAVED, which is what a merge or a launch migration does. Then the
    // captured array is walked for the survivor, exactly as a button closure does at press time.
    //
    // The deleted row is placed FIRST so the walk must pass through it to reach the one being asked for:
    // a fixture with the target first would short-circuit and prove nothing (L165, damaging the end of
    // something lets the scenario finish its real work before failing).
    @Test func walkingACapturedScopePastADeletedRow() throws {
        let ctx = ModelContext(try container())
        let doomed = make(ctx, key: "doomed-key", name: "Doomed Show")
        let survivor = make(ctx, key: "survivor-key", name: "Survivor Show")
        try ctx.save()
        _ = survivor

        // The captured scope, deliberately ordered so the deleted row is walked first.
        let capturedScope = [doomed, survivor]

        ctx.delete(doomed)
        try ctx.save()

        let feedback = ActionFeedback()
        let found = ProspectMutations.model(forKey: "survivor-key", org: "Survivor Show",
                                            in: capturedScope, feedback: feedback)

        // WHAT THIS MEASURED, 2026-09-08: the walk SURVIVES. It passed the deleted row and resolved the
        // survivor, so the "reading a deleted model is a crash" premise that #3651, #3666 and #3690 were
        // all written on is false here. The hazard those issues describe is the WRONG ROW rather than a
        // crash, which is the sharper one anyway: `naturalKey` is unique and mutable, and a survivor
        // adopting a deleted loser's key resolves silently onto the wrong show.
        //
        // What this does NOT measure, stated so nobody reads it as more than it is: an in-memory store,
        // deleted on the same context. Production is file-backed and its deletes come from the launch
        // migrations and merge passes. A green here is not a licence to restore the crash language.
        let resolved = found?.groupName ?? "nil"
        print("press-time-resolution: resolved=\(resolved) walkedPastADeletedRow=true")
        #expect(found?.naturalKey == "survivor-key")
    }
}

// #3690, the hazard that SURVIVED the measurement above.
//
// The crash claim is disproved: a walk past a deleted, saved row resolves the survivor. What #3692
// deliberately left open is the WRONG ROW, and this is it, because it is not a hypothetical shape. Four
// merges in this app delete a row and keep another for the same night: `DuplicateContactMerge`,
// `SameNightTitleVariantMerge`, `DriftedRunMerge` and the launch sweep. A natural key is DERIVED from
// the title, date and venue (`Prospect.makeNaturalKey`), so the survivor of such a merge can carry the
// very key the deleted row had.
//
// When that happens, an array captured when the render pass ran still holds the DELETED object under
// that key, and `first(where:)` returns it because it is the first match in the array it was handed. The
// press then writes to a row the store has thrown away: no crash, no refusal, no banner, and the change
// Dan asked for is simply not there afterwards. That is worse than a crash, which at least reports
// itself (L12).
//
// THE RESOLVER IS NOT THE DEFECT. `ProspectMutations.model(forKey:org:in:feedback:)` answers correctly
// for whatever array it is handed, and seven of its callers genuinely need a collection rather than one
// row (`dismissAll`, `bulkReprep`, `setOrgDoNotContact`, `manualPrepPrefill`). The defect is entirely
// WHICH array the render path hands it, so the fix is at the call site and the guard belongs there too.
@Suite("A press resolves the row the store holds (#3690)")
@MainActor
struct PressResolvesTheStoredRowTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, key: String, name: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: name, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-10-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    /// THE HAZARD, proved rather than argued. A captured array and the live store give DIFFERENT answers
    /// for one key after a merge, which is the whole reason the wiring guards below matter. Stated as a
    /// disagreement rather than as "the resolver returns the loser", because the resolver is right about
    /// what it was handed and it is the handing that is wrong.
    @Test func aCapturedScopeAndTheLiveStoreDisagreeAboutWhichRowHoldsAKey() throws {
        let ctx = ModelContext(try container())
        let key = "a-show|2026-10-01|weill-recital-hall"

        let loser = make(ctx, key: key, name: "The Losing Copy")
        try ctx.save()
        // What a render pass captures, and what every row control used to close over.
        let capturedScope = [loser]

        // The merge: the loser goes, a survivor carrying the SAME derived key stays.
        ctx.delete(loser)
        let survivor = make(ctx, key: key, name: "The Surviving Copy")
        try ctx.save()

        let feedback = ActionFeedback()
        let fromCapturedScope = ProspectMutations.model(forKey: key, org: nil,
                                                        in: capturedScope, feedback: feedback)
        let live = try ctx.fetch(FetchDescriptor<Prospect>())
        let fromTheStore = ProspectMutations.model(forKey: key, org: nil, in: live, feedback: feedback)

        #expect(fromTheStore?.groupName == survivor.groupName,
                "resolving against the live store must reach the row the store actually holds")
        #expect(fromCapturedScope?.groupName != fromTheStore?.groupName,
                Comment(rawValue: "a captured scope and the live store agreed, so this fixture no longer "
                        + "reproduces the hazard and the guards below are protecting nothing (L1). "
                        + "captured: \(fromCapturedScope?.groupName ?? "nothing"), "
                        + "store: \(fromTheStore?.groupName ?? "nothing")"))
    }
}

// The wiring, which is where the defect actually lives. Source guards, because `ProspectRowFactory.row`
// takes nineteen arguments and every existing test of it in this suite is one
// (`RowFactoryBuildsOneConcreteCardGuardTests`, `DismissDayOffWiringGuardTests` and six others).
@Suite("No row control closes over a captured pass scope (#3690)")
struct RowControlsDoNotCaptureThePassScopeTests {

    /// The factory takes a PROVIDER, so the array is derived when a button is pressed rather than when a
    /// row is built. That is what makes it both live and free: `QueueModel.queueScope` is a whole-store
    /// filter AND a stable sort (`QueueView+Model.swift:1067`), so evaluating it per rendered row is the
    /// regression #3690 says the obvious fix would be. A closure is evaluated per PRESS.
    @Test func theRowFactoryTakesAProviderRatherThanAnArray() {
        let source = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        // Reduced to Bools BEFORE `#expect` sees them: an expectation renders its operands on failure,
        // and one of these is a whole file, which buries the message under it (L351, L148).
        let takesAProvider = source.contains("prospects: @escaping () -> [Prospect]")
        let stillTakesAnArray = source.contains("prospects: [Prospect],")
        #expect(takesAProvider,
                Comment(rawValue: "ProspectRowFactory.row does not take a scope PROVIDER. Handed an "
                        + "array, the caller must have derived it before the press, which is either "
                        + "stale (the pass's copy) or a whole-store filter and sort per rendered row."))
        #expect(stillTakesAnArray == false,
                "ProspectRowFactory.row still takes a plain [Prospect]")
    }

    /// And neither call site hands it the pass's own copy. `QueueView.swift:33` states the rule in its
    /// own words: the live query is "read from HERE only by the action handlers, which run on a press
    /// rather than during a render". This is that rule, enforced.
    @Test func neitherCallSitePassesThePassesOwnCopy() {
        for file in ["Overture/UI/QueueView.swift", "Overture/UI/ArchiveView.swift"] {
            let source = SourceGuardHelper.source(file)
            guard let call = source.range(of: "ProspectRowFactory.row(") else { continue }
            let line = source[call.lowerBound...].prefix(while: { $0 != "\n" })
            #expect(!line.contains("data.queueScope"),
                    Comment(rawValue: "\(file) hands ProspectRowFactory the render pass's captured scope. "
                            + "Those are model references frozen when the pass ran, and a merge that "
                            + "replaces a row under its own key leaves the deleted object in them."))
        }
    }

    /// The CLASS, not the two instances. A mutation runs on a press, so no mutation may ever be handed
    /// the pass's captured copy, whichever surface is calling and whichever mutation it is. Derived by
    /// scanning for the pairing rather than by listing the call sites, so a new mutation joins the rule
    /// on its own (L96, L30).
    @Test func noMutationIsHandedThePassesCapturedScope() {
        for file in ["Overture/UI/QueueView.swift", "Overture/UI/ArchiveView.swift",
                     "Overture/UI/ProspectRowFactory.swift"] {
            let source = SourceGuardHelper.source(file)
            let offending = source
                .components(separatedBy: "ProspectMutations.")
                .dropFirst()
                .filter { chunk in
                    // The call's own argument list, which ends at the first newline of the call.
                    chunk.prefix(while: { $0 != "\n" }).contains("data.queueScope")
                }
            #expect(offending.isEmpty,
                    Comment(rawValue: "\(file) hands a ProspectMutations call the render pass's captured "
                            + "scope. A mutation runs on a PRESS, and those model references were frozen "
                            + "when the pass ran, so a merge that replaced a row under its own key leaves "
                            + "the deleted object in them (#3690)."))
        }
    }
}
