import Foundation
import SwiftData

// #4252: every stored property of every model, as `ScopeMemo` compares it. See `ScopeValues.swift`.
//
// One line per property, in the schema's own spelling. `ScopeFieldsMatchTheSchemaTests` derives the
// expected list from `AppSchema.schema` and fails on any property missing here or named here that the
// schema does not hold, so a property added to a model cannot quietly go uncompared (L41, L96).

extension AllowedSeedTown: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<AllowedSeedTown, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<AllowedSeedTown>] = [
        .init(\.addedAt),
        .init(\.town),
    ]
}

extension CancelledShoot: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<CancelledShoot, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<CancelledShoot>] = [
        .init(\.bookingId),
        .init(\.cancelledAt),
        .init(\.shootName),
        .init(\.startDate),
    ]
}

extension DayOff: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<DayOff, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<DayOff>] = [
        .init(\.createdAt),
        .init(\.endDate),
        .init(\.note),
        .init(\.startDate),
    ]
}

extension DemotedHouse: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<DemotedHouse, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<DemotedHouse>] = [
        .init(\.addedAt),
        .init(\.orgKey),
    ]
}

extension DismissedCoverageClient: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<DismissedCoverageClient, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<DismissedCoverageClient>] = [
        .init(\.clientId),
        .init(\.dismissedAt),
    ]
}

extension ExcludedTown: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<ExcludedTown, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<ExcludedTown>] = [
        .init(\.addedAt),
        .init(\.town),
    ]
}

extension Experiment: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<Experiment, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<Experiment>] = [
        .init(\.dimensionRaw),
        .init(\.endedAt),
        .init(\.experimentId),
        .init(\.isActive),
        .init(\.label),
        .init(\.startedAt),
        .init(\.variantA),
        .init(\.variantB),
    ]
}

extension GenreCorrection: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<GenreCorrection, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<GenreCorrection>] = [
        .init(\.classifierRead),
        .init(\.correctedAt),
        .init(\.danSaid),
        .init(\.id),
        .init(\.presenter),
        .init(\.title),
        .init(\.venue),
    ]
}

extension Inquiry: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<Inquiry, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<Inquiry>] = [
        .init(\.attachWroteSentAt),
        .init(\.autoBookingRejectedWithoutId),
        .init(\.bookingSuggested),
        .init(\.bookingSuggestionDismissed),
        .init(\.bounced),
        .init(\.conversationAttachedAt),
        .init(\.conversationSubject),
        .init(\.createdAt),
        .init(\.delayNoticeAt),
        .init(\.dismissedBounceId),
        .init(\.dismissedReplyId),
        .init(\.downbeatClientId),
        .init(\.eventName),
        .init(\.gmailMessageId),
        .init(\.gmailReferences),
        .init(\.gmailThreadId),
        .init(\.inboundReplyMessageId),
        .init(\.inboundReplySentAt),
        .init(\.inquirerEmail),
        .init(\.inquirerName),
        .init(\.lastBounceId),
        .init(\.lastDelayMessageId),
        .init(\.lastReplyId),
        .init(\.lastReplyText),
        .init(\.lostReasonRaw),
        .init(\.notes),
        .init(\.outcomeAt),
        .init(\.outcomeRaw),
        .init(\.outcomeSourceRaw),
        .init(\.performanceDate),
        .init(\.rejectedBookingIdsRaw),
        .init(\.replied),
        .init(\.repliedAt),
        .init(\.replyAudience),
        .init(\.replyCandidateSearchedAt),
        .init(\.replyFromAddress),
        .init(\.replyFromName),
        .init(\.replyHandledAt),
        .init(\.replyTextCheckedAt),
        .init(\.runEndDate),
        .init(\.sendError),
        .init(\.sentAt),
        .init(\.showOutcomeAt),
        .init(\.showOutcomeRaw),
        .init(\.sourceRaw),
        .init(\.threadIdDegraded),
        .init(\.threadingDegraded),
        .init(\.venue),
    ]
}

extension OrgReachabilityAnswer: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<OrgReachabilityAnswer, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<OrgReachabilityAnswer>] = [
        .init(\.foundEmailsRaw),
        .init(\.orgKey),
        .init(\.presenterName),
        .init(\.probedAt),
        .init(\.resultRaw),
        .init(\.sourceGroupName),
        .init(\.sourceNaturalKey),
    ]
}

extension PromotedProducer: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<PromotedProducer, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<PromotedProducer>] = [
        .init(\.addedAt),
        .init(\.orgKey),
    ]
}

extension Prospect: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<Prospect, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<Prospect>] = [
        .init(\.alreadyCoveredDismissed),
        .init(\.alreadyCoveredNote),
        .init(\.arrivedLookingLike),
        .init(\.arrivedOnAPitchedNight),
        .init(\.assignedArm),
        .init(\.autoBookedFromBookingId),
        .init(\.autoBookingRejectedWithoutId),
        .init(\.bookingSuggested),
        .init(\.bookingSuggestionDismissed),
        .init(\.classificationConfidence),
        .init(\.classificationOverriddenByDan),
        .init(\.confidenceReviewedByDan),
        .init(\.conflictClearedKey),
        .init(\.conflictKey),
        .init(\.conflictOpen),
        .init(\.contactRouteAtScore),
        .init(\.contactTierAtScore),
        .init(\.contradictionMarkedAt),
        .init(\.coverage),
        .init(\.coverageAtSend),
        .init(\.discipline),
        .init(\.disciplineAtSend),
        .init(\.disciplineGenreSourceKey),
        .init(\.dismissReasonRaw),
        .init(\.dismissedAt),
        .init(\.dismissedReplyId),
        .init(\.downbeatClientId),
        .init(\.draftBody),
        .init(\.draftEditedByDan),
        .init(\.draftModel),
        .init(\.draftNeedsSalutationReview),
        .init(\.draftSalutationReviewOverriddenBody),
        .init(\.draftSubject),
        .init(\.draftVariant),
        .init(\.draftWrittenByDan),
        .init(\.droppedRunNights),
        .init(\.excludedFromVoiceLearning),
        .init(\.experimentID),
        .init(\.experimentOpenerEdited),
        .init(\.firstSeenAt),
        .init(\.fitReason),
        .init(\.fitScore),
        .init(\.fitScoreAtSend),
        .init(\.fitScoreBeforeContactCheck),
        .init(\.followUpCount),
        .init(\.gmailMessageId),
        .init(\.gmailThreadId),
        .init(\.groupName),
        .init(\.groupNameOverriddenByDan),
        .init(\.heldBackAt),
        .init(\.heldBackBySlot),
        .init(\.ingestedAt),
        .init(\.jointOpeningOverride),
        .init(\.keptVisibleAfterGenreChange),
        .init(\.lastFollowUpAt),
        .init(\.lastReplyAt),
        .init(\.lastReplyId),
        .init(\.lastReplyText),
        .init(\.location),
        .init(\.lostReason),
        .init(\.matchedClientName),
        .init(\.matchedPerformerName),
        .init(\.mergeSurvivorUnseenAt),
        .init(\.missedScoutCount),
        .init(\.naturalKey),
        .init(\.nightStartTimes),
        .init(\.orgDoNotContact),
        .init(\.originalDraftBody),
        .init(\.originalDraftSubject),
        .init(\.outcomeAt),
        .init(\.outcomeRaw),
        .init(\.outcomeSourceRaw),
        .init(\.outreachStoodDownAt),
        .init(\.partOfRelatedRun),
        .init(\.passedOnThisShow),
        .init(\.performanceDate),
        .init(\.performanceStartTimes),
        .init(\.performerMatchDismissed),
        .init(\.performerMatchNote),
        .init(\.performerMatchPreviousDownbeatClientId),
        .init(\.performerMatchPreviousFitScore),
        .init(\.performerMatchPreviousMatchedClientName),
        .init(\.performerMatchPreviousRelationship),
        .init(\.performerMatchPreviousTier),
        .init(\.performerMatchReviewed),
        .init(\.pitchedRunNights),
        .init(\.possibleMatchName),
        .init(\.possibleMatchSource),
        .init(\.presenter),
        .init(\.presenterSource),
        .init(\.presenterSourceKey),
        .init(\.presenterWasTheRoom),
        .init(\.priorRelationship),
        .init(\.priorRelationshipAtSend),
        .init(\.producerAxisSourceKey),
        .init(\.production),
        .init(\.productionAtSend),
        .init(\.profile),
        .init(\.profileAtSend),
        .init(\.reachabilityEmptyReasonRaw),
        .init(\.reachabilityProbedAt),
        .init(\.reachabilityRecheckRequestedAt),
        .init(\.reachabilityResultRaw),
        .init(\.reachabilityUnansweredAt),
        .init(toMany: \.recipients),
        .init(\.recipientsEditedByDan),
        .init(\.rejectedBookingIdsRaw),
        .init(\.relationshipCorrectedByPerformerMatch),
        .init(\.reprepContactsRequested),
        .init(\.reprepDraftRequested),
        .init(\.reprepHandedToRun),
        .init(\.reprepLastServedAt),
        .init(\.runEndDate),
        .init(\.runNights),
        .init(\.runSourceURLs),
        .init(\.scoutGroupName),
        .init(\.scoutVenue),
        .init(\.sendError),
        .init(\.sendsTogetherOverride),
        .init(\.sentAt),
        .init(\.sentBody),
        .init(\.sentSubject),
        .init(\.seriesId),
        .init(\.showOutcomeAt),
        .init(\.showOutcomeRaw),
        .init(\.showSummary),
        .init(\.showSummaryAbsentReasonRaw),
        .init(\.skippedRunNights),
        .init(\.sourceIds),
        .init(\.sourceListingURL),
        .init(\.startTimesVary),
        .init(\.statusRaw),
        .init(\.survivedMergeAt),
        .init(\.tier),
        .init(\.tierAtSend),
        .init(\.venue),
    ]
}

extension Recipient: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<Recipient, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<Recipient>] = [
        .init(\.attachDisplacedEmail),
        .init(\.attachDisplacedMessageId),
        .init(\.attachDisplacedThreadId),
        .init(\.attachPausedRecipientIds),
        .init(\.attachPriorOriginalReplyDraftBody),
        .init(\.attachPriorReplyDraftEditedByDan),
        .init(\.attachPriorReplyDraftWrittenByDan),
        .init(\.attachPriorResolutionRaw),
        .init(\.attachWroteAddress),
        .init(\.attachedThreadSubject),
        .init(\.bounced),
        .init(\.closingNoteStoodDownAt),
        .init(\.contactConfidenceRaw),
        .init(\.contactFormURL),
        .init(\.contactMethodRaw),
        .init(\.contactSourceURL),
        .init(\.contactTierRaw),
        .init(\.conversationAttachedAt),
        .init(\.conversationEverAttachedAt),
        .init(\.conversationRemindedAt),
        .init(\.delayNoticeAt),
        .init(\.dismissedBounceId),
        .init(\.dismissedConversationIds),
        .init(\.dismissedReplyId),
        .init(\.email),
        .init(\.followUpCount),
        .init(\.formOutreachPriorStatusRaw),
        .init(\.formOutreachRecordedAt),
        .init(\.formOutreachStartedAt),
        .init(\.formOutreachURL),
        .init(\.gmailMessageId),
        .init(\.gmailReferences),
        .init(\.gmailThreadId),
        .init(\.greetingOverriddenBody),
        .init(\.heldDownReasonRaw),
        .init(\.heldDownToUnverified),
        .init(\.heldDownToUnverifiedDismissed),
        .init(\.id),
        .init(\.inboundReplyMessageId),
        .init(\.inboundReplySentAt),
        .init(\.intentHint),
        .init(\.lastBounceId),
        .init(\.lastDelayMessageId),
        .init(\.lastFollowUpAt),
        .init(\.lastReplyId),
        .init(\.lastReplyText),
        .init(\.lintOverriddenBody),
        .init(\.looksLikeAnotherPersons),
        .init(\.looksLikeAnotherPersonsDismissed),
        .init(\.looksLikeDuplicateContact),
        .init(\.looksLikeDuplicateContactDismissed),
        .init(\.looksLikeDuplicateContactKey),
        .init(\.looksLikePressContact),
        .init(\.looksLikePressContactDismissed),
        .init(\.looksLikeVenue),
        .init(\.looksLikeVenueDismissed),
        .init(\.name),
        .init(\.nameMatchOnly),
        .init(\.nameMatchOnlyDismissed),
        .init(\.nudgeRemindedAt),
        .init(\.nudgeSendClaimedAt),
        .init(\.openingOverride),
        .init(\.originalReplyDraftBody),
        .init(\.outcomeSourceRaw),
        .init(\.outreachChannelRaw),
        .init(\.outreachStoodDownAt),
        .init(\.overrideBody),
        .init(\.pausedByReply),
        .init(\.pitchSubject),
        .init(\.promisedNightsRaw),
        .init(toOne: \.prospect),
        .init(\.provenanceRaw),
        .init(\.replied),
        .init(\.repliedAt),
        .init(\.replyAudience),
        .init(\.replyCandidateSearchedAt),
        .init(\.replyCopiedAt),
        .init(\.replyDraftBody),
        .init(\.replyDraftEditedByDan),
        .init(\.replyDraftModel),
        .init(\.replyDraftReplacesDraftOnFile),
        .init(\.replyDraftRequestedAt),
        .init(\.replyDraftSubject),
        .init(\.replyDraftWrittenByDan),
        .init(\.replyFromAddress),
        .init(\.replyFromName),
        .init(\.replyHandledAt),
        .init(\.replyMarkClearedStandDown),
        .init(\.replyMarkedByHandAt),
        .init(\.replyProposedAt),
        .init(\.replyProposedFromAddress),
        .init(\.replyProposedFromName),
        .init(\.replyProposedMessageId),
        .init(\.replyProposedScore),
        .init(\.replyProposedSentAt),
        .init(\.replyProposedSubject),
        .init(\.replyProposedThreadId),
        .init(\.replySendClaimedAt),
        .init(\.replySentAt),
        .init(\.replyTextCheckedAt),
        .init(\.replyTrackingDegraded),
        .init(\.resolutionRaw),
        .init(\.role),
        .init(\.roleIsACharacterisation),
        .init(\.sendClaimedAt),
        .init(\.sendError),
        .init(\.sendGroupId),
        .init(\.sendStateRaw),
        .init(\.sentAt),
        .init(\.sentReplyBody),
        .init(\.suppressionReasonRaw),
        .init(\.threadingDegraded),
    ]
}

extension RefusedContactAddress: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<RefusedContactAddress, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<RefusedContactAddress>] = [
        .init(\.handleKey),
        .init(\.id),
        .init(\.refusedAt),
        .init(\.scopeId),
        .init(\.scopeRaw),
    ]
}

extension VenuePlaceAnswer: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<VenuePlaceAnswer, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<VenuePlaceAnswer>] = [
        .init(\.answeredAt),
        .init(\.location),
        .init(\.venueKey),
        .init(\.venueName),
    ]
}

extension WatchedSource: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<WatchedSource, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<WatchedSource>] = [
        .init(\.addedAt),
        .init(\.baselineFeedCount),
        .init(\.clientTagClientId),
        .init(\.clientTagOverride),
        .init(\.confirmedEmptyHash),
        .init(\.degradedStreak),
        .init(\.emptyStreak),
        .init(\.failedReadStreak),
        .init(\.hadPlacedBeforeLastRun),
        .init(\.hasUnreadChanges),
        .init(\.healthRaw),
        .init(\.inactiveReasonRaw),
        .init(\.isActive),
        .init(\.kindRaw),
        .init(\.lastCheckedAt),
        .init(\.lastContentHash),
        .init(\.lastDegradedCount),
        .init(\.lastDroppedShowLabelsRaw),
        .init(\.lastErrorRaw),
        .init(\.lastFetchWasInsecure),
        .init(\.lastManualReadAt),
        .init(\.lastNonEmptyAt),
        .init(\.lastObservedContentHash),
        .init(\.lastPlacedCount),
        .init(\.lastReadableCount),
        .init(\.lastStructuralGapCount),
        .init(\.lastSucceededAt),
        .init(\.lastUnreadableCount),
        .init(\.lastUnreadableTitleCount),
        .init(\.listingsURL),
        .init(\.mergeSameDateVenue),
        .init(\.notes),
        .init(\.orgName),
        .init(\.pageCount),
        .init(\.pendingContentHash),
        .init(\.pendingPageMonthsRaw),
        .init(\.sourceId),
        .init(\.successfulCheckCount),
        .init(\.ticketingFeedURL),
        .init(\.venueLocation),
        .init(\.venueName),
    ]
}

extension WeeklyDayOff: ScopeCompared {
    func scopeAccess<V>(_ keyPath: KeyPath<WeeklyDayOff, V>) { access(keyPath: keyPath) }
    static let scopeFields: [ScopeField<WeeklyDayOff>] = [
        .init(\.createdAt),
        .init(\.firstDate),
        .init(\.freedDates),
        .init(\.lastDate),
        .init(\.note),
        .init(\.weekday),
    ]
}
