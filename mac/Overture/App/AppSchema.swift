import SwiftData

// The one list of models in Overture's live SwiftData store. Kept in a single place so the app and
// the migration dry-run reference the SAME schema, and a new model is added in exactly one spot.
//
// There is no MigrationPlan or VersionedSchema anywhere in this app: every schema change so far has
// been ADDITIVE (a new entity, and at most a defaulted column on an existing one), which SwiftData's
// lightweight migration handles on its own. The launch-time backup is the only safety net, so each
// addition is rehearsed against a clone of the live store before it ships (see InquiryMigrationDryRun).
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Prospect.self,
        Recipient.self,
        WatchedSource.self,
        DayOff.self,
        ExcludedTown.self,
        AllowedSeedTown.self,
        DismissedCoverageClient.self,
        Experiment.self,
        Inquiry.self,   // #1435: hire inquiries. A new INDEPENDENT entity, zero relationships to any
                        // existing model and no new columns on one, so the migration is purely additive.
    ]

    static var schema: Schema { Schema(models) }
}
