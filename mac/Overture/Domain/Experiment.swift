import Foundation
import SwiftData

// #5 (opener A/B testing), Phase 1: the experiment framework's data + assignment logic.
//
// An Experiment is a true random A/B test on ONE dimension (opener shape today; subject-style is a
// documented extension point, deferred because the runbook deliberately fixes the subject formula). It
// holds two variants (each a preset opener archetype), and exactly ONE experiment is active at a time,
// run in sequence, with history retained (ended experiments are never deleted; each prospect carries its
// own stamp, so a past experiment's outcomes stay attributable after the next one starts).
//
// Design pillars locked by the plan (#1377):
//  - The tally keys on the APP-ASSIGNED arm (Prospect.assignedArm), NEVER the drafter's self-reported
//    echo (Prospect.draftVariant). Application of #804: the runner stamps the model, never the model
//    itself. The echo is only ever a compliance/drift signal.
//  - Assignment happens at draft (prep) time and is sticky + forward-only: a prospect that already
//    carries an assignedArm is never re-rolled (a re-prep must not rebias it), and an experiment
//    activated after a prospect was drafted never retroactively assigns it.
//  - "One active at a time" cannot be a SwiftData constraint (no partial unique index), so it is enforced
//    by a single atomic activate() mutation plus a guard test. Said plainly, not pretended in the schema.

// The controlled vocabulary for the opener dimension: the four archetypes the runbook (#362) rotates and
// docs/prep-runbook.md names. Raw values are the kebab tokens the drafter echoes into `variant` (#5 Phase
// 0) and the tokens check-brand-voice-drift.sh already anchors, so a variant defined here is verifiable
// against what the drafter reports and can never silently contradict the authoritative brand-voice skill.
enum OpenerArchetype: String, CaseIterable, Codable, Sendable {
    case reasonFirst = "reason-first"
    case credentialFirst = "credential-first"
    case observationFirst = "observation-first"
    case directIntent = "direct-intent"
}

// The dimension an experiment tests. Only openerShape ships now; subjectStyle is reserved and documented,
// not built (it would require first un-fixing the runbook's "subject stays fixed" rule).
enum ExperimentDimension: String, CaseIterable, Codable, Sendable {
    case openerShape = "openerShape"
}

@Model
final class Experiment {
    // Not `id`: PersistentModel already refines Identifiable through persistentModelID, and a stored
    // `var id` collides with it (the same convention as Prospect.naturalKey, ExcludedTown.town). This is
    // the opaque stamp copied onto each assigned Prospect.experimentID.
    @Attribute(.unique) var experimentId: String
    // Stored raw so an unknown future dimension degrades to nil rather than failing to decode (the
    // dismissReasonRaw / DismissReason pattern).
    var dimensionRaw: String
    // Each variant is an OpenerArchetype raw token (a preset). Stored as the raw string so the model stays
    // a plain @Model; the picker that creates an Experiment supplies valid tokens.
    var variantA: String
    var variantB: String
    var label: String?
    var startedAt: Date
    // nil == still active-eligible / never retired; set when Dan ends the experiment. Retention: ended
    // rows are never deleted, so the report can iterate active + past experiments.
    var endedAt: Date?
    // The one currently-assigning experiment. Enforced-single via ExperimentLifecycle.activate, not a DB
    // constraint. Defaulted so any future additive field migrates cleanly.
    var isActive: Bool = false

    var dimension: ExperimentDimension? { ExperimentDimension(rawValue: dimensionRaw) }

    init(experimentId: String = UUID().uuidString,
         dimension: ExperimentDimension,
         variantA: OpenerArchetype,
         variantB: OpenerArchetype,
         label: String? = nil,
         startedAt: Date = Date(),
         endedAt: Date? = nil,
         isActive: Bool = false) {
        self.experimentId = experimentId
        self.dimensionRaw = dimension.rawValue
        self.variantA = variantA.rawValue
        self.variantB = variantB.rawValue
        self.label = label
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isActive = isActive
    }
}

// One-active enforcement, kept OUT of any view (a rule in a SwiftUI body is a rule no test can reach;
// #863 is this repo's proof it drifts). activate() is the ONLY sanctioned way to make an experiment
// active, and it retires every other active row in the same save so the invariant can't be split.
@MainActor
enum ExperimentLifecycle {
    // Make `experiment` the sole active experiment: deactivate every other row, activate this one, one save.
    static func activate(_ experiment: Experiment, in context: ModelContext) throws {
        // Retire every other active row, activate this one, in a single save so the "one active"
        // invariant can never be observed split. Idempotent: re-activating the already-active one is fine.
        let all = (try? context.fetch(FetchDescriptor<Experiment>())) ?? []
        for other in all where other.experimentId != experiment.experimentId {
            other.isActive = false
        }
        experiment.isActive = true
        try context.save()
    }
}

// The random A/B assignment. The coin is a pure function of an injected uniform draw, so the decision is
// testable without randomness; the stamp-and-save is fail-loud (a save failure throws rather than
// silently leaving the store disagreeing with what a later phase would instruct the drafter to write).
@MainActor
enum ExperimentAssignment {
    // Pure: which arm a fair coin selects. `coin` is a uniform [0,1) draw the caller supplies. 50/50.
    static func arm(forCoin coin: Double, experiment: Experiment) -> String {
        // Half-open split: [0,0.5) -> A, [0.5,1) -> B. A uniform draw is fair 50/50.
        coin < 0.5 ? experiment.variantA : experiment.variantB
    }

    // The single active experiment, or nil. At most one by the activate() invariant.
    static func activeExperiment(in context: ModelContext) -> Experiment? {
        let all = (try? context.fetch(FetchDescriptor<Experiment>())) ?? []
        return all.first { $0.isActive }
    }

    // Stamp an A/B arm onto each eligible prospect that has none yet, under the active experiment, then
    // save once. Sticky/forward-only: a prospect already carrying an assignedArm is skipped (a re-prep
    // never re-randomizes). No active experiment => no-op. Fail-loud: the save throws on failure.
    static func assignArms(to prospects: [Prospect], in context: ModelContext,
                           coin: () -> Double = { Double.random(in: 0..<1) }) throws {
        guard let active = activeExperiment(in: context) else { return }
        var changed = false
        for p in prospects where p.assignedArm == nil {
            p.assignedArm = arm(forCoin: coin(), experiment: active)
            p.experimentID = active.experimentId
            changed = true
        }
        // Persist BEFORE the caller encodes the queue, so the handoff can never instruct an arm the store
        // didn't record. Fail-loud: a save failure throws rather than silently proceeding unassigned.
        if changed { try context.save() }
    }
}
