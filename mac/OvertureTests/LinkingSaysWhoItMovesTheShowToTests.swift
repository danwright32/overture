import Testing
import Foundation

// #3711 (milestone 82, Phase 5): what Overture says when linking a reply MOVES the show off the address
// it pitched.
//
// `confirmDetail` was written for a contact with no address at all: "Linking this saves <address> on the
// contact." On an emailed pitch, confirming agrees to something larger. It replaces the address Dan
// pitched, and it replaces the conversation Overture sent on, and neither was named. What Dan approves
// has to be exactly what happens, including who it reaches (L64).
//
// The row's own account had the same gap, in the shape #2806 already fixed once: the more completely the
// attach succeeded, the less the row said. `attachWroteAddress` is FALSE on a replacing attach (that flag
// means the attach filled an EMPTY address), so both attached states fell through to the silent branch
// and said nothing at all about the move.
@Suite("What linking says when it moves the show onto somebody else (#3711)")
struct LinkingSaysWhoItMovesTheShowToTests {

    private let pitched = "producer@presenter.example"
    private let writer = "performer@theirown.example"

    // MARK: before the click

    @Test("the confirm line names the address the pitch went to as well as the new one")
    func theConfirmLineNamesBothAddresses() {
        let line = ProposedConversationCopy.confirmDetail(address: writer, replacing: pitched)

        #expect(line.contains(pitched), "the address being displaced")
        #expect(line.contains(writer), "the address being adopted")
    }

    // Dan asked for this specifically, so it is what he will look for: the pitched address is kept rather
    // than dropped.
    // Both surfaces say the displaced address survives, because Dan asked for that specifically, so it is
    // what he will look for. They say it in DIFFERENT words on purpose: see below.
    @Test("it says the displaced address is kept")
    func itSaysTheDisplacedAddressIsKept() {
        #expect(ProposedConversationCopy.confirmDetail(address: writer, replacing: pitched)
            .contains("The address it replaces is kept on the contact."))
    }

    // `confirmDetail` renders only inside `ProposedConversation.State.proposed`, which `isAskable` reaches
    // only on a pitch with `formOutreachRecordedAt`. A form pitch went to a FORM, and an address Prep
    // found for that contact is not one Dan pitched to, so "the address you pitched" would be a claim
    // about something that did not happen.
    @Test("the row never calls a found address one he pitched to")
    func theRowNeverCallsAFoundAddressOneHePitchedTo() {
        let line = ProposedConversationCopy.confirmDetail(address: writer, replacing: pitched)

        #expect(!line.contains("This pitch went to"))
    }

    // The mirror, in the picker, which the inline control opens on exactly the same form pitch. Only the
    // menu route (a real send) is entitled to the pitched wording.
    @Test("the picker only says a pitch went somewhere where one did")
    func thePickerOnlySaysAPitchWentSomewhereWhereOneDid() {
        let form = ProposedConversationCopy.pickWhatLinkingDoes(replacing: pitched,
                                                                alsoMovesTheConversation: false)
        let emailed = ProposedConversationCopy.pickWhatLinkingDoes(replacing: pitched,
                                                                   alsoMovesTheConversation: true)

        #expect(!form.contains("This pitch went to"))
        #expect(emailed.contains("This pitch went to \(pitched)"))
        #expect(emailed.contains("The address it replaces is kept on the contact."))
    }

    // MARK: the reply panel

    // "Overture didn't email them" is what the panel has said since #2715, and it is true of the form
    // pitch it was written for. On #3706's row Overture DID email, at the address the link displaced, so
    // the sentence reads as a denial of a pitch Dan certainly sent.
    @Test("the panel says who Overture emailed when it was not this thread")
    func thePanelSaysWhoOvertureEmailed() {
        let line = AttachConversationWriteCopy.linkedByHandAfterEmailing(pitched)

        #expect(line.contains(pitched))
        #expect(!line.contains("didn't email"))
    }

    // MARK: the picker, which shows several at once

    // The picker draws a LIST, so a sentence per row whose first half is a fact about the contact is the
    // same words repeated down the screen (L579). It is said once, above the list, and each row's own
    // sender line names who linking it would move to (L605).
    @Test("the picker says what linking does once, not once per candidate")
    func thePickerSaysItOnce() {
        let picker = SourceGuardHelper.source("Overture/UI/LinkReplyPicker.swift")
        let row = try! #require(SourceGuardHelper.bodyOfFunction(named: "row", in: picker))

        #expect(SourceGuardHelper.containsCode(
            "pickWhatLinkingDoes( replacing: recipient.email, alsoMovesTheConversation: recipient.hasWatchableConversation)",
            in: picker))
        #expect(!SourceGuardHelper.containsCode("confirmDetail", in: row),
                "a per-candidate approval line is what makes the wall")
    }

    // One vocabulary across the two compositions, so the picker and the row do not describe one act in
    // two sets of words (L605).
    @Test("the picker and the row describe the move the same way")
    func thePickerAndTheRowAgree() {
        let picker = ProposedConversationCopy.pickWhatLinkingDoes(replacing: pitched,
                                                                  alsoMovesTheConversation: true)

        #expect(picker.contains(pitched))
        #expect(picker.contains("instead of the one it emailed"))
        #expect(picker.contains("The address it replaces is kept on the contact."))
        #expect(ProposedConversationCopy.confirmDetail(address: writer, replacing: pitched)
            .contains("The address it replaces is kept on the contact."),
                "one fact, one wording, wherever it is shown")
        #expect(ProposedConversationCopy.confirmDetail(address: writer, replacing: pitched)
            .contains("moves the contact from \(pitched) to \(writer)"),
                "and both open on the move itself, in the same words")
    }

    // The branch a form pitch with a Prep-found address reaches: the address moves and no conversation
    // does, because Overture has never emailed this contact and is watching nothing. A promise to watch
    // this one "instead of the one it emailed" would describe something that never happened (#1547: read
    // the section in every branch it renders, not only the one in front of you).
    @Test("the picker claims no displaced conversation where there was none")
    func thePickerClaimsNoDisplacedConversationWhereThereWasNone() {
        let line = ProposedConversationCopy.pickWhatLinkingDoes(replacing: pitched,
                                                                 alsoMovesTheConversation: false)

        #expect(line.contains("moves the contact from \(pitched)"))
        #expect(!line.contains("instead of the one it emailed"))
    }

    @Test("a pitch with no address gets the sentence it always got, hoisted")
    func thePickerIsUnchangedForAPitchWithNoAddress() {
        let line = ProposedConversationCopy.pickWhatLinkingDoes(replacing: nil)

        #expect(line.contains("saves the writer's address on the contact"))
        #expect(!line.contains("This pitch went to"))
        #expect(line == ProposedConversationCopy.pickWhatLinkingDoes(replacing: "  "))
    }

    // The form pitch this sentence was written for, unchanged. A contact with no address is not being
    // moved off anything, and a sentence about a displaced address would name a fact that does not exist.
    @Test("a contact with no address still gets the sentence it always got")
    func aContactWithNoAddressIsUnchanged() {
        let line = ProposedConversationCopy.confirmDetail(address: writer, replacing: nil)

        #expect(line.hasPrefix("Linking this saves \(writer) on the contact."))
        #expect(!line.contains("This pitch went to"))
        #expect(line == ProposedConversationCopy.confirmDetail(address: writer, replacing: "   "),
                "whitespace is not an address either")
    }

    // The branch nobody would look at from inside the emailed case: a FORM pitch whose address Prep
    // already found. The address moves and no conversation does, because Overture has never emailed this
    // contact and is watching nothing, so a promise to watch this one "instead of the one it emailed"
    // would describe a thing that never happened (#1547: read the section in every branch it renders).
    @Test("it claims no displaced conversation, because it cannot be shown on one")
    func itClaimsNoDisplacedConversation() {
        let line = ProposedConversationCopy.confirmDetail(address: writer, replacing: pitched)

        #expect(line.contains("moves the contact from \(pitched) to \(writer)"))
        #expect(!line.contains("instead of the one it emailed"),
                "both call sites render `.proposed`, which `isAskable` reaches only with no conversation")
    }

    // The commonest attach of all: the person who wrote back IS the contact. Nothing moves, so claiming a
    // move would be Overture describing a change it is not about to make.
    @Test("it claims no move when the writer is already the contact")
    func itClaimsNoMoveWhenTheWriterIsTheContact() {
        let line = ProposedConversationCopy.confirmDetail(address: writer, replacing: writer.uppercased())

        #expect(!line.contains("This pitch went to"))
    }

    // MARK: after it

    @Test("the row says where email goes now, before he has answered")
    func theWaitingRowSaysWhereEmailGoesNow() {
        let line = ProposedConversationCopy.attachedAwaitingAnswer(wroteAddress: false, address: writer,
                                                                   displaced: pitched)

        #expect(line.hasPrefix("You linked their reply. It's waiting on you."))
        #expect(line.contains(writer))
        #expect(line.contains(pitched))
    }

    @Test("and after he has answered")
    func theAnsweredRowSaysWhereEmailGoesNow() {
        let line = ProposedConversationCopy.linkedAndAnswered(wroteAddress: false, address: writer,
                                                              displaced: pitched)

        #expect(line.hasPrefix("Their reply is here and you've already answered it."))
        #expect(line.contains(writer))
        #expect(line.contains(pitched))
    }

    // One vocabulary for one fact across the two states, rather than each describing the move in its own
    // words. The whole page is what a person reads, and one fact told two ways is two facts to them
    // (L605).
    @Test("both states describe the move in the same words")
    func bothStatesUseOneVocabulary() {
        let waiting = ProposedConversationCopy.attachedAwaitingAnswer(wroteAddress: false, address: writer,
                                                                      displaced: pitched)
        let answered = ProposedConversationCopy.linkedAndAnswered(wroteAddress: false, address: writer,
                                                                   displaced: pitched)
        let clause = "Email goes to \(writer) from now on, not \(pitched)."

        #expect(waiting.hasSuffix(clause))
        #expect(answered.hasSuffix(clause))
    }

    // #2806's own rule, unbroken: the row says something about the address only when there is something
    // to say. An attach that changed nobody's address gets the bare account.
    @Test("neither state invents an address sentence when nothing moved")
    func neitherInventsAnAddressSentence() {
        #expect(ProposedConversationCopy.attachedAwaitingAnswer(wroteAddress: false, address: writer,
                                                                displaced: nil)
                == "You linked their reply. It's waiting on you.")
        #expect(ProposedConversationCopy.linkedAndAnswered(wroteAddress: false, address: writer,
                                                           displaced: nil)
                == "Their reply is here and you've already answered it.")
    }

    // #2719's arm, which fills an EMPTY address, still says its own smaller thing.
    @Test("filling an empty address still reads as filling one")
    func fillingAnEmptyAddressIsUnchanged() {
        #expect(ProposedConversationCopy.linkedAndAnswered(wroteAddress: true, address: writer)
                == "Their reply is here and you've already answered it. Email goes to \(writer) from now on.")
    }

    // A sentence is only true if the facts reach it. Every surface that draws one of these has the
    // recipient in hand, and a call site that keeps passing the old argument list would render the old
    // claim while every test above passed (L27).
    @Test("every surface passes the address the pitch went to")
    func everySurfacePassesTheDisplacedAddress() {
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let followUps = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")

        #expect(SourceGuardHelper.containsCode(
            "confirmDetail(address: candidate.fromAddress, replacing: r.email)",
            in: queue))
        #expect(SourceGuardHelper.containsCode(
            "confirmDetail(address: candidate.fromAddress, replacing: d.recipient.email)",
            in: followUps))
        #expect(SourceGuardHelper.containsCode("displaced: r.attachDisplacedEmail", in: queue))
    }
}
