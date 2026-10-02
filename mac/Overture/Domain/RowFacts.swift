import Foundation
import SwiftData

// #4356 (plan v7 Phase 2): one show as a VALUE, the retained half of `ProspectFacts`.
//
// A `RowFacts` is what the queue engine (Phase 4) keeps per row instead of holding the live `Prospect`:
// `Sendable`, so the verifier can read it off the main thread; `Equatable`, so an edit that changed nothing
// a term reads (D2's equality gate) is recognised and dropped; and free of any model, so nothing retained
// can fault the store or see a field change underneath it (`RowFactsHoldNoModelTests`).
//
// `extract(_:)` is TYPED, per-field code rather than a read through `ScopeFields`, whose key paths are
// `AnyKeyPath` and can arm observation but cannot fill a typed value (#4106 premise, discussion #4267).
// It is `nonisolated` so the verifier thread can extract from its own background context.
//
// The field list is every stored property of `Prospect` bar `notReadByQueue`, held to the schema in both
// directions by `RowFactsSchemaCoverageTests`; see `ProspectFacts` for why carrying is the default. The one
// relationship, `recipients`, is carried as `factContacts`: one `RecipientRecord` per contact in the
// canonical order, so a retained row holds values rather than the related models.
struct RowFacts: ProspectFacts, Equatable, Sendable {
    let persistentModelID: PersistentIdentifier
    let factContacts: [RecipientRecord]
    let foldedKeys: RowKeys

    let alreadyCoveredDismissed: Bool
    let alreadyCoveredNote: String?
    let arrivedLookingLike: String?
    let arrivedOnAPitchedNight: String?
    let assignedArm: String?
    let autoBookedFromBookingId: String?
    let autoBookingRejectedWithoutId: Bool
    let bookingSuggested: Bool
    let bookingSuggestionDismissed: Bool
    let classificationOverriddenByDan: Bool
    let conflictClearedKey: String?
    let conflictKey: String?
    let conflictOpen: Bool
    let contactRouteAtScore: String?
    let contactTierAtScore: String?
    let contradictionMarkedAt: Date?
    let coverage: String
    let coverageAtSend: String?
    let discipline: String
    let disciplineAtSend: String?
    let disciplineGenreSourceKey: String?
    let dismissReasonRaw: String?
    let dismissedAt: Date?
    let dismissedReplyId: String?
    let downbeatClientId: String?
    let draftBody: String?
    let draftEditedByDan: Bool
    let draftModel: String?
    let draftSubject: String?
    let draftVariant: String?
    let draftWrittenByDan: Bool
    let droppedRunNights: [String]
    let excludedFromVoiceLearning: Bool
    let experimentID: String?
    let experimentOpenerEdited: Bool
    let firstSeenAt: Date?
    let fitReason: String
    let fitScore: Int
    let fitScoreAtSend: Int?
    let fitScoreBeforeContactCheck: Int?
    let followUpCount: Int
    let gmailMessageId: String?
    let gmailThreadId: String?
    let groupName: String
    let groupNameOverriddenByDan: Bool
    let heldBackAt: Date?
    let heldBackBySlot: String?
    let keptVisibleAfterGenreChange: Bool
    let lastFollowUpAt: Date?
    let lastReplyAt: Date?
    let lastReplyId: String?
    let lastReplyText: String?
    let location: String?
    let lostReason: String?
    let matchedClientName: String?
    let matchedPerformerName: String?
    let mergeSurvivorUnseenAt: Date?
    let missedScoutCount: Int
    let naturalKey: String
    let nightStartTimes: [String]
    let orgDoNotContact: Bool
    let originalDraftBody: String?
    let originalDraftSubject: String?
    let outcomeAt: Date?
    let outcomeRaw: String
    let outcomeSourceRaw: String?
    let outreachStoodDownAt: Date?
    let partOfRelatedRun: Bool
    let passedOnThisShow: Bool
    let performanceDate: String?
    let performanceStartTimes: [String]
    let performerMatchDismissed: Bool
    let performerMatchNote: String?
    let performerMatchPreviousDownbeatClientId: String?
    let performerMatchPreviousFitScore: Int?
    let performerMatchPreviousMatchedClientName: String?
    let performerMatchPreviousRelationship: String?
    let performerMatchPreviousTier: String?
    let performerMatchReviewed: Bool
    let pitchedRunNights: [String]
    let possibleMatchName: String?
    let possibleMatchSource: String?
    let presenter: String?
    let presenterSource: String?
    let presenterSourceKey: String?
    let presenterWasTheRoom: Bool?
    let priorRelationship: String
    let priorRelationshipAtSend: String?
    let producerAxisSourceKey: String?
    let production: String
    let productionAtSend: String?
    let profile: String
    let profileAtSend: String?
    let reachabilityEmptyReasonRaw: String?
    let reachabilityProbedAt: Date?
    let reachabilityRecheckRequestedAt: Date?
    let reachabilityResultRaw: String?
    let reachabilityUnansweredAt: Date?
    let recipientsEditedByDan: Bool
    let rejectedBookingIdsRaw: String
    let relationshipCorrectedByPerformerMatch: Bool
    let reprepContactsRequested: Bool
    let reprepDraftRequested: Bool
    let reprepHandedToRun: Bool
    let reprepLastServedAt: Date?
    let runEndDate: String?
    let runNights: [String]
    let runSourceURLs: [String]
    let scoutGroupName: String?
    let scoutVenue: String?
    let sendError: String?
    let sendsTogetherOverride: Bool?
    let sentAt: Date?
    let sentBody: String?
    let sentSubject: String?
    let seriesId: String?
    let showOutcomeAt: Date?
    let showOutcomeRaw: String?
    let showSummary: String?
    let showSummaryAbsentReasonRaw: String?
    let skippedRunNights: [String]
    let sourceIds: [String]
    let sourceListingURL: String?
    let startTimesVary: Bool
    let statusRaw: String
    let survivedMergeAt: Date?
    let tier: String
    let tierAtSend: String?
    let venue: String?

    /// The stored properties no queue term reads, each with the reason it is safe not to carry. A property
    /// listed here is invisible to every term written over `ProspectFacts`, so a reason must say why no
    /// term will ever want it, not merely that none does today.
    static let notReadByQueue: [String: String] = [
        "ingestedAt": """
            Rewritten by every scout landing that touches the row, and read only by the merge paths, the \
            re-key target, the first seen backfill and the Prep export (#4106 fact 10). Carrying it would make \
            a re-land that changed nothing look like a change to every row it wrote.
            """,
        "classificationConfidence": retained("#1533"),
        "confidenceReviewedByDan": retained("#1533"),
        "draftNeedsSalutationReview": retained("#2545"),
        "draftSalutationReviewOverriddenBody": retained("#2545"),
        "jointOpeningOverride": retained("#2545"),
    ]

    /// A column kept on the model only because dropping it would be the store's first subtractive migration.
    /// Nothing reads or writes it, so a term that started to would be bringing a retired rule back.
    static func retained(_ issue: String) -> String {
        "Retained storage, read and written by nothing since \(issue), and kept on the model only because "
            + "dropping a column would be the store's first subtractive migration (see AppSchema)."
    }

    /// One live show as a value. The contacts are read through the counted, canonically ordered accessor.
    nonisolated static func extract(_ prospect: Prospect) -> RowFacts {
        RowFacts(copying: prospect)
    }
}

// The copy is ONE call to the memberwise initialiser rather than an assignment per field, so a field missing
// from it does not compile, and so no line here reads as a write of the model's own column to a guard that
// looks for one (`ConflictOpenWritersGuardTests` judges `conflictOpen =`, which this is not).
extension RowFacts {
    /// Copies every carried field from any conformer, so the one list of fields is written once and a live
    /// model, a value and a test fixture all go through the same copy.
    nonisolated init<Source: ProspectFacts>(copying source: Source) {
        self.init(persistentModelID: source.persistentModelID,
                  factContacts: source.factContacts.map(RecipientRecord.init(copying:)),
                  foldedKeys: source.foldedKeys,
                  alreadyCoveredDismissed: source.alreadyCoveredDismissed,
                  alreadyCoveredNote: source.alreadyCoveredNote,
                  arrivedLookingLike: source.arrivedLookingLike,
                  arrivedOnAPitchedNight: source.arrivedOnAPitchedNight,
                  assignedArm: source.assignedArm,
                  autoBookedFromBookingId: source.autoBookedFromBookingId,
                  autoBookingRejectedWithoutId: source.autoBookingRejectedWithoutId,
                  bookingSuggested: source.bookingSuggested,
                  bookingSuggestionDismissed: source.bookingSuggestionDismissed,
                  classificationOverriddenByDan: source.classificationOverriddenByDan,
                  conflictClearedKey: source.conflictClearedKey,
                  conflictKey: source.conflictKey,
                  conflictOpen: source.conflictOpen,
                  contactRouteAtScore: source.contactRouteAtScore,
                  contactTierAtScore: source.contactTierAtScore,
                  contradictionMarkedAt: source.contradictionMarkedAt,
                  coverage: source.coverage,
                  coverageAtSend: source.coverageAtSend,
                  discipline: source.discipline,
                  disciplineAtSend: source.disciplineAtSend,
                  disciplineGenreSourceKey: source.disciplineGenreSourceKey,
                  dismissReasonRaw: source.dismissReasonRaw,
                  dismissedAt: source.dismissedAt,
                  dismissedReplyId: source.dismissedReplyId,
                  downbeatClientId: source.downbeatClientId,
                  draftBody: source.draftBody,
                  draftEditedByDan: source.draftEditedByDan,
                  draftModel: source.draftModel,
                  draftSubject: source.draftSubject,
                  draftVariant: source.draftVariant,
                  draftWrittenByDan: source.draftWrittenByDan,
                  droppedRunNights: source.droppedRunNights,
                  excludedFromVoiceLearning: source.excludedFromVoiceLearning,
                  experimentID: source.experimentID,
                  experimentOpenerEdited: source.experimentOpenerEdited,
                  firstSeenAt: source.firstSeenAt,
                  fitReason: source.fitReason,
                  fitScore: source.fitScore,
                  fitScoreAtSend: source.fitScoreAtSend,
                  fitScoreBeforeContactCheck: source.fitScoreBeforeContactCheck,
                  followUpCount: source.followUpCount,
                  gmailMessageId: source.gmailMessageId,
                  gmailThreadId: source.gmailThreadId,
                  groupName: source.groupName,
                  groupNameOverriddenByDan: source.groupNameOverriddenByDan,
                  heldBackAt: source.heldBackAt,
                  heldBackBySlot: source.heldBackBySlot,
                  keptVisibleAfterGenreChange: source.keptVisibleAfterGenreChange,
                  lastFollowUpAt: source.lastFollowUpAt,
                  lastReplyAt: source.lastReplyAt,
                  lastReplyId: source.lastReplyId,
                  lastReplyText: source.lastReplyText,
                  location: source.location,
                  lostReason: source.lostReason,
                  matchedClientName: source.matchedClientName,
                  matchedPerformerName: source.matchedPerformerName,
                  mergeSurvivorUnseenAt: source.mergeSurvivorUnseenAt,
                  missedScoutCount: source.missedScoutCount,
                  naturalKey: source.naturalKey,
                  nightStartTimes: source.nightStartTimes,
                  orgDoNotContact: source.orgDoNotContact,
                  originalDraftBody: source.originalDraftBody,
                  originalDraftSubject: source.originalDraftSubject,
                  outcomeAt: source.outcomeAt,
                  outcomeRaw: source.outcomeRaw,
                  outcomeSourceRaw: source.outcomeSourceRaw,
                  outreachStoodDownAt: source.outreachStoodDownAt,
                  partOfRelatedRun: source.partOfRelatedRun,
                  passedOnThisShow: source.passedOnThisShow,
                  performanceDate: source.performanceDate,
                  performanceStartTimes: source.performanceStartTimes,
                  performerMatchDismissed: source.performerMatchDismissed,
                  performerMatchNote: source.performerMatchNote,
                  performerMatchPreviousDownbeatClientId: source.performerMatchPreviousDownbeatClientId,
                  performerMatchPreviousFitScore: source.performerMatchPreviousFitScore,
                  performerMatchPreviousMatchedClientName: source.performerMatchPreviousMatchedClientName,
                  performerMatchPreviousRelationship: source.performerMatchPreviousRelationship,
                  performerMatchPreviousTier: source.performerMatchPreviousTier,
                  performerMatchReviewed: source.performerMatchReviewed,
                  pitchedRunNights: source.pitchedRunNights,
                  possibleMatchName: source.possibleMatchName,
                  possibleMatchSource: source.possibleMatchSource,
                  presenter: source.presenter,
                  presenterSource: source.presenterSource,
                  presenterSourceKey: source.presenterSourceKey,
                  presenterWasTheRoom: source.presenterWasTheRoom,
                  priorRelationship: source.priorRelationship,
                  priorRelationshipAtSend: source.priorRelationshipAtSend,
                  producerAxisSourceKey: source.producerAxisSourceKey,
                  production: source.production,
                  productionAtSend: source.productionAtSend,
                  profile: source.profile,
                  profileAtSend: source.profileAtSend,
                  reachabilityEmptyReasonRaw: source.reachabilityEmptyReasonRaw,
                  reachabilityProbedAt: source.reachabilityProbedAt,
                  reachabilityRecheckRequestedAt: source.reachabilityRecheckRequestedAt,
                  reachabilityResultRaw: source.reachabilityResultRaw,
                  reachabilityUnansweredAt: source.reachabilityUnansweredAt,
                  recipientsEditedByDan: source.recipientsEditedByDan,
                  rejectedBookingIdsRaw: source.rejectedBookingIdsRaw,
                  relationshipCorrectedByPerformerMatch: source.relationshipCorrectedByPerformerMatch,
                  reprepContactsRequested: source.reprepContactsRequested,
                  reprepDraftRequested: source.reprepDraftRequested,
                  reprepHandedToRun: source.reprepHandedToRun,
                  reprepLastServedAt: source.reprepLastServedAt,
                  runEndDate: source.runEndDate,
                  runNights: source.runNights,
                  runSourceURLs: source.runSourceURLs,
                  scoutGroupName: source.scoutGroupName,
                  scoutVenue: source.scoutVenue,
                  sendError: source.sendError,
                  sendsTogetherOverride: source.sendsTogetherOverride,
                  sentAt: source.sentAt,
                  sentBody: source.sentBody,
                  sentSubject: source.sentSubject,
                  seriesId: source.seriesId,
                  showOutcomeAt: source.showOutcomeAt,
                  showOutcomeRaw: source.showOutcomeRaw,
                  showSummary: source.showSummary,
                  showSummaryAbsentReasonRaw: source.showSummaryAbsentReasonRaw,
                  skippedRunNights: source.skippedRunNights,
                  sourceIds: source.sourceIds,
                  sourceListingURL: source.sourceListingURL,
                  startTimesVary: source.startTimesVary,
                  statusRaw: source.statusRaw,
                  survivedMergeAt: source.survivedMergeAt,
                  tier: source.tier,
                  tierAtSend: source.tierAtSend,
                  venue: source.venue)
    }
}

/// One contact as a value, carried inside its show's `RowFacts`.
struct RecipientRecord: ContactFacts, Equatable, Sendable {
    let persistentModelID: PersistentIdentifier

    let attachDisplacedEmail: String?
    let attachDisplacedMessageId: String?
    let attachDisplacedThreadId: String?
    let attachPausedRecipientIds: [String]?
    let attachPriorOriginalReplyDraftBody: String?
    let attachPriorReplyDraftEditedByDan: Bool
    let attachPriorReplyDraftWrittenByDan: Bool
    let attachPriorResolutionRaw: String?
    let attachWroteAddress: Bool
    let attachedThreadSubject: String?
    let bounced: Bool
    let closingNoteStoodDownAt: Date?
    let contactConfidenceRaw: String?
    let contactFormURL: String?
    let contactMethodRaw: String?
    let contactSourceURL: String?
    let contactTierRaw: String?
    let conversationAttachedAt: Date?
    let conversationEverAttachedAt: Date?
    let conversationRemindedAt: Date?
    let delayNoticeAt: Date?
    let dismissedBounceId: String?
    let dismissedConversationIds: [String]?
    let dismissedReplyId: String?
    let email: String?
    let followUpCount: Int
    let formOutreachPriorStatusRaw: String?
    let formOutreachRecordedAt: Date?
    let formOutreachStartedAt: Date?
    let formOutreachURL: String?
    let gmailMessageId: String?
    let gmailReferences: String?
    let gmailThreadId: String?
    let greetingOverriddenBody: String?
    let heldDownReasonRaw: String?
    let heldDownToUnverified: Bool
    let heldDownToUnverifiedDismissed: Bool
    let id: String
    let inboundReplyMessageId: String?
    let inboundReplySentAt: Date?
    let intentHint: String?
    let lastBounceId: String?
    let lastDelayMessageId: String?
    let lastFollowUpAt: Date?
    let lastReplyId: String?
    let lastReplyText: String?
    let lintOverriddenBody: String?
    let looksLikeAnotherPersons: Bool
    let looksLikeAnotherPersonsDismissed: Bool
    let looksLikeDuplicateContact: Bool
    let looksLikeDuplicateContactDismissed: Bool
    let looksLikeDuplicateContactKey: String?
    let looksLikePressContact: Bool
    let looksLikePressContactDismissed: Bool
    let looksLikeVenue: Bool
    let looksLikeVenueDismissed: Bool
    let name: String?
    let nameMatchOnly: Bool
    let nameMatchOnlyDismissed: Bool
    let nudgeRemindedAt: Date?
    let nudgeSendClaimedAt: Date?
    let originalReplyDraftBody: String?
    let outcomeSourceRaw: String?
    let outreachChannelRaw: String?
    let outreachStoodDownAt: Date?
    let pausedByReply: Bool
    let pitchSubject: String?
    let promisedNightsRaw: String?
    let provenanceRaw: String
    let replied: Bool
    let repliedAt: Date?
    let replyAudience: [String]?
    let replyCandidateSearchedAt: Date?
    let replyCopiedAt: Date?
    let replyDraftBody: String?
    let replyDraftEditedByDan: Bool
    let replyDraftModel: String?
    let replyDraftReplacesDraftOnFile: Bool
    let replyDraftRequestedAt: Date?
    let replyDraftWrittenByDan: Bool
    let replyFromAddress: String?
    let replyFromName: String?
    let replyHandledAt: Date?
    let replyMarkClearedStandDown: Bool
    let replyMarkedByHandAt: Date?
    let replyProposedAt: Date?
    let replyProposedFromAddress: String?
    let replyProposedFromName: String?
    let replyProposedMessageId: String?
    let replyProposedScore: Int
    let replyProposedSentAt: Date?
    let replyProposedSubject: String?
    let replyProposedThreadId: String?
    let replySendClaimedAt: Date?
    let replySentAt: Date?
    let replyTextCheckedAt: Date?
    let replyTrackingDegraded: Bool
    let resolutionRaw: String?
    let role: String?
    let roleIsACharacterisation: Bool
    let sendClaimedAt: Date?
    let sendError: String?
    let sendGroupId: String?
    let sendStateRaw: String
    let sentAt: Date?
    let sentReplyBody: String?
    let suppressionReasonRaw: String?
    let threadingDegraded: Bool

    static let notReadByQueue: [String: String] = [
        "prospect": """
            The parent link. A record lives inside its show's `RowFacts`, so the show it belongs to is the \
            value holding it, and carrying the link would put a model inside the value.
            """,
        "overrideBody": RowFacts.retained("#3549"),
        "replyDraftSubject": RowFacts.retained("#3891"),
        "openingOverride": RowFacts.retained("#2545"),
    ]
}

extension RecipientRecord {
    nonisolated init<Source: ContactFacts>(copying source: Source) {
        self.init(persistentModelID: source.persistentModelID,
                  attachDisplacedEmail: source.attachDisplacedEmail,
                  attachDisplacedMessageId: source.attachDisplacedMessageId,
                  attachDisplacedThreadId: source.attachDisplacedThreadId,
                  attachPausedRecipientIds: source.attachPausedRecipientIds,
                  attachPriorOriginalReplyDraftBody: source.attachPriorOriginalReplyDraftBody,
                  attachPriorReplyDraftEditedByDan: source.attachPriorReplyDraftEditedByDan,
                  attachPriorReplyDraftWrittenByDan: source.attachPriorReplyDraftWrittenByDan,
                  attachPriorResolutionRaw: source.attachPriorResolutionRaw,
                  attachWroteAddress: source.attachWroteAddress,
                  attachedThreadSubject: source.attachedThreadSubject,
                  bounced: source.bounced,
                  closingNoteStoodDownAt: source.closingNoteStoodDownAt,
                  contactConfidenceRaw: source.contactConfidenceRaw,
                  contactFormURL: source.contactFormURL,
                  contactMethodRaw: source.contactMethodRaw,
                  contactSourceURL: source.contactSourceURL,
                  contactTierRaw: source.contactTierRaw,
                  conversationAttachedAt: source.conversationAttachedAt,
                  conversationEverAttachedAt: source.conversationEverAttachedAt,
                  conversationRemindedAt: source.conversationRemindedAt,
                  delayNoticeAt: source.delayNoticeAt,
                  dismissedBounceId: source.dismissedBounceId,
                  dismissedConversationIds: source.dismissedConversationIds,
                  dismissedReplyId: source.dismissedReplyId,
                  email: source.email,
                  followUpCount: source.followUpCount,
                  formOutreachPriorStatusRaw: source.formOutreachPriorStatusRaw,
                  formOutreachRecordedAt: source.formOutreachRecordedAt,
                  formOutreachStartedAt: source.formOutreachStartedAt,
                  formOutreachURL: source.formOutreachURL,
                  gmailMessageId: source.gmailMessageId,
                  gmailReferences: source.gmailReferences,
                  gmailThreadId: source.gmailThreadId,
                  greetingOverriddenBody: source.greetingOverriddenBody,
                  heldDownReasonRaw: source.heldDownReasonRaw,
                  heldDownToUnverified: source.heldDownToUnverified,
                  heldDownToUnverifiedDismissed: source.heldDownToUnverifiedDismissed,
                  id: source.id,
                  inboundReplyMessageId: source.inboundReplyMessageId,
                  inboundReplySentAt: source.inboundReplySentAt,
                  intentHint: source.intentHint,
                  lastBounceId: source.lastBounceId,
                  lastDelayMessageId: source.lastDelayMessageId,
                  lastFollowUpAt: source.lastFollowUpAt,
                  lastReplyId: source.lastReplyId,
                  lastReplyText: source.lastReplyText,
                  lintOverriddenBody: source.lintOverriddenBody,
                  looksLikeAnotherPersons: source.looksLikeAnotherPersons,
                  looksLikeAnotherPersonsDismissed: source.looksLikeAnotherPersonsDismissed,
                  looksLikeDuplicateContact: source.looksLikeDuplicateContact,
                  looksLikeDuplicateContactDismissed: source.looksLikeDuplicateContactDismissed,
                  looksLikeDuplicateContactKey: source.looksLikeDuplicateContactKey,
                  looksLikePressContact: source.looksLikePressContact,
                  looksLikePressContactDismissed: source.looksLikePressContactDismissed,
                  looksLikeVenue: source.looksLikeVenue,
                  looksLikeVenueDismissed: source.looksLikeVenueDismissed,
                  name: source.name,
                  nameMatchOnly: source.nameMatchOnly,
                  nameMatchOnlyDismissed: source.nameMatchOnlyDismissed,
                  nudgeRemindedAt: source.nudgeRemindedAt,
                  nudgeSendClaimedAt: source.nudgeSendClaimedAt,
                  originalReplyDraftBody: source.originalReplyDraftBody,
                  outcomeSourceRaw: source.outcomeSourceRaw,
                  outreachChannelRaw: source.outreachChannelRaw,
                  outreachStoodDownAt: source.outreachStoodDownAt,
                  pausedByReply: source.pausedByReply,
                  pitchSubject: source.pitchSubject,
                  promisedNightsRaw: source.promisedNightsRaw,
                  provenanceRaw: source.provenanceRaw,
                  replied: source.replied,
                  repliedAt: source.repliedAt,
                  replyAudience: source.replyAudience,
                  replyCandidateSearchedAt: source.replyCandidateSearchedAt,
                  replyCopiedAt: source.replyCopiedAt,
                  replyDraftBody: source.replyDraftBody,
                  replyDraftEditedByDan: source.replyDraftEditedByDan,
                  replyDraftModel: source.replyDraftModel,
                  replyDraftReplacesDraftOnFile: source.replyDraftReplacesDraftOnFile,
                  replyDraftRequestedAt: source.replyDraftRequestedAt,
                  replyDraftWrittenByDan: source.replyDraftWrittenByDan,
                  replyFromAddress: source.replyFromAddress,
                  replyFromName: source.replyFromName,
                  replyHandledAt: source.replyHandledAt,
                  replyMarkClearedStandDown: source.replyMarkClearedStandDown,
                  replyMarkedByHandAt: source.replyMarkedByHandAt,
                  replyProposedAt: source.replyProposedAt,
                  replyProposedFromAddress: source.replyProposedFromAddress,
                  replyProposedFromName: source.replyProposedFromName,
                  replyProposedMessageId: source.replyProposedMessageId,
                  replyProposedScore: source.replyProposedScore,
                  replyProposedSentAt: source.replyProposedSentAt,
                  replyProposedSubject: source.replyProposedSubject,
                  replyProposedThreadId: source.replyProposedThreadId,
                  replySendClaimedAt: source.replySendClaimedAt,
                  replySentAt: source.replySentAt,
                  replyTextCheckedAt: source.replyTextCheckedAt,
                  replyTrackingDegraded: source.replyTrackingDegraded,
                  resolutionRaw: source.resolutionRaw,
                  role: source.role,
                  roleIsACharacterisation: source.roleIsACharacterisation,
                  sendClaimedAt: source.sendClaimedAt,
                  sendError: source.sendError,
                  sendGroupId: source.sendGroupId,
                  sendStateRaw: source.sendStateRaw,
                  sentAt: source.sentAt,
                  sentReplyBody: source.sentReplyBody,
                  suppressionReasonRaw: source.suppressionReasonRaw,
                  threadingDegraded: source.threadingDegraded)
    }
}
