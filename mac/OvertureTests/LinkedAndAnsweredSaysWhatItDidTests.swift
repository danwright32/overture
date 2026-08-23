import Testing
import Foundation

// #2806. Dan, 2026-08-16, immediately after linking a conversation onto a pitch: "overture correctly
// found their response email and asked me to link it, which I did. But then nothing seemed to happen?
// Did the link work? What did it do?"
//
// It had worked. Five distinct facts were written in that one moment: the thread was linked, the reply
// was captured with its text and its sender, an email address was written onto a contact that had none
// so the show became emailable, and the reply was stamped as already answered because the newest message
// on the thread was his own. What he got back was a transient toast and one changed sentence.
//
// THE QUIET IS THREE CORRECT DECISIONS STACKING. `ProposedConversation.state` returns
// `.attachedAwaitingAnswer` only when there is an unhandled reply, so an attach that stamps
// `replyHandledAt` falls to `.notApplicable`, which draws nothing at all. So the more completely the
// attach succeeded, the less the product said about it: the version that shows a reply badge is the one
// where he had NOT already answered, which has LESS to report, not more.
//
// That is L148 in shape: the durable state changed, the only account of the change was transient, and
// pressing the control again is the only diagnosis available. Here it would be refused as already
// linked.
//
// THE ACCOUNT IS DERIVED FROM THE STORED FACTS, never from the attach's transient outcome. A line built
// from the outcome exists only in the frame that did the work; this one is there tomorrow, after a
// relaunch, on every render, which is what "durable" has to mean for a question he asked a minute later.
@Suite("A conversation linked and already answered says what it did (#2806)")
struct LinkedAndAnsweredSaysWhatItDidTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func linkedContact(answered: Bool, wroteAddress: Bool, subject: String? = "54 Sings Photography",
                               email: String? = "someone@example.com") -> Recipient {
        let r = Recipient(id: "form:https://venue.example/contact", email: email, name: "Corin",
                          provenance: .act)
        r.contactFormURL = "https://venue.example/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        r.gmailThreadId = "t-1"
        r.conversationAttachedAt = now
        r.attachedThreadSubject = subject
        r.attachWroteAddress = wroteAddress
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-3_600)
        if answered { r.replyHandledAt = now }
        return r
    }

    // MARK: - The state that drew nothing

    // The exact row from Dan's report: linked, reply captured, and nothing waiting on him.
    @Test func alinkedConversationWithNothingWaitingIsItsOwnStateRatherThanNothingAtAll() {
        let r = linkedContact(answered: true, wroteAddress: true)
        #expect(ProposedConversation.state(of: r, now: now) == .attachedAndAnswered,
                "the most completely successful attach still falls to the state that draws EmptyView (#2806)")
    }

    // The state with LESS to report is unchanged. It already had a line, and this issue is not about it.
    @Test func alinkedConversationStillWaitingIsUnchanged() {
        let r = linkedContact(answered: false, wroteAddress: true)
        #expect(ProposedConversation.state(of: r, now: now) == .attachedAwaitingAnswer)
    }

    // A row with no attach at all is untouched: this must not start speaking on every contact.
    @Test func acontactWithNoLinkedConversationSaysNothingNew() {
        let r = Recipient(id: "a@example.com", email: "a@example.com", name: "Nessa", provenance: .act)
        #expect(ProposedConversation.state(of: r, now: now) != .attachedAndAnswered)
    }

    // MARK: - What the line says

    // The reply is named as CAPTURED, which is the fact he could not see. Not "linked": he pressed the
    // link button and already knows he did.
    @Test func thelineSaysTheirReplyWasCaptured() {
        let line = ProposedConversationCopy.linkedAndAnswered(wroteAddress: false, address: nil)
        #expect(line.contains("reply"))
        // It says what the attach DID, which is the question Dan asked. "Nothing is waiting on you" is
        // true and answers a question he did not ask; his was "did the link work, what did it do".
        #expect(line.contains("answered"), "the line does not say his answer is already on the thread")
    }

    // The saved address is named, because it is the consequence with the longest reach: every email on
    // this show from now on goes there. `confirmDetail` promises exactly that BEFORE the click and
    // nothing confirmed it after.
    @Test func thelineNamesTheAddressItSavedWhenItSavedOne() {
        let line = ProposedConversationCopy.linkedAndAnswered(wroteAddress: true,
                                                              address: "someone@example.com")
        #expect(line.contains("someone@example.com"))
    }

    // And does not claim to have saved one when it did not, which would be a promise about where mail
    // goes that is simply false.
    @Test func thelineNamesNoAddressWhenItSavedNone() {
        let line = ProposedConversationCopy.linkedAndAnswered(wroteAddress: false, address: nil)
        #expect(!line.contains("@"))
        #expect(!line.contains("Email goes to"),
                "the line promises where email goes without naming anywhere")
    }

    // An address the attach did NOT write is not this line's to promise. The contact may have carried an
    // address all along, and saying mail goes there now would report an act that never happened.
    @Test func anaddressTheAttachDidNotWriteIsNotClaimed() {
        let line = ProposedConversationCopy.linkedAndAnswered(wroteAddress: false,
                                                              address: "already@example.com")
        #expect(!line.contains("already@example.com"))
    }

    // A row that says it saved an address and carries none cannot say so. Reading `attachWroteAddress`
    // without the address itself would render "and it goes to " with nothing after it, which is the
    // placeholder-as-fact shape (L67).
    @Test func aflagWithNoAddressBehindItNamesNoAddress() {
        let line = ProposedConversationCopy.linkedAndAnswered(wroteAddress: true, address: nil)
        // The EXACT no-address sentence, not merely "contains no @". A version that interpolated an
        // empty string would also contain no @ and would render "Email goes to  from now on.", which is
        // a promise about where mail goes with the promise missing (L67). Measured: mutate.sh reported
        // SURVIVED on precisely that mutation while the weaker assertion was here.
        #expect(line == ProposedConversationCopy.linkedAndAnswered(wroteAddress: false, address: nil))
        #expect(!line.contains("Email goes to"))
        #expect(!line.isEmpty, "the row falls silent again on a half-written attach, which is #2806 itself")
    }

    // MARK: - Built is not wired (L3)

    @Test func thereachedOutRowDrawsTheNewState() {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("case .attachedAndAnswered:", in: source),
                "the row has a state for this and still draws nothing for it (#2806, L3)")
        #expect(source.contains("ProposedConversationCopy.linkedAndAnswered"),
                "the row draws the state and not its sentence")
    }
}
