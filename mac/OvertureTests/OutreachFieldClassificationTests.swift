import Testing
import Foundation

// #2009: `Recipient.wasWrittenTo` decides whether anybody has actually been WRITTEN TO at a contact, as
// opposed to the address merely having been FOUND by a paid check. Three merge passes read it, through
// `NaturalKeyVenueMigration.hasRecordBeyondADismissal`, to decide whether a duplicate row may be deleted.
// So this one answer stands between a merge and a record of real outreach.
//
// It is a hand-written list, and it can only name what existed when it was written. `Recipient` gains
// fields regularly. The day somebody adds a new way of recording that an outreach happened and does not
// add it there, a duplicate holding that record becomes deletable and the next launch deletes it. Nothing
// fails, nothing warns, and the loss is silent and permanent.
//
// The function already carries a comment asking a future author to add their field. A rule that lives
// only in a comment is a hope; this is its detector. Same shape as #1780's split and #1949's merge: a
// judgment correct on the day it was written, with nothing to notice the day it stops being complete.
@Suite("Every Recipient field is classified for the merge (#2009)")
struct OutreachFieldClassificationTests {

    // The COUNTED set is not restated here. It is read out of `wasWrittenTo`'s own body, so this guard
    // cannot drift from the rule it guards (L41): a field removed from the function moves into this
    // test's failure list rather than being quietly still believed.
    private var recipientSource: String { SourceGuardHelper.source("Overture/Domain/Recipient.swift") }

    // Every stored property that does NOT record an outreach, each with the reason it does not. Most are
    // COMPANIONS: a row that carries them necessarily also carries a field `wasWrittenTo` counts, because
    // one write path sets both, which is why not counting them costs nothing.
    static let notOutreach: [String: String] = [
        // Identity and the address itself.
        "id": "the row's identity",
        "email": "the address, which is what a check FINDS rather than what a send records",
        "name": "who the address belongs to",
        "role": "their job title, from the page the address came off",
        "prospect": "the show this contact belongs to",

        // How the address was found. This is the whole other side of the distinction: a found address is
        // the result of a lookup and is repeatable by running the lookup again.
        "provenanceRaw": "how the address was found (act, performer, presenter, Dan)",
        "contactMethodRaw": "how the check reached it",
        "contactConfidenceRaw": "how sure the check was",
        "contactFormURL": "a form the check found, not one anybody submitted",
        "contactSourceURL": "the page the address was read off",

        // What a guard thought, and what Dan answered about it. Dan's answers are his work, but they are
        // answers about an ADDRESS rather than a record that somebody was written to.
        "looksLikeVenue": "a guard's opinion of the address",
        "looksLikeVenueDismissed": "Dan waving that guard off, an answer about the address",
        "contactTierRaw": "who the check judged this contact to be, a fact about the ADDRESS not about a send",
        "looksLikeAnotherPersons": "a guard's opinion of the address",
        "looksLikeAnotherPersonsDismissed": "Dan waving that guard off, an answer about the address",
        "looksLikePressContact": "a guard's opinion of the address",
        "looksLikePressContactDismissed": "Dan waving that guard off, an answer about the address",
        "looksLikeDuplicateContact": "a guard's opinion of the address",
        "looksLikeDuplicateContactDismissed": "Dan waving that guard off, an answer about the address",
        // #2912: what the CHECK said about the route it found, in the same family as the two below it.
        // Nobody has been written to on the strength of a name matching a handle; the write that would
        // prove this contact was reached is formOutreachRecordedAt, which the rule counts.
        "nameMatchOnly": "the check saying only the NAME matched, a fact about the route it found",
        "heldDownToUnverified": "a guard's opinion of how the address was cited",
        "heldDownToUnverifiedDismissed": "Dan waving that guard off, an answer about the address",
        // #2895: WHICH guard's opinion, which is the same family as the flag it qualifies. It says
        // something about how the check cited an address and nothing about anybody being written to.
        "heldDownReasonRaw": "which citation rule held the address down, a fact about the check's evidence",

        // Drafted, not sent. A body exists on a contact nobody has written to yet, which is exactly the
        // state the merge is for.
        // #3549: RETAINED STORAGE, read and written by nothing. Classified anyway, because this
        // guard asks about every stored field and a retained one is still a stored field.
        "overrideBody": "a retired second copy of a draft, which was never a send",
        "lintOverriddenBody": "a draft the lint was waved off on, still not a send",
        "greetingOverriddenBody": "a draft the greeting hold was waved off on, still not a send",
        "openingOverride": "Dan's chosen opening for a draft, still not a send",

        // Companions of a counted field: one write path sets both.
        "outreachChannelRaw": "set with formOutreachRecordedAt and sentAt by recordFormOutreach",
        "formOutreachURL": "set with formOutreachRecordedAt",
        "formOutreachPriorStatusRaw": "set with formOutreachRecordedAt",
        "suppressionReasonRaw": "why sendState is suppressed, and sendState is counted",
        "sendStateRaw": "read as sendState, which is counted",
        "sendError": "what a send attempt failed with; the attempt set sendClaimedAt",
        "replyTrackingDegraded": "a property of a send that happened",
        "threadingDegraded": "a property of a send that happened: its Message-ID could not be read back",
        "gmailReferences": "the ancestry of gmailMessageId, written in the same step, and that id is counted",
        "replyFromAddress": "read off a reply, and replied is counted",
        "replyFromName": "read off a reply, and replied is counted",
        "inboundReplySentAt": "when their reply was sent, and replied is counted",
        "inboundReplyMessageId": "which message of theirs is being answered, and replied is counted",
        "replyTextCheckedAt": "when a reply was last read, and replied is counted",
        "replyHandledAt": "when Dan dealt with a reply, and replied is counted",
        "lastReplyId": "which reply, and replied is counted",
        "dismissedReplyId": "a reply Dan dismissed, and replied is counted",
        "lastReplyText": "the reply's words, and replied is counted",
        "lastBounceId": "which bounce, and bounced is counted",
        "dismissedBounceId": "a bounce Dan dismissed, and bounced is counted",
        "delayNoticeAt": "a delivery delay notice about a send that happened",
        "lastDelayMessageId": "which delay notice, about a send that happened",
        "nudgeRemindedAt": "a reminder about a send that happened",
        "conversationRemindedAt": "a reminder about a conversation that happened",
        "pausedByReply": "paused BECAUSE they replied, and replied is counted",
        "resolutionRaw": "how it ended, which can only follow a send",
        "outcomeSourceRaw": "who decided the ending",
        "replyDraftSubject": "set beside replyDraftBody, which is counted",
        "replyDraftModel": "what wrote the reply draft, set beside replyDraftBody",
        "originalReplyDraftBody": "what the reply draft said before Dan edited it",
        "sentReplyBody": "set with replySentAt, which is counted",
        "replyAudience": "who a reply went to, captured with the reply that is counted",
        "intentHint": "what a classify run read a REPLY as meaning, and replied is counted",
        "replyDraftEditedByDan": "whether he edited the reply draft, and replyDraftBody is counted",
        // #2869: the draft is on the clipboard and Dan has NOT said he sent it. Deliberately not
        // outreach, which is the whole of that change: copying is not sending, and the field exists
        // precisely to hold the in-between state that used to be recorded as an answer. `replySentAt`
        // and `replyHandledAt` are what say something happened, and both are written by the confirm.
        "replyCopiedAt": "the reply draft was put on the clipboard and nothing has been sent yet (#2869)",
        "replyDraftWrittenByDan": "whether he wrote the reply draft himself, and replyDraftBody is counted",
        "replyMarkClearedStandDown": "set with replyMarkedByHandAt by HandMarkedReply.mark, and that is counted",
        // #2715: the attach can only ever run on a contact that already carries formOutreachRecordedAt
        // (it refuses otherwise) and it stamps gmailThreadId, and BOTH of those are counted by the rule
        // above. So every one of these is written strictly inside a state already counted, and none of
        // them can be the only evidence an outreach happened.
        "conversationAttachedAt": "when Dan linked a conversation by hand, which is only possible on a "
            + "contact whose form outreach is already recorded, and it stamps gmailThreadId, both counted",
        "attachedThreadSubject": "what the linked thread is called, so a reply can carry a subject Gmail "
            + "will accept; written with gmailThreadId, which is counted",
        "attachPriorResolutionRaw": "what the attach found before detection cleared it, for the detach "
            + "to put back; written with gmailThreadId, which is counted",
        "attachPriorOriginalReplyDraftBody": "the same snapshot, for the reply-draft baseline",
        "attachPriorReplyDraftWrittenByDan": "the same snapshot, for the reply-draft baseline",
        "attachPriorReplyDraftEditedByDan": "the same snapshot, for the reply-draft baseline",
        "attachPausedRecipientIds": "which OTHER contacts on the show this attach froze, so the detach "
            + "unfreezes only those; a fact about its neighbours, never about this contact being written to",
        // #2718: the QUESTION Overture is asking about this contact, which is a fact about a message in
        // Dan's mailbox rather than about anybody having been written to. Every one of them can only be
        // set on a contact that already carries formOutreachRecordedAt, which the rule above counts,
        // because `ProposedConversation.isAskable` refuses otherwise.
        "replyProposedMessageId": "which message Overture is asking about; a fact about his inbox",
        "replyProposedThreadId": "which conversation that message is on",
        "replyProposedFromAddress": "who that message is from, so the row can ask without calling Gmail",
        "replyProposedFromName": "and what they are called",
        "replyProposedSubject": "what that message is called",
        "replyProposedSentAt": "when that message was sent",
        "replyProposedScore": "how strongly it matched, for diagnosing a wrong proposal",
        "replyProposedAt": "when Overture started asking",
        "dismissedConversationIds": "the conversations Dan has said are NOT them, the sibling of "
            + "dismissedReplyId above and not outreach for the same reason it is not",
        "attachWroteAddress": "whether the ATTACH is what put the current address here, so a detach takes "
            + "back only what it wrote; provenance of a field, not evidence anybody was contacted",
        "replyCandidateSearchedAt": "when OVERTURE last read the mailbox for an answer to this pitch, "
            + "which is a record of its own looking and says nothing about anybody having been written to; "
            + "the write that proves this contact was reached is formOutreachRecordedAt, which is counted",
    ]

    @Test func everyStoredPropertyIsEitherCountedAsOutreachOrRecordedAsNotOutreach() throws {
        let classBody = try #require(
            SourceGuardHelper.propertyBody("final class Recipient {", in: recipientSource),
            "Recipient's class body could not be read, so this guard measured nothing")
        let rule = try #require(
            SourceGuardHelper.propertyBody("var wasWrittenTo: Bool {", in: recipientSource),
            "wasWrittenTo could not be found: it is what this guard measures")

        let stored = SourceGuardHelper.storedPropertyNames(inClassBody: classBody)
        #expect(stored.count > 40, "found almost no stored properties, which is a broken read")

        let unclassified = stored.filter { name in
            if Self.notOutreach.keys.contains(name) { return false }
            // A `...Raw` field is read through its typed accessor, so the rule names the accessor.
            let asRead = name.hasSuffix("Raw") ? String(name.dropLast(3)) : name
            return !rule.contains(name) && !rule.contains(asRead)
        }

        #expect(unclassified.isEmpty, """
            \(unclassified.joined(separator: ", ")): neither counted by `Recipient.wasWrittenTo` nor \
            listed in `notOutreach` above. Decide whether the field records that somebody was WRITTEN TO \
            (as opposed to the address having been found), then add it to the rule or to that list with \
            the reason. Getting this wrong deletes an outreach record on the next launch's merge, \
            silently and permanently, so the cheap direction is to count too much.
            """)
    }

    // The list must not rot the other way either: an entry for a field that has gone is a note about
    // code that no longer exists, and it would let a real one hide behind it.
    @Test func nothingIsListedThatIsNoLongerAField() throws {
        let classBody = try #require(SourceGuardHelper.propertyBody("final class Recipient {",
                                                                     in: recipientSource))
        let stored = Set(SourceGuardHelper.storedPropertyNames(inClassBody: classBody))

        let gone = Self.notOutreach.keys.filter { !stored.contains($0) }.sorted()

        #expect(gone.isEmpty, "these are listed as not-outreach but are no longer fields: \(gone.joined(separator: ", "))")
    }

    // Every reason is a real reason. An empty string would pass the list check while recording nothing
    // about why the field is safe, which is the whole value of the list.
    @Test func everyEntryCarriesItsReason() {
        for (field, reason) in Self.notOutreach {
            #expect(reason.count > 10, "\(field) is listed with no real reason: \"\(reason)\"")
        }
    }

    // Seen to fail (L1). A guard over a hand-written list is worth nothing until a new field has actually
    // been watched to trip it, and this is the exact shape the issue is about: somebody adds a field that
    // records an outreach and does not teach the rule.
    @Test func aNewFieldTheRuleWasNeverTaughtIsReported() throws {
        let classBody = try #require(SourceGuardHelper.propertyBody("final class Recipient {",
                                                                     in: recipientSource))
        let withNewField = classBody + "\n    var carrierPigeonSentAt: Date? = nil\n"

        let stored = SourceGuardHelper.storedPropertyNames(inClassBody: withNewField)

        #expect(stored.contains("carrierPigeonSentAt"))
        #expect(!Self.notOutreach.keys.contains("carrierPigeonSentAt"))
        #expect(!recipientSource.contains("carrierPigeonSentAt"),
                "the fixture name must not exist for real, or this proves nothing")
    }

    // The rule's own reason for existing, restated as a test so it cannot be lost in a refactor: a found
    // address is not a contacted one, and the merge turns on the difference.
    @Test func aFoundButUnwrittenAddressIsNotCountedAsOutreach() {
        let found = Recipient(id: "r1", email: "info@example.test", name: "Someone", provenance: .act)
        found.contactMethodRaw = ContactMethod.genericInbox.rawValue
        found.contactConfidenceRaw = ContactConfidence.medium.rawValue
        found.contactSourceURL = "https://example.test/contact"

        #expect(!found.wasWrittenTo)
    }

    // And the other direction, so the test above cannot pass because `wasWrittenTo` has stopped answering
    // at all.
    @Test func aContactedAddressIsCountedAsOutreach() {
        let written = Recipient(id: "r2", email: "info@example.test", name: "Someone", provenance: .act)
        written.sentAt = Date(timeIntervalSince1970: 1_780_000_000)

        #expect(written.wasWrittenTo)
    }
}
