import Foundation
import SwiftData

// #4358 (plan v7 Phase 4, B2 "every pass input is a value"): the queue's inputs other than a show, as values.
//
// `RowFacts` (#4356) is one show and its contacts. The pass reads three more kinds of row: an inquiry, which is
// a root of its own and is taken in per row exactly like a show (`AppSchemaInputClass.byModel` names it
// `perRowFact`), and the small tables the pass is handed whole (`smallTableInput`). The queue engine keeps one
// value per stored row of each, keyed by `persistentModelID`, in its `FactStore`, so nothing it retains is a
// model that can fault the store or change underneath it, and so a change that alters nothing a term reads
// can be recognised by `==` and dropped (D2's equality gate).
//
// The rule is `RowFacts`' own: every stored property is CARRIED, because the two mistakes are not alike. A
// carried field no term reads costs one comparison; a field left out that some term does read is a retained
// row that never goes stale when it should (L40). None of these leaves anything out, so none has a
// `notReadByQueue` list, and `QueueEngineRecordsCoverTheSchemaTests` holds each one to `AppSchema.schema` in
// both directions, through the same finder `RowFactsSchemaCoverageTests` uses, so a property added to one of
// these models is a red test until somebody carries it.
//
// The two pairs of two column tables share a record each: a producer correction is a folded organisation key
// and when it was added, whichever direction it points, and a town refusal is a folded town and when, whichever
// list it is on. Which table a record came from is the dictionary it sits in (`FactStore`), never a field.
//
// Each copy is ONE call to the memberwise initialiser, so a field missing from it does not compile.
//
// NOTHING IN THE APP READS THESE YET. The queue engine fills them (#4358, slice E1); the value pass that reads
// them arrives with the cutover.

/// One inquiry, a root row of its own taken in per row like a show.
struct InquiryRecord: Equatable, Sendable {
    let persistentModelID: PersistentIdentifier

    let attachWroteSentAt: Bool
    let autoBookingRejectedWithoutId: Bool
    let bookingSuggested: Bool
    let bookingSuggestionDismissed: Bool
    let bounced: Bool
    let conversationAttachedAt: Date?
    let conversationSubject: String?
    let createdAt: Date
    let delayNoticeAt: Date?
    let dismissedBounceId: String?
    let dismissedReplyId: String?
    let downbeatClientId: String?
    let eventName: String
    let gmailMessageId: String?
    let gmailReferences: String?
    let gmailThreadId: String?
    let inboundReplyMessageId: String?
    let inboundReplySentAt: Date?
    let inquirerEmail: String?
    let inquirerName: String
    let lastBounceId: String?
    let lastDelayMessageId: String?
    let lastReplyId: String?
    let lastReplyText: String?
    let lostReasonRaw: String?
    let notes: String?
    let outcomeAt: Date?
    let outcomeRaw: String
    let outcomeSourceRaw: String?
    let performanceDate: String?
    let rejectedBookingIdsRaw: String
    let replied: Bool
    let repliedAt: Date?
    let replyAudience: [String]?
    let replyCandidateSearchedAt: Date?
    let replyFromAddress: String?
    let replyFromName: String?
    let replyHandledAt: Date?
    let replyTextCheckedAt: Date?
    let runEndDate: String?
    let sendError: String?
    let sentAt: Date?
    let showOutcomeAt: Date?
    let showOutcomeRaw: String?
    let sourceRaw: String
    let threadIdDegraded: Bool
    let threadingDegraded: Bool
    let venue: String?
}

extension InquiryRecord {
    nonisolated init(copying source: Inquiry) {
        self.init(persistentModelID: source.persistentModelID,
                  attachWroteSentAt: source.attachWroteSentAt,
                  autoBookingRejectedWithoutId: source.autoBookingRejectedWithoutId,
                  bookingSuggested: source.bookingSuggested,
                  bookingSuggestionDismissed: source.bookingSuggestionDismissed,
                  bounced: source.bounced,
                  conversationAttachedAt: source.conversationAttachedAt,
                  conversationSubject: source.conversationSubject,
                  createdAt: source.createdAt,
                  delayNoticeAt: source.delayNoticeAt,
                  dismissedBounceId: source.dismissedBounceId,
                  dismissedReplyId: source.dismissedReplyId,
                  downbeatClientId: source.downbeatClientId,
                  eventName: source.eventName,
                  gmailMessageId: source.gmailMessageId,
                  gmailReferences: source.gmailReferences,
                  gmailThreadId: source.gmailThreadId,
                  inboundReplyMessageId: source.inboundReplyMessageId,
                  inboundReplySentAt: source.inboundReplySentAt,
                  inquirerEmail: source.inquirerEmail,
                  inquirerName: source.inquirerName,
                  lastBounceId: source.lastBounceId,
                  lastDelayMessageId: source.lastDelayMessageId,
                  lastReplyId: source.lastReplyId,
                  lastReplyText: source.lastReplyText,
                  lostReasonRaw: source.lostReasonRaw,
                  notes: source.notes,
                  outcomeAt: source.outcomeAt,
                  outcomeRaw: source.outcomeRaw,
                  outcomeSourceRaw: source.outcomeSourceRaw,
                  performanceDate: source.performanceDate,
                  rejectedBookingIdsRaw: source.rejectedBookingIdsRaw,
                  replied: source.replied,
                  repliedAt: source.repliedAt,
                  replyAudience: source.replyAudience,
                  replyCandidateSearchedAt: source.replyCandidateSearchedAt,
                  replyFromAddress: source.replyFromAddress,
                  replyFromName: source.replyFromName,
                  replyHandledAt: source.replyHandledAt,
                  replyTextCheckedAt: source.replyTextCheckedAt,
                  runEndDate: source.runEndDate,
                  sendError: source.sendError,
                  sentAt: source.sentAt,
                  showOutcomeAt: source.showOutcomeAt,
                  showOutcomeRaw: source.showOutcomeRaw,
                  sourceRaw: source.sourceRaw,
                  threadIdDegraded: source.threadIdDegraded,
                  threadingDegraded: source.threadingDegraded,
                  venue: source.venue)
    }
}

/// One organisation's reachability answer (`OrgReachabilityAnswer`).
struct OrgAnswerRecord: Equatable, Sendable {
    let persistentModelID: PersistentIdentifier

    let foundEmailsRaw: String
    let orgKey: String
    let presenterName: String
    let probedAt: Date
    let resultRaw: String
    let sourceGroupName: String
    let sourceNaturalKey: String
}

extension OrgAnswerRecord {
    nonisolated init(copying source: OrgReachabilityAnswer) {
        self.init(persistentModelID: source.persistentModelID,
                  foundEmailsRaw: source.foundEmailsRaw,
                  orgKey: source.orgKey,
                  presenterName: source.presenterName,
                  probedAt: source.probedAt,
                  resultRaw: source.resultRaw,
                  sourceGroupName: source.sourceGroupName,
                  sourceNaturalKey: source.sourceNaturalKey)
    }
}

/// One watched calendar (`WatchedSource`).
struct WatchedSourceRecord: Equatable, Sendable {
    let persistentModelID: PersistentIdentifier

    let addedAt: Date
    let baselineFeedCount: Int
    let clientTagClientId: String?
    let clientTagOverride: Bool?
    let confirmedEmptyHash: String?
    let degradedStreak: Int
    let emptyStreak: Int
    let failedReadStreak: Int
    let hadPlacedBeforeLastRun: Bool
    let hasUnreadChanges: Bool
    let healthRaw: String
    let inactiveReasonRaw: String?
    let isActive: Bool
    let kindRaw: String
    let lastCheckedAt: Date?
    let lastContentHash: String?
    let lastDegradedCount: Int
    let lastDroppedShowLabelsRaw: String
    let lastErrorRaw: String?
    let lastFetchWasInsecure: Bool
    let lastLandedRunID: String?
    let lastLandedSequence: Int
    let lastManualReadAt: Date?
    let lastNonEmptyAt: Date?
    let lastObservedContentHash: String?
    let lastPlacedCount: Int
    let lastReadableCount: Int
    let lastStructuralGapCount: Int
    let lastSucceededAt: Date?
    let lastTouchedSequence: Int
    let lastUnreadableCount: Int
    let lastUnreadableTitleCount: Int
    let listingsURL: String?
    let mergeSameDateVenue: Bool
    let notes: String?
    let orgName: String
    let pageCount: Int
    let pendingContentHash: String?
    let pendingPageMonthsRaw: String
    let sourceId: String
    let successfulCheckCount: Int
    let ticketingFeedURL: String?
    let venueLocation: String?
    let venueName: String?
}

extension WatchedSourceRecord {
    nonisolated init(copying source: WatchedSource) {
        self.init(persistentModelID: source.persistentModelID,
                  addedAt: source.addedAt,
                  baselineFeedCount: source.baselineFeedCount,
                  clientTagClientId: source.clientTagClientId,
                  clientTagOverride: source.clientTagOverride,
                  confirmedEmptyHash: source.confirmedEmptyHash,
                  degradedStreak: source.degradedStreak,
                  emptyStreak: source.emptyStreak,
                  failedReadStreak: source.failedReadStreak,
                  hadPlacedBeforeLastRun: source.hadPlacedBeforeLastRun,
                  hasUnreadChanges: source.hasUnreadChanges,
                  healthRaw: source.healthRaw,
                  inactiveReasonRaw: source.inactiveReasonRaw,
                  isActive: source.isActive,
                  kindRaw: source.kindRaw,
                  lastCheckedAt: source.lastCheckedAt,
                  lastContentHash: source.lastContentHash,
                  lastDegradedCount: source.lastDegradedCount,
                  lastDroppedShowLabelsRaw: source.lastDroppedShowLabelsRaw,
                  lastErrorRaw: source.lastErrorRaw,
                  lastFetchWasInsecure: source.lastFetchWasInsecure,
                  lastLandedRunID: source.lastLandedRunID,
                  lastLandedSequence: source.lastLandedSequence,
                  lastManualReadAt: source.lastManualReadAt,
                  lastNonEmptyAt: source.lastNonEmptyAt,
                  lastObservedContentHash: source.lastObservedContentHash,
                  lastPlacedCount: source.lastPlacedCount,
                  lastReadableCount: source.lastReadableCount,
                  lastStructuralGapCount: source.lastStructuralGapCount,
                  lastSucceededAt: source.lastSucceededAt,
                  lastTouchedSequence: source.lastTouchedSequence,
                  lastUnreadableCount: source.lastUnreadableCount,
                  lastUnreadableTitleCount: source.lastUnreadableTitleCount,
                  listingsURL: source.listingsURL,
                  mergeSameDateVenue: source.mergeSameDateVenue,
                  notes: source.notes,
                  orgName: source.orgName,
                  pageCount: source.pageCount,
                  pendingContentHash: source.pendingContentHash,
                  pendingPageMonthsRaw: source.pendingPageMonthsRaw,
                  sourceId: source.sourceId,
                  successfulCheckCount: source.successfulCheckCount,
                  ticketingFeedURL: source.ticketingFeedURL,
                  venueLocation: source.venueLocation,
                  venueName: source.venueName)
    }
}

/// One address Dan has struck (`RefusedContactAddress`).
struct RefusedAddressRecord: Equatable, Sendable {
    let persistentModelID: PersistentIdentifier

    let handleKey: String
    let id: String
    let refusedAt: Date
    let scopeId: String
    let scopeRaw: String
}

extension RefusedAddressRecord {
    nonisolated init(copying source: RefusedContactAddress) {
        self.init(persistentModelID: source.persistentModelID,
                  handleKey: source.handleKey,
                  id: source.id,
                  refusedAt: source.refusedAt,
                  scopeId: source.scopeId,
                  scopeRaw: source.scopeRaw)
    }
}

/// One producer correction, from either direction's table (`PromotedProducer` or `DemotedHouse`).
struct ProducerOverrideRecord: Equatable, Sendable {
    let persistentModelID: PersistentIdentifier

    let addedAt: Date
    let orgKey: String
}

extension ProducerOverrideRecord {
    nonisolated init(copying source: PromotedProducer) {
        self.init(persistentModelID: source.persistentModelID, addedAt: source.addedAt, orgKey: source.orgKey)
    }

    nonisolated init(copying source: DemotedHouse) {
        self.init(persistentModelID: source.persistentModelID, addedAt: source.addedAt, orgKey: source.orgKey)
    }
}

/// One town refusal, from either list (`ExcludedTown` or `AllowedSeedTown`).
struct TownRecord: Equatable, Sendable {
    let persistentModelID: PersistentIdentifier

    let addedAt: Date
    let town: String
}

extension TownRecord {
    nonisolated init(copying source: ExcludedTown) {
        self.init(persistentModelID: source.persistentModelID, addedAt: source.addedAt, town: source.town)
    }

    nonisolated init(copying source: AllowedSeedTown) {
        self.init(persistentModelID: source.persistentModelID, addedAt: source.addedAt, town: source.town)
    }
}
