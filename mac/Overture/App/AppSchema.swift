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
        OrgReachabilityAnswer.self,   // #1598: the organisation answer ledger. Independent for the same
                                      // reason, so a dismissed or re-keyed prospect can never take an
                                      // answer Dan paid for with it.
        PromotedProducer.self,        // #1719: Dan's own producer/house corrections. Two more independent
        DemotedHouse.self,            // entities, no relationship to Prospect, so the migration is purely
                                      // additive and no re-key or sweep can take a correction with it.
        RefusedContactAddress.self,   // #2392: an address Dan struck. Independent for the same reason, so
                                      // a dismissed or re-keyed prospect can never quietly cancel a
                                      // refusal and let the next run write to somebody again.
        GenreCorrection.self,         // #2688: what the classifier read and what Dan said instead, so a
                                      // correction teaches the vocabulary something instead of being
                                      // spent on one row. Independent for the same reason as the rest:
                                      // the lesson must outlive the show that taught it.
        VenuePlaceAnswer.self,        // #1752: where Dan says a room is, when no table knows. Independent
                                      // for the same reason, and keyed on the ROOM so one answer reaches
                                      // every spelling of it and every show played there.
        CancelledShoot.self,          // #2692: a Downbeat booking Dan says is not happening. Independent
                                      // for the same reason as the rest, and keyed on the BOOKING id, so
                                      // a row left behind can never suppress a future booking landing on
                                      // the same date.
    ]

    static var schema: Schema { Schema(models) }
}
