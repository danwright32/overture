import Foundation
import SwiftData

// #4356 (plan v7 Phase 2, discussion #4267 section 12 item 11): the facts a queue term may read about one
// show and its contacts, as two PROTOCOLS that the live models and the retained values both conform to.
//
// WHY PROTOCOLS, and why both sides conform. Phase 3 rewrites every queue term ONCE, as generic code over
// `some ProspectFacts`, so the app's hot path can run it over retained `RowFacts` while actions, Archive
// and the in-app card check keep running the very same code over live `Prospect` models. Two copies of a
// rule, one over models and one over values, would drift (L263, L370); one generic copy cannot.
//
// WHAT IS LISTED. Every stored property of `Prospect` and of `Recipient`, by its own name and type, except
// the few `RowFacts.notReadByQueue` and `RecipientRecord.notReadByQueue` exempt with a written reason. The
// default is to CARRY, because the two possible mistakes are not alike: a carried field no term reads
// costs an equality check, while an exempted field some term DOES read is a retained row that never goes
// stale when it should (L40). `RowFactsSchemaCoverageTests` holds the lists to `AppSchema.schema` in both
// directions, so a property added to a model is a red test until somebody decides which side it is on.
//
// NOTHING HERE CHANGES WHAT THE APP SHOWS. Phase 3 (#4357) ports the terms onto these protocols slice by
// slice, and the inventory comment on that issue lists which terms read them and which still read models.

/// One show's facts: every stored `Prospect` property a queue term may read, its contacts in their one
/// canonical order, and the keys every cross-row term folds from it, worked out once.
///
/// `SendableMetatype` (#4357 slice D2): a generic term over these protocols hands `Row.init` and friends to
/// closures, which captures the conformer's metatype; without this the compiler warns on every such site
/// (`capture of non-Sendable type '(some ProspectFacts).Type'`). Every conformer is a nonisolated type, so
/// its metatype is already sendable and the requirement costs nothing. `ContactFacts` and
/// `QueueScopeFacts` carry it for the same reason.
protocol ProspectFacts: SendableMetatype {
    associatedtype Contact: ContactFacts

    /// The row's permanent identity. Every retained index is keyed by it, never by `naturalKey` (merges
    /// and re-keys reassign that) and never by `Recipient.id` (a shared email).
    var persistentModelID: PersistentIdentifier { get }
    /// The show's contacts in ONE order, `Recipient.id` then the store's identifier (#4352), so a row
    /// read twice reads the same list however the relationship hands it back.
    var factContacts: [Contact] { get }
    /// The keys the cross-row terms fold from this row (plan v7 section 4), worked out once.
    var foldedKeys: RowKeys { get }

    var alreadyCoveredDismissed: Bool { get }
    var alreadyCoveredNote: String? { get }
    var arrivedLookingLike: String? { get }
    var arrivedOnAPitchedNight: String? { get }
    var assignedArm: String? { get }
    var autoBookedFromBookingId: String? { get }
    var autoBookingRejectedWithoutId: Bool { get }
    var bookingSuggested: Bool { get }
    var bookingSuggestionDismissed: Bool { get }
    var classificationOverriddenByDan: Bool { get }
    var conflictClearedKey: String? { get }
    var conflictKey: String? { get }
    var conflictOpen: Bool { get }
    var contactRouteAtScore: String? { get }
    var contactTierAtScore: String? { get }
    var contradictionMarkedAt: Date? { get }
    var coverage: String { get }
    var coverageAtSend: String? { get }
    var discipline: String { get }
    var disciplineAtSend: String? { get }
    var disciplineGenreSourceKey: String? { get }
    var dismissReasonRaw: String? { get }
    var dismissedAt: Date? { get }
    var dismissedReplyId: String? { get }
    var downbeatClientId: String? { get }
    var draftBody: String? { get }
    var draftEditedByDan: Bool { get }
    var draftModel: String? { get }
    var draftSubject: String? { get }
    var draftVariant: String? { get }
    var draftWrittenByDan: Bool { get }
    var droppedRunNights: [String] { get }
    var excludedFromVoiceLearning: Bool { get }
    var experimentID: String? { get }
    var experimentOpenerEdited: Bool { get }
    var firstSeenAt: Date? { get }
    var fitReason: String { get }
    var fitScore: Int { get }
    var fitScoreAtSend: Int? { get }
    var fitScoreBeforeContactCheck: Int? { get }
    var followUpCount: Int { get }
    var gmailMessageId: String? { get }
    var gmailThreadId: String? { get }
    var groupName: String { get }
    var groupNameOverriddenByDan: Bool { get }
    var heldBackAt: Date? { get }
    var heldBackBySlot: String? { get }
    var keptVisibleAfterGenreChange: Bool { get }
    var lastFollowUpAt: Date? { get }
    var lastReplyAt: Date? { get }
    var lastReplyId: String? { get }
    var lastReplyText: String? { get }
    var location: String? { get }
    var lostReason: String? { get }
    var matchedClientName: String? { get }
    var matchedPerformerName: String? { get }
    var mergeSurvivorUnseenAt: Date? { get }
    var missedScoutCount: Int { get }
    var naturalKey: String { get }
    var nightStartTimes: [String] { get }
    var orgDoNotContact: Bool { get }
    var originalDraftBody: String? { get }
    var originalDraftSubject: String? { get }
    var outcomeAt: Date? { get }
    var outcomeRaw: String { get }
    var outcomeSourceRaw: String? { get }
    var outreachStoodDownAt: Date? { get }
    var partOfRelatedRun: Bool { get }
    var passedOnThisShow: Bool { get }
    var performanceDate: String? { get }
    var performanceStartTimes: [String] { get }
    var performerMatchDismissed: Bool { get }
    var performerMatchNote: String? { get }
    var performerMatchPreviousDownbeatClientId: String? { get }
    var performerMatchPreviousFitScore: Int? { get }
    var performerMatchPreviousMatchedClientName: String? { get }
    var performerMatchPreviousRelationship: String? { get }
    var performerMatchPreviousTier: String? { get }
    var performerMatchReviewed: Bool { get }
    var pitchedRunNights: [String] { get }
    var possibleMatchName: String? { get }
    var possibleMatchSource: String? { get }
    var presenter: String? { get }
    var presenterSource: String? { get }
    var presenterSourceKey: String? { get }
    var presenterWasTheRoom: Bool? { get }
    var priorRelationship: String { get }
    var priorRelationshipAtSend: String? { get }
    var producerAxisSourceKey: String? { get }
    var production: String { get }
    var productionAtSend: String? { get }
    var profile: String { get }
    var profileAtSend: String? { get }
    var reachabilityEmptyReasonRaw: String? { get }
    var reachabilityProbedAt: Date? { get }
    var reachabilityRecheckRequestedAt: Date? { get }
    var reachabilityResultRaw: String? { get }
    var reachabilityUnansweredAt: Date? { get }
    var recipientsEditedByDan: Bool { get }
    var rejectedBookingIdsRaw: String { get }
    var relationshipCorrectedByPerformerMatch: Bool { get }
    var reprepContactsRequested: Bool { get }
    var reprepDraftRequested: Bool { get }
    var reprepHandedToRun: Bool { get }
    var reprepLastServedAt: Date? { get }
    var runEndDate: String? { get }
    var runNights: [String] { get }
    var runSourceURLs: [String] { get }
    var scoutGroupName: String? { get }
    var scoutVenue: String? { get }
    var sendError: String? { get }
    var sendsTogetherOverride: Bool? { get }
    var sentAt: Date? { get }
    var sentBody: String? { get }
    var sentSubject: String? { get }
    var seriesId: String? { get }
    var showOutcomeAt: Date? { get }
    var showOutcomeRaw: String? { get }
    var showSummary: String? { get }
    var showSummaryAbsentReasonRaw: String? { get }
    var skippedRunNights: [String] { get }
    var sourceIds: [String] { get }
    var sourceListingURL: String? { get }
    var startTimesVary: Bool { get }
    var statusRaw: String { get }
    var survivedMergeAt: Date? { get }
    var tier: String { get }
    var tierAtSend: String? { get }
    var venue: String? { get }
}

/// One contact's facts: every stored `Recipient` property a queue term may read.
protocol ContactFacts: ReplyArrivalFacts, SendableMetatype {
    var persistentModelID: PersistentIdentifier { get }

    var attachDisplacedEmail: String? { get }
    var attachDisplacedMessageId: String? { get }
    var attachDisplacedThreadId: String? { get }
    var attachPausedRecipientIds: [String]? { get }
    var attachPriorOriginalReplyDraftBody: String? { get }
    var attachPriorReplyDraftEditedByDan: Bool { get }
    var attachPriorReplyDraftWrittenByDan: Bool { get }
    var attachPriorResolutionRaw: String? { get }
    var attachWroteAddress: Bool { get }
    var attachedThreadSubject: String? { get }
    var bounced: Bool { get }
    var closingNoteStoodDownAt: Date? { get }
    var contactConfidenceRaw: String? { get }
    var contactFormURL: String? { get }
    var contactMethodRaw: String? { get }
    var contactSourceURL: String? { get }
    var contactTierRaw: String? { get }
    var conversationAttachedAt: Date? { get }
    var conversationEverAttachedAt: Date? { get }
    var conversationRemindedAt: Date? { get }
    var delayNoticeAt: Date? { get }
    var dismissedBounceId: String? { get }
    var dismissedConversationIds: [String]? { get }
    var dismissedReplyId: String? { get }
    var email: String? { get }
    var followUpCount: Int { get }
    var formOutreachPriorStatusRaw: String? { get }
    var formOutreachRecordedAt: Date? { get }
    var formOutreachStartedAt: Date? { get }
    var formOutreachURL: String? { get }
    var gmailMessageId: String? { get }
    var gmailReferences: String? { get }
    var gmailThreadId: String? { get }
    var greetingOverriddenBody: String? { get }
    var heldDownReasonRaw: String? { get }
    var heldDownToUnverified: Bool { get }
    var heldDownToUnverifiedDismissed: Bool { get }
    var id: String { get }
    var inboundReplyMessageId: String? { get }
    var inboundReplySentAt: Date? { get }
    var intentHint: String? { get }
    var lastBounceId: String? { get }
    var lastDelayMessageId: String? { get }
    var lastFollowUpAt: Date? { get }
    var lastReplyId: String? { get }
    var lastReplyText: String? { get }
    var lintOverriddenBody: String? { get }
    var looksLikeAnotherPersons: Bool { get }
    var looksLikeAnotherPersonsDismissed: Bool { get }
    var looksLikeDuplicateContact: Bool { get }
    var looksLikeDuplicateContactDismissed: Bool { get }
    var looksLikeDuplicateContactKey: String? { get }
    var looksLikePressContact: Bool { get }
    var looksLikePressContactDismissed: Bool { get }
    var looksLikeVenue: Bool { get }
    var looksLikeVenueDismissed: Bool { get }
    var name: String? { get }
    var nameMatchOnly: Bool { get }
    var nameMatchOnlyDismissed: Bool { get }
    var nudgeRemindedAt: Date? { get }
    var nudgeSendClaimedAt: Date? { get }
    var originalReplyDraftBody: String? { get }
    var outcomeSourceRaw: String? { get }
    var outreachChannelRaw: String? { get }
    var outreachStoodDownAt: Date? { get }
    var pausedByReply: Bool { get }
    var pitchSubject: String? { get }
    var promisedNightsRaw: String? { get }
    var provenanceRaw: String { get }
    var replied: Bool { get }
    var repliedAt: Date? { get }
    var replyAudience: [String]? { get }
    var replyCandidateSearchedAt: Date? { get }
    var replyCopiedAt: Date? { get }
    var replyDraftBody: String? { get }
    var replyDraftEditedByDan: Bool { get }
    var replyDraftModel: String? { get }
    var replyDraftReplacesDraftOnFile: Bool { get }
    var replyDraftRequestedAt: Date? { get }
    var replyDraftWrittenByDan: Bool { get }
    var replyFromAddress: String? { get }
    var replyFromName: String? { get }
    var replyHandledAt: Date? { get }
    var replyMarkClearedStandDown: Bool { get }
    var replyMarkedByHandAt: Date? { get }
    var replyProposedAt: Date? { get }
    var replyProposedFromAddress: String? { get }
    var replyProposedFromName: String? { get }
    var replyProposedMessageId: String? { get }
    var replyProposedScore: Int { get }
    var replyProposedSentAt: Date? { get }
    var replyProposedSubject: String? { get }
    var replyProposedThreadId: String? { get }
    var replySendClaimedAt: Date? { get }
    var replySentAt: Date? { get }
    var replyTextCheckedAt: Date? { get }
    var replyTrackingDegraded: Bool { get }
    var resolutionRaw: String? { get }
    var role: String? { get }
    var roleIsACharacterisation: Bool { get }
    var sendClaimedAt: Date? { get }
    var sendError: String? { get }
    var sendGroupId: String? { get }
    var sendStateRaw: String { get }
    var sentAt: Date? { get }
    var sentReplyBody: String? { get }
    var suppressionReasonRaw: String? { get }
    var threadingDegraded: Bool { get }
}

/// The keys the cross-row terms fold from one row, worked out ONCE (plan v7 section 4: "pre-folded once in
/// `extract()`"). Each is the term's own fold over the term's own choice of input field, called through the
/// term rather than restated, so a retained key and the term's live answer cannot disagree about how a
/// name folds (L370). `RowKeysMatchTheTermsTests` holds each one to the slice the term builds today.
struct RowKeys: Equatable, Sendable {
    /// T1 ShowLink: the bucket a row joins, from the SCOUT-ANCHORED title and venue (`ShowLink.Row`).
    let showLinkTitle: String
    let showLinkVenue: String
    /// T1 ShowLink: the nights a row occupies, kept and dropped, else its span.
    let showLinkNights: Set<String>
    /// T1 ShowLink: the production tokens in the row's listing and run URLs.
    let productionTokens: Set<String>
    /// The nights Dan dropped, decoded once from their self-describing entries (`DroppedNight`).
    let droppedNights: [String]
    /// T6 EngagementLink: the title fold its cross-venue clusters are bucketed by.
    let engagementTitle: String
    /// T4 and T5: the presenter and venue as the producer gate folds them, and the presenter's org key.
    let presenterKey: String?
    let venueKey: String?
    let orgKey: String?
    /// T2 ContradictedCancellation: the room a flagged row is judged within (`""` for no venue).
    let contradictionRoom: String
    /// T3 feed breaks: the room a flagged row is bucketed by.
    let feedBreakRoom: String

    nonisolated init(of row: some ProspectFacts) {
        let link = ShowLink.Row(row)
        showLinkTitle = ShowLink.foldedTitle(link.groupName)
        showLinkVenue = ShowLink.foldedVenue(link.venue)
        showLinkNights = ShowLink.nights(of: link)
        productionTokens = Set(link.sourceURLs.compactMap(ProductionToken.inURL))
        droppedNights = link.droppedNights
        engagementTitle = GroupNameMatch.normalize(EngagementLink.Row(row).groupName)
        presenterKey = ProducerGate.key(row.presenter)
        venueKey = ProducerGate.key(row.venue)
        orgKey = OrgKey.stored(for: row.presenter)
        contradictionRoom = ContradictedCancellation.canonicalVenue(row.venue)
        feedBreakRoom = FeedBreakEvent.canonicalVenue(row.venue)
    }
}

// The live models conform by being what they are: every requirement above is one of their own stored
// properties, so the conformance adds no storage and no second definition of any field.
extension Prospect: ProspectFacts {
    /// Through `countedRecipients`, the one accessor that counts a reach and sorts canonically, so a generic
    /// term reading a model's contacts is measured exactly as the pass's own read is (#3653, #4352).
    var factContacts: [Recipient] { countedRecipients }
    /// Folded on every read, which is the cost a retained `RowFacts` exists to avoid paying twice.
    var foldedKeys: RowKeys { RowKeys(of: self) }
}

extension Recipient: ContactFacts {}

// #4358 slice E4a (plan v7 Phase 4, B2 "every pass input is a value"): the queue pass's OTHER inputs as protocols
// too, so `QueueRenderPass.make` reads them through one generic body: the live models in today's memo path, the
// engine's retained records (`QueueEngineRecords.swift`) once it hands the pass in (#4358, slice E4b). Each
// declares every stored property its record carries, under the model's own names, on `ProspectFacts`' rule
// (`RowFactsSchemaCoverageTests` holds each to its record), so a term written over one reads either.
//
// WHY PROTOCOLS AND NOT RECORDS BUILT BY THE CALLER. The memo path builds its pass inside an observation scope
// (`ScopeMemo`), and a record copies EVERY stored field, so building one there would observe every field of every
// inquiry and source: a write to one the pass never reads (a reply check stamping `replyTextCheckedAt`) would
// rebuild the whole queue. Over the protocol the memo path reads exactly the fields it read before.

/// One direct hire inquiry's facts: every stored `Inquiry` property, as `InquiryRecord` carries them.
protocol InquiryFacts: ReplyArrivalFacts, SendableMetatype {
    var persistentModelID: PersistentIdentifier { get }
    var attachWroteSentAt: Bool { get }
    var autoBookingRejectedWithoutId: Bool { get }
    var bookingSuggested: Bool { get }
    var bookingSuggestionDismissed: Bool { get }
    var bounced: Bool { get }
    var conversationAttachedAt: Date? { get }
    var conversationSubject: String? { get }
    var createdAt: Date { get }
    var delayNoticeAt: Date? { get }
    var dismissedBounceId: String? { get }
    var dismissedReplyId: String? { get }
    var downbeatClientId: String? { get }
    var eventName: String { get }
    var gmailMessageId: String? { get }
    var gmailReferences: String? { get }
    var gmailThreadId: String? { get }
    var inboundReplyMessageId: String? { get }
    var inboundReplySentAt: Date? { get }
    var inquirerEmail: String? { get }
    var inquirerName: String { get }
    var lastBounceId: String? { get }
    var lastDelayMessageId: String? { get }
    var lastReplyId: String? { get }
    var lastReplyText: String? { get }
    var lostReasonRaw: String? { get }
    var notes: String? { get }
    var outcomeAt: Date? { get }
    var outcomeRaw: String { get }
    var outcomeSourceRaw: String? { get }
    var performanceDate: String? { get }
    var rejectedBookingIdsRaw: String { get }
    var replied: Bool { get }
    var repliedAt: Date? { get }
    var replyAudience: [String]? { get }
    var replyCandidateSearchedAt: Date? { get }
    var replyFromAddress: String? { get }
    var replyFromName: String? { get }
    var replyHandledAt: Date? { get }
    var replyTextCheckedAt: Date? { get }
    var runEndDate: String? { get }
    var sendError: String? { get }
    var sentAt: Date? { get }
    var showOutcomeAt: Date? { get }
    var showOutcomeRaw: String? { get }
    var sourceRaw: String { get }
    var threadIdDegraded: Bool { get }
    var threadingDegraded: Bool { get }
    var venue: String? { get }
}

/// One organisation's stored reachability answer: every stored `OrgReachabilityAnswer` property.
protocol OrgAnswerFacts: SendableMetatype {
    var persistentModelID: PersistentIdentifier { get }
    var foundEmailsRaw: String { get }
    var orgKey: String { get }
    var presenterName: String { get }
    var probedAt: Date { get }
    var resultRaw: String { get }
    var sourceGroupName: String { get }
    var sourceNaturalKey: String { get }
}

/// One watched calendar's facts: every stored `WatchedSource` property.
protocol WatchedSourceFacts: SendableMetatype {
    var persistentModelID: PersistentIdentifier { get }
    var addedAt: Date { get }
    var baselineFeedCount: Int { get }
    var clientTagClientId: String? { get }
    var clientTagOverride: Bool? { get }
    var confirmedEmptyHash: String? { get }
    var degradedStreak: Int { get }
    var emptyStreak: Int { get }
    var failedReadStreak: Int { get }
    var hadPlacedBeforeLastRun: Bool { get }
    var hasUnreadChanges: Bool { get }
    var healthRaw: String { get }
    var inactiveReasonRaw: String? { get }
    var isActive: Bool { get }
    var kindRaw: String { get }
    var lastCheckedAt: Date? { get }
    var lastContentHash: String? { get }
    var lastDegradedCount: Int { get }
    var lastDroppedShowLabelsRaw: String { get }
    var lastErrorRaw: String? { get }
    var lastFetchWasInsecure: Bool { get }
    var lastLandedRunID: String? { get }
    var lastLandedSequence: Int { get }
    var lastManualReadAt: Date? { get }
    var lastNonEmptyAt: Date? { get }
    var lastObservedContentHash: String? { get }
    var lastPlacedCount: Int { get }
    var lastReadableCount: Int { get }
    var lastStructuralGapCount: Int { get }
    var lastSucceededAt: Date? { get }
    var lastTouchedSequence: Int { get }
    var lastUnreadableCount: Int { get }
    var lastUnreadableTitleCount: Int { get }
    var listingsURL: String? { get }
    var mergeSameDateVenue: Bool { get }
    var notes: String? { get }
    var orgName: String { get }
    var pageCount: Int { get }
    var pendingContentHash: String? { get }
    var pendingPageMonthsRaw: String { get }
    var sourceId: String { get }
    var successfulCheckCount: Int { get }
    var ticketingFeedURL: String? { get }
    var venueLocation: String? { get }
    var venueName: String? { get }
}

extension Inquiry: InquiryFacts {}
extension InquiryRecord: InquiryFacts {}
extension OrgReachabilityAnswer: OrgAnswerFacts {}
extension OrgAnswerRecord: OrgAnswerFacts {}
extension WatchedSource: WatchedSourceFacts {}
extension WatchedSourceRecord: WatchedSourceFacts {}

extension OrgAnswerFacts {
    // nil when a future version wrote a verdict this build cannot read. An unreadable value must never be
    // reported as one of today's answers (#1596's own rule, kept here).
    var result: Reachability.ProbeResult? { Reachability.ProbeResult(rawValue: resultRaw) }

    var foundEmails: [String] { foundEmailsRaw.split(separator: "\n").map(String.init) }
}

// #4358 slice E4a: the ONE family of rows a queue pass is made over, as its row type: a show, and the inquiry,
// answer and source types beside it. Today's memo path is made over the live models (`Prospect`); the engine's
// over its retained values (`RowFacts`). A pass never mixes the two, and naming the family through the row keeps
// `QueueRenderPass.Inputs` one generic parameter rather than four that could be crossed.
//
// THE TWO MEMBERS ARE HOW EACH FAMILY READS WHAT IT HOLDS, and they are why this is more than `ProspectFacts`.
// The stage, reached out and pill terms walk a show's contacts and ask whether it is closed. Over the models the
// pass has always read the uncounted `recipients` relationship for them, and the model's own `isClosed` over it,
// so no `WorkTally.recipientReaches` pin moves and no contact list is sorted twice; over facts it reads the
// retained list, which is already in canonical order and counts nothing.
protocol QueuePassRow: ProspectFacts {
    associatedtype PassInquiry: InquiryFacts
    associatedtype PassAnswer: OrgAnswerFacts
    associatedtype PassSource: WatchedSourceFacts

    /// The contacts the stage, reached out and pill terms walk.
    var passContacts: [Contact] { get }
    /// Whether the show is closed for routine follow ups, read as the pass has always read it.
    var passIsClosed: Bool { get }
    /// #4371: how a card store built over this family holds what a card it did not prebuild is built from. The
    /// models by identity (`CardSourcesByIdentity`), so no store holds a model; the engine's values as they are.
    static func cardSources(shows: [Self], contacts: [String: [Contact]]) -> any QueueModel.CardSources
}

extension Prospect: QueuePassRow {
    typealias PassInquiry = Inquiry
    typealias PassAnswer = OrgReachabilityAnswer
    typealias PassSource = WatchedSource
    var passContacts: [Recipient] { recipients }
    var passIsClosed: Bool { isClosed }
    static func cardSources(shows: [Prospect], contacts: [String: [Recipient]]) -> any QueueModel.CardSources {
        QueueModel.CardSourcesByIdentity(shows: shows, contacts: contacts)
    }
}

extension RowFacts: QueuePassRow {
    typealias PassInquiry = InquiryRecord
    typealias PassAnswer = OrgAnswerRecord
    typealias PassSource = WatchedSourceRecord
    var passContacts: [RecipientRecord] { factContacts }
    var passIsClosed: Bool { isClosed }
    static func cardSources(shows: [RowFacts], contacts: [String: [RecipientRecord]]) -> any QueueModel.CardSources {
        QueueModel.CardSourcesOf(shows: Dictionary(shows.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a }),
                                 contacts: contacts)
    }
}
