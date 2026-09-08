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
