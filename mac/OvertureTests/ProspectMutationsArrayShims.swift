import Foundation
import SwiftData

// #4357 slice I2, TEMPORARY: deleted by the next pull request in its stack (m80-4357-i2p2-b).
//
// Every row action now takes `shows: some ShowResolver` and resolves the card through it by store
// identity. Relabelling every test call site in the same pull request as the signature change put it past
// what the lessons review can read, so the pure suite's call sites keep their `prospects:` label for one
// pull request through these forwarding overloads. Each passes the array straight on as the resolver, so
// a test through one runs exactly the code a press runs. Test target only: the app never sees them, and
// `AControlThatFindsNothingSaysSoTests` reads only the app's own files.
@MainActor
extension ProspectMutations {
    static func toggleVoiceLearning(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        toggleVoiceLearning(item, shows: prospects, context: context, feedback: feedback)
    }

    static func requestReachabilityRecheck(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, now: Date = Date()) {
        requestReachabilityRecheck(item, shows: prospects, context: context, feedback: feedback, now: now)
    }

    static func dismissReply(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissReply(item, shows: prospects, context: context, feedback: feedback)
    }

    static func markContact(_ item: QueueItem, _ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        markContact(item, recipientId, resolution, bounced, shows: prospects, context: context, feedback: feedback)
    }

    @discardableResult
    static func recordOutcome(_ item: QueueItem, _ outcome: ShowOutcome, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, undo: QueueUndoStack? = nil) -> Bool {
        return recordOutcome(item, outcome, shows: prospects, context: context, feedback: feedback, undo: undo)
    }

    @discardableResult
    static func reopenOutcome(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) -> Bool {
        return reopenOutcome(item, shows: prospects, context: context, feedback: feedback)
    }

    static func detachConversation(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, now: Date = Date()) {
        detachConversation(item, recipientId, shows: prospects, context: context, feedback: feedback, now: now)
    }

    static func addRecipientManually(_ item: QueueItem, email: String, name: String?, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        addRecipientManually(item, email: email, name: name, shows: prospects, context: context, feedback: feedback)
    }

    static func manualPrepPrefill(_ item: QueueItem, prospects: [Prospect]) -> ManualPrepPrefill.Result {
        return manualPrepPrefill(item, shows: prospects)
    }

    static func prepManually(_ item: QueueItem, email: String, name: String?, subject: String, body: String, sendsTogether: Bool = true, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        prepManually(item, email: email, name: name, subject: subject, body: body, sendsTogether: sendsTogether, shows: prospects, context: context, feedback: feedback)
    }

    static func removeRecipientManually(_ item: QueueItem, _ recipientId: String, _ name: String?, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        removeRecipientManually(item, recipientId, name, shows: prospects, context: context, feedback: feedback)
    }

    static func removeInheritedAddress(_ item: QueueItem, email: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        removeInheritedAddress(item, email: email, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissContactReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissContactReply(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissContactBounce(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissContactBounce(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissVenueMatch(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissVenueMatch(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func confirmGuessedProfile(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        confirmGuessedProfile(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissPressContactMatch(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissPressContactMatch(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissDuplicateContactMatch(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissDuplicateContactMatch(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissConfidenceHeldDown(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissConfidenceHeldDown(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissAddressInAnotherName(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissAddressInAnotherName(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func draftReply(_ naturalKey: String, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, start: ReplyDraftLaunch = { try launchReplyDrafter($0, $1) }) {
        draftReply(naturalKey, recipientId, shows: prospects, context: context, feedback: feedback, start: start)
    }

    static func editReplyDraft(_ item: QueueItem, _ recipientId: String, _ body: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        editReplyDraft(item, recipientId, body, shows: prospects, context: context, feedback: feedback)
    }

    static func copyReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        copyReply(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func confirmCopiedReplySent(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        confirmCopiedReplySent(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func beginFormPitch(_ item: QueueItem, _ recipientId: String, _ formURL: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        beginFormPitch(item, recipientId, formURL, shows: prospects, context: context, feedback: feedback)
    }

    static func recordFormPitch(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        recordFormPitch(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func cancelFormPitch(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        cancelFormPitch(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func setStatus(_ item: QueueItem, _ status: ReviewStatus, _ reason: ShowOutcome?, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, undo: QueueUndoStack? = nil, undoLabel: String? = nil) {
        setStatus(item, status, reason, shows: prospects, context: context, feedback: feedback, undo: undo, undoLabel: undoLabel)
    }

    @discardableResult
    static func dismissAll(_ keys: [String], reason: ShowOutcome, dateLabel: String, nightDate: String? = nil, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, undo: QueueUndoStack? = nil, now: Date = Date(), export: DayOffEditing.Export = DownbeatBridge.loadedExport()) -> DayOffOfferRequest.Pending? {
        return dismissAll(keys, reason: reason, dateLabel: dateLabel, nightDate: nightDate, shows: prospects, context: context, feedback: feedback, undo: undo, now: now, export: export)
    }

    static func dismissForReason(_ item: QueueItem, _ reason: ShowOutcome, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, offer: DayOffOfferRequest, undo: QueueUndoStack? = nil, now: Date = Date(), export: DayOffEditing.Export = DownbeatBridge.loadedExport()) {
        dismissForReason(item, reason, shows: prospects, context: context, feedback: feedback, offer: offer, undo: undo, now: now, export: export)
    }

    static func saveDraft(_ item: QueueItem, _ subject: String, _ body: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        saveDraft(item, subject, body, shows: prospects, context: context, feedback: feedback)
    }

    static func setSendsTogether(_ item: QueueItem, _ together: Bool, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        setSendsTogether(item, together, shows: prospects, context: context, feedback: feedback)
    }

    static func reprep(_ item: QueueItem, mode: ReprepMode, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, now: Date = Date(), startPrep: @MainActor (ModelContext, Date, Set<String>) async throws -> Void = { ctx, now, keys in _ = try await PrepQueueService.startPrep(from: ctx, now: now, includedKeys: keys) }) async {
        await reprep(item, mode: mode, shows: prospects, context: context, feedback: feedback, now: now, startPrep: startPrep)
    }

    static func bulkReprep(_ mode: ReprepMode, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, now: Date = Date()) {
        bulkReprep(mode, shows: prospects, context: context, feedback: feedback, now: now)
    }

    static func correctClassification(_ item: QueueItem, discipline: Discipline, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        correctClassification(item, discipline: discipline, shows: prospects, context: context, feedback: feedback)
    }

    static func renameGroup(_ item: QueueItem, to newName: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        renameGroup(item, to: newName, shows: prospects, context: context, feedback: feedback)
    }

    static func resetGroupName(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        resetGroupName(item, shows: prospects, context: context, feedback: feedback)
    }

    static func remindRecipientLater(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        remindRecipientLater(item, recipientId, shows: prospects, context: context, feedback: feedback)
    }

    static func confirmBooking(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        confirmBooking(item, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissBookingSuggestion(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissBookingSuggestion(item, shows: prospects, context: context, feedback: feedback)
    }

    static func clearConflict(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        clearConflict(item, shows: prospects, context: context, feedback: feedback)
    }

    static func dismissAlreadyCoveredFlag(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        dismissAlreadyCoveredFlag(item, shows: prospects, context: context, feedback: feedback)
    }

    static func setOrgDoNotContact(_ item: QueueItem, _ on: Bool, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        setOrgDoNotContact(item, on, shows: prospects, context: context, feedback: feedback)
    }

    @discardableResult
    static func confirmPerformerMatch(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) -> Bool {
        return confirmPerformerMatch(item, shows: prospects, context: context, feedback: feedback)
    }

    @discardableResult
    static func dismissPerformerMatch(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) -> Bool {
        return dismissPerformerMatch(item, shows: prospects, context: context, feedback: feedback)
    }

    static func overrideGreeting(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        overrideGreeting(item, shows: prospects, context: context, feedback: feedback)
    }

    static func overrideDraftLint(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        overrideDraftLint(item, shows: prospects, context: context, feedback: feedback)
    }

    static func pitchNightAfterAll(_ item: QueueItem, night: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, now: Date = Date()) {
        pitchNightAfterAll(item, night: night, shows: prospects, context: context, feedback: feedback, now: now)
    }

    static func rejectBooking(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        rejectBooking(item, shows: prospects, context: context, feedback: feedback)
    }

    static func setLostReason(_ item: QueueItem, _ reason: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        setLostReason(item, reason, shows: prospects, context: context, feedback: feedback)
    }

    static func approveAndSend(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, selecting: [String]? = nil, together: Bool? = nil, sender: MailSender = liveSender(), markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void, onNeedsReconnect: @escaping () -> Void, onSent: @escaping (_ naturalKey: String, _ fullySent: Bool) -> Void = { _, _ in }) {
        approveAndSend(item, shows: prospects, context: context, feedback: feedback, selecting: selecting, together: together, sender: sender, markSending: markSending, clearSending: clearSending, onNeedsReconnect: onNeedsReconnect, onSent: onSent)
    }

    static func performSend(_ naturalKey: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, selecting: [String]? = nil, together: Bool? = nil, sender: MailSender = liveSender(), markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void, onNeedsReconnect: @escaping () -> Void, onSent: @escaping (_ naturalKey: String, _ fullySent: Bool) -> Void = { _, _ in }) {
        performSend(naturalKey, shows: prospects, context: context, feedback: feedback, selecting: selecting, together: together, sender: sender, markSending: markSending, clearSending: clearSending, onNeedsReconnect: onNeedsReconnect, onSent: onSent)
    }

    static func sendReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, sender: MailSender = liveSender(), markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void, onNeedsReconnect: @escaping () -> Void) {
        sendReply(item, recipientId, shows: prospects, context: context, feedback: feedback, sender: sender, markSending: markSending, clearSending: clearSending, onNeedsReconnect: onNeedsReconnect)
    }

    static func sendFollowUp(_ naturalKey: String, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, sender: MailSender = liveSender(), body: String? = nil, now: Date = Date(), markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void) {
        sendFollowUp(naturalKey, recipientId, shows: prospects, context: context, feedback: feedback, sender: sender, body: body, now: now, markSending: markSending, clearSending: clearSending)
    }
}
