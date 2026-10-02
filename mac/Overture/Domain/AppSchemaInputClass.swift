import Foundation

// #4356 (plan v7 Phase 2, discussion #4267): how each model in `AppSchema` reaches the queue, if it does.
//
// The queue engine (Phase 4) takes a store change in by KIND: a per-row change re-extracts one row's
// `RowFacts`, a small-table change moves the pass's input fingerprint, and a change to a table the queue
// never reads is ignored. A model nobody classified would be the third kind by default, which is the one
// that silently shows a stale queue (L72's direction, applied to intake). So every model is classified
// here, once, and `AppSchemaInputClassTests` holds this table to the code in both directions: to
// `AppSchema.models`, to the pass's own `Inputs`, and to the tables `QueueView` actually reads.
//
// NOTHING READS THIS YET. Phase 4's intake is its first reader (#4358).
enum AppSchemaInputClass: Equatable, Sendable {
    /// A row the engine keeps facts for. `parent` names the relationship that carries it into its owner's
    /// facts (a contact rides inside its show's `RowFacts`), or nil for a row that is a root of its own.
    /// `feeds` is the `QueueRenderPass.Inputs` field a root reaches the pass through.
    case perRowFact(parent: String?, feeds: String?)
    /// A whole table handed to the pass as a value. `feeds` names each `Inputs` path it reaches, written
    /// `field` or `field.subfield` (`context.geo` is the geography inside `StageContext`).
    case smallTableInput(feeds: [String])
    /// A table the pass never reads, with the reason. Where it changes what the queue shows, the reason
    /// names the stored field it does that through, which a row change already carries in.
    case notAQueueInput(reason: String)

    /// Every model in `AppSchema.models`, by its type name.
    static let byModel: [String: AppSchemaInputClass] = [
        "Prospect": .perRowFact(parent: nil, feeds: "allProspects"),
        "Recipient": .perRowFact(parent: "prospect", feeds: nil),
        "Inquiry": .perRowFact(parent: nil, feeds: "inquiries"),
        "OrgReachabilityAnswer": .smallTableInput(feeds: ["orgAnswers"]),
        "WatchedSource": .smallTableInput(feeds: ["sources", "context.clients"]),
        "RefusedContactAddress": .smallTableInput(feeds: ["refusals"]),
        "PromotedProducer": .smallTableInput(feeds: ["overrides"]),
        "DemotedHouse": .smallTableInput(feeds: ["overrides"]),
        "ExcludedTown": .smallTableInput(feeds: ["context.geo"]),
        "AllowedSeedTown": .smallTableInput(feeds: ["context.geo"]),
        "DayOff": .notAQueueInput(reason: """
            Reaches the queue only through `Prospect.conflictKey` and `conflictOpen`, which \
            `ConflictSweep.reapplyAll` writes on every day off edit, so the row change carries it in.
            """),
        "WeeklyDayOff": .notAQueueInput(reason: """
            Reaches the queue only through the same conflict fields, written by the same \
            `ConflictSweep.reapplyAll` on every weekly rule edit.
            """),
        "CancelledShoot": .notAQueueInput(reason: """
            Reaches the queue only through the same conflict fields, written by `ConflictSweep.reapplyAll` \
            when a shoot is cancelled or restored.
            """),
        "GenreCorrection": .notAQueueInput(reason: """
            Teaches the classifier's vocabulary. It reaches a show only as the `discipline` a later \
            classification writes onto the row.
            """),
        "VenuePlaceAnswer": .notAQueueInput(reason: """
            Reaches the queue only through `Prospect.location`, which `LocationBackfill` writes onto the \
            shows played in the answered room in the same call that records the answer.
            """),
        "Experiment": .notAQueueInput(reason: """
            The definition is read by the experiment report alone. A show's own arm is the \
            `experimentID` and `assignedArm` stored on the row.
            """),
        "DismissedCoverageClient": .notAQueueInput(reason: """
            Read by the Sources sheet's coverage panel alone.
            """),
        "LandingRun": .notAQueueInput(reason: """
            The record that a scout results file has landed (#4336), read only by the landing that \
            refuses the same file twice. The shows it landed reach the queue through their own rows.
            """),
    ]
}
