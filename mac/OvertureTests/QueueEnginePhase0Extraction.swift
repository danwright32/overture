import Foundation
import SwiftData

// #4106 Phase 0, probe 1 and probe 3: what EXTRACTING a show into values costs, measured as an upper bound.
//
// Generated from the per model field lists in `ScopeFields.swift` (every stored property of Prospect,
// Recipient and Inquiry), read by typed property access and packed into tuples, so no value is boxed into
// an existential on the way. It reads EVERY stored property, which is more than any queue term reads, so
// the time it takes is a ceiling on what a `RowFacts` extraction could cost, not an estimate of it. The
// plan's real extraction (Phase 2) carries only what a term reads.
//
// The result type is opaque on purpose: nothing reads these values, they exist so the reads are real and
// cannot be optimised away by a later build setting. Opt in probes only; nothing in the app calls this.

/// Every stored attribute of one Prospect (135 of them), typed and unboxed. Its recipients are extracted with it.
nonisolated func probeExtractProspect(_ p: Prospect) -> some Sendable {
    let c0 = (p.alreadyCoveredDismissed, p.alreadyCoveredNote, p.arrivedLookingLike, p.arrivedOnAPitchedNight, p.assignedArm, p.autoBookedFromBookingId, p.autoBookingRejectedWithoutId, p.bookingSuggested, p.bookingSuggestionDismissed, p.classificationConfidence, p.classificationOverriddenByDan, p.confidenceReviewedByDan)
    let c1 = (p.conflictClearedKey, p.conflictKey, p.conflictOpen, p.contactRouteAtScore, p.contactTierAtScore, p.contradictionMarkedAt, p.coverage, p.coverageAtSend, p.discipline, p.disciplineAtSend, p.disciplineGenreSourceKey, p.dismissReasonRaw)
    let c2 = (p.dismissedAt, p.dismissedReplyId, p.downbeatClientId, p.draftBody, p.draftEditedByDan, p.draftModel, p.draftNeedsSalutationReview, p.draftSalutationReviewOverriddenBody, p.draftSubject, p.draftVariant, p.draftWrittenByDan, p.droppedRunNights)
    let c3 = (p.excludedFromVoiceLearning, p.experimentID, p.experimentOpenerEdited, p.firstSeenAt, p.fitReason, p.fitScore, p.fitScoreAtSend, p.fitScoreBeforeContactCheck, p.followUpCount, p.gmailMessageId, p.gmailThreadId, p.groupName)
    let c4 = (p.groupNameOverriddenByDan, p.heldBackAt, p.heldBackBySlot, p.ingestedAt, p.jointOpeningOverride, p.keptVisibleAfterGenreChange, p.lastFollowUpAt, p.lastReplyAt, p.lastReplyId, p.lastReplyText, p.location, p.lostReason)
    let c5 = (p.matchedClientName, p.matchedPerformerName, p.mergeSurvivorUnseenAt, p.missedScoutCount, p.naturalKey, p.nightStartTimes, p.orgDoNotContact, p.originalDraftBody, p.originalDraftSubject, p.outcomeAt, p.outcomeRaw, p.outcomeSourceRaw)
    let c6 = (p.outreachStoodDownAt, p.partOfRelatedRun, p.passedOnThisShow, p.performanceDate, p.performanceStartTimes, p.performerMatchDismissed, p.performerMatchNote, p.performerMatchPreviousDownbeatClientId, p.performerMatchPreviousFitScore, p.performerMatchPreviousMatchedClientName, p.performerMatchPreviousRelationship, p.performerMatchPreviousTier)
    let c7 = (p.performerMatchReviewed, p.pitchedRunNights, p.possibleMatchName, p.possibleMatchSource, p.presenter, p.presenterSource, p.presenterSourceKey, p.presenterWasTheRoom, p.priorRelationship, p.priorRelationshipAtSend, p.producerAxisSourceKey, p.production)
    let c8 = (p.productionAtSend, p.profile, p.profileAtSend, p.reachabilityEmptyReasonRaw, p.reachabilityProbedAt, p.reachabilityRecheckRequestedAt, p.reachabilityResultRaw, p.reachabilityUnansweredAt, p.recipientsEditedByDan, p.rejectedBookingIdsRaw, p.relationshipCorrectedByPerformerMatch, p.reprepContactsRequested)
    let c9 = (p.reprepDraftRequested, p.reprepHandedToRun, p.reprepLastServedAt, p.runEndDate, p.runNights, p.runSourceURLs, p.scoutGroupName, p.scoutVenue, p.sendError, p.sendsTogetherOverride, p.sentAt, p.sentBody)
    let c10 = (p.sentSubject, p.seriesId, p.showOutcomeAt, p.showOutcomeRaw, p.showSummary, p.showSummaryAbsentReasonRaw, p.skippedRunNights, p.sourceIds, p.sourceListingURL, p.startTimesVary, p.statusRaw, p.survivedMergeAt)
    let c11 = (p.tier, p.tierAtSend, p.venue)
    let contacts = p.recipients.map(probeExtractRecipient)
    return (c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, contacts, p.persistentModelID)
}

/// Every stored attribute of one Recipient (111 of them), typed and unboxed.
nonisolated func probeExtractRecipient(_ r: Recipient) -> some Sendable {
    let c0 = (r.attachDisplacedEmail, r.attachDisplacedMessageId, r.attachDisplacedThreadId, r.attachPausedRecipientIds, r.attachPriorOriginalReplyDraftBody, r.attachPriorReplyDraftEditedByDan, r.attachPriorReplyDraftWrittenByDan, r.attachPriorResolutionRaw, r.attachWroteAddress, r.attachedThreadSubject, r.bounced, r.closingNoteStoodDownAt)
    let c1 = (r.contactConfidenceRaw, r.contactFormURL, r.contactMethodRaw, r.contactSourceURL, r.contactTierRaw, r.conversationAttachedAt, r.conversationEverAttachedAt, r.conversationRemindedAt, r.delayNoticeAt, r.dismissedBounceId, r.dismissedConversationIds, r.dismissedReplyId)
    let c2 = (r.email, r.followUpCount, r.formOutreachPriorStatusRaw, r.formOutreachRecordedAt, r.formOutreachStartedAt, r.formOutreachURL, r.gmailMessageId, r.gmailReferences, r.gmailThreadId, r.greetingOverriddenBody, r.heldDownReasonRaw, r.heldDownToUnverified)
    let c3 = (r.heldDownToUnverifiedDismissed, r.id, r.inboundReplyMessageId, r.inboundReplySentAt, r.intentHint, r.lastBounceId, r.lastDelayMessageId, r.lastFollowUpAt, r.lastReplyId, r.lastReplyText, r.lintOverriddenBody, r.looksLikeAnotherPersons)
    let c4 = (r.looksLikeAnotherPersonsDismissed, r.looksLikeDuplicateContact, r.looksLikeDuplicateContactDismissed, r.looksLikeDuplicateContactKey, r.looksLikePressContact, r.looksLikePressContactDismissed, r.looksLikeVenue, r.looksLikeVenueDismissed, r.name, r.nameMatchOnly, r.nameMatchOnlyDismissed, r.nudgeRemindedAt)
    let c5 = (r.nudgeSendClaimedAt, r.openingOverride, r.originalReplyDraftBody, r.outcomeSourceRaw, r.outreachChannelRaw, r.outreachStoodDownAt, r.overrideBody, r.pausedByReply, r.pitchSubject, r.promisedNightsRaw, r.provenanceRaw, r.replied)
    let c6 = (r.repliedAt, r.replyAudience, r.replyCandidateSearchedAt, r.replyCopiedAt, r.replyDraftBody, r.replyDraftEditedByDan, r.replyDraftModel, r.replyDraftReplacesDraftOnFile, r.replyDraftRequestedAt, r.replyDraftSubject, r.replyDraftWrittenByDan, r.replyFromAddress)
    let c7 = (r.replyFromName, r.replyHandledAt, r.replyMarkClearedStandDown, r.replyMarkedByHandAt, r.replyProposedAt, r.replyProposedFromAddress, r.replyProposedFromName, r.replyProposedMessageId, r.replyProposedScore, r.replyProposedSentAt, r.replyProposedSubject, r.replyProposedThreadId)
    let c8 = (r.replySendClaimedAt, r.replySentAt, r.replyTextCheckedAt, r.replyTrackingDegraded, r.resolutionRaw, r.role, r.roleIsACharacterisation, r.sendClaimedAt, r.sendError, r.sendGroupId, r.sendStateRaw, r.sentAt)
    let c9 = (r.sentReplyBody, r.suppressionReasonRaw, r.threadingDegraded)
    return (c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, r.persistentModelID)
}

/// Every stored attribute of one Inquiry (48 of them), typed and unboxed.
nonisolated func probeExtractInquiry(_ i: Inquiry) -> some Sendable {
    let c0 = (i.attachWroteSentAt, i.autoBookingRejectedWithoutId, i.bookingSuggested, i.bookingSuggestionDismissed, i.bounced, i.conversationAttachedAt, i.conversationSubject, i.createdAt, i.delayNoticeAt, i.dismissedBounceId, i.dismissedReplyId, i.downbeatClientId)
    let c1 = (i.eventName, i.gmailMessageId, i.gmailReferences, i.gmailThreadId, i.inboundReplyMessageId, i.inboundReplySentAt, i.inquirerEmail, i.inquirerName, i.lastBounceId, i.lastDelayMessageId, i.lastReplyId, i.lastReplyText)
    let c2 = (i.lostReasonRaw, i.notes, i.outcomeAt, i.outcomeRaw, i.outcomeSourceRaw, i.performanceDate, i.rejectedBookingIdsRaw, i.replied, i.repliedAt, i.replyAudience, i.replyCandidateSearchedAt, i.replyFromAddress)
    let c3 = (i.replyFromName, i.replyHandledAt, i.replyTextCheckedAt, i.runEndDate, i.sendError, i.sentAt, i.showOutcomeAt, i.showOutcomeRaw, i.sourceRaw, i.threadIdDegraded, i.threadingDegraded, i.venue)
    return (c0, c1, c2, c3, i.persistentModelID)
}
