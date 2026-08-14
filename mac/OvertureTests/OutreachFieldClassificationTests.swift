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
        "heldDownToUnverified": "a guard's opinion of how the address was cited",
        "heldDownToUnverifiedDismissed": "Dan waving that guard off, an answer about the address",

        // Drafted, not sent. A body exists on a contact nobody has written to yet, which is exactly the
        // state the merge is for.
        "overrideBody": "a draft written for this contact, which is not a send",
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
        "replyDraftWrittenByDan": "whether he wrote the reply draft himself, and replyDraftBody is counted",
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
