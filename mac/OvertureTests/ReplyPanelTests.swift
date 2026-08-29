import Testing
import Foundation
import SwiftData

// #2128: answering a reply from the Reached out queue. Dan (2026-08-05): "The reply itself should be
// done in the reached out queue. I'm never going to archive unless I need to look at something in the
// past." And: "I'll respond to whatever it is they say, usually by hand."
//
// Everything the panel decides lives here, in pure types, because the panel itself is SwiftUI and a
// decision made inside it is a decision no test can reach.
@MainActor
@Suite("The reply panel")
struct ReplyPanelTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Pumpkin Singalong", discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ address: String, group: String? = "g") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sendGroupId = group
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        r.gmailThreadId = "t"
        p.setRecipients(p.recipients + [r])
        return r
    }

    // MARK: what the panel is allowed to send

    // Dan types the words himself, so there is nothing to send until he has typed some.
    @Test func nothingSendsUntilSomethingIsTyped() {
        #expect(!ReplyPanel.canSend(body: "", subject: nil, audience: ["a@x.org"], gmailConnected: true, writer: nil))
        #expect(!ReplyPanel.canSend(body: "   \n  ", subject: nil, audience: ["a@x.org"], gmailConnected: true, writer: nil))
        #expect(ReplyPanel.canSend(body: "Sounds good.", subject: nil, audience: ["a@x.org"], gmailConnected: true, writer: nil))
    }

    // An audience of nobody means the send has no destination, so the button must refuse rather than
    // fail at the network and report it as an error Dan cannot act on.
    @Test func nothingSendsWithNobodyToSendTo() {
        #expect(!ReplyPanel.canSend(body: "Sounds good.", subject: nil, audience: [], gmailConnected: true, writer: nil))
    }

    @Test func nothingSendsWhileGmailIsDisconnected() {
        #expect(!ReplyPanel.canSend(body: "Sounds good.", subject: nil, audience: ["a@x.org"], gmailConnected: false, writer: nil))
    }

    // MARK: why the send is refused (#2152)

    // The refusal and the disabled button are ONE decision, asked once. A second predicate deciding what
    // to say could agree with the button today and drift from it tomorrow, and the drift would show as a
    // dead button beside a sentence claiming everything is fine (L16, L70).
    @Test func theDisabledButtonAndTheStatedReasonAreTheSameDecision() {
        let bodies = ["", "   ", "Tuesday works."]
        let audiences: [[String]] = [[], ["chelsea@everyvoicechoirs.org"],
                                     ["chelsea@everyvoicechoirs.org", "nicolebecker@everyvoicechoirs.org"]]
        let writers: [String?] = [nil, "", "nicolebecker@everyvoicechoirs.org"]
        for body in bodies {
            for audience in audiences {
                for connected in [true, false] {
                    for writer in writers {
                        let refusal = ReplyPanel.refusal(body: body, subject: nil, audience: audience,
                                                         gmailConnected: connected, writer: writer)
                        let can = ReplyPanel.canSend(body: body, subject: nil, audience: audience,
                                                     gmailConnected: connected, writer: writer)
                        #expect(can == (refusal == nil),
                                "body \(body.debugDescription), audience \(audience), connected \(connected), writer \(writer.debugDescription)")
                    }
                }
            }
        }
    }

    // Dan's real case: Nicole wrote from an address he never pitched, so #2147 refuses the send. Without
    // this he sees a dead Send button on a plainly live conversation and cannot tell a refusal from a bug.
    // The line names BOTH sides, because the mismatch between them is the whole reason (L11).
    @Test func theReasonNamesWhoWroteAndWhoTheReplyWouldReach() throws {
        let refusal = ReplyPanel.refusal(body: "Tuesday works.", subject: nil,
                                         audience: ["nbecker@everyvoicechoirs.org"],
                                         gmailConnected: true,
                                         writer: "nicolebecker@everyvoicechoirs.org")
        #expect(refusal == .writerNotReached(writer: "nicolebecker@everyvoicechoirs.org",
                                             audience: ["nbecker@everyvoicechoirs.org"]))
        let line = try #require(ReplyPanelCopy.refusalLine(refusal))
        #expect(line.contains("nicolebecker@everyvoicechoirs.org"))
        #expect(line.contains("nbecker@everyvoicechoirs.org"))
    }

    // Every address the answer would reach is named, not just the first, so Dan can see the whole
    // mismatch rather than a sample of it.
    @Test func theReasonNamesEveryAddressTheReplyWouldReach() {
        let line = ReplyPanelCopy.refusalLine(
            ReplyPanel.refusal(body: "Tuesday works.", subject: nil,
                               audience: ["chelsea@everyvoicechoirs.org", "ray@elsewhere.example"],
                               gmailConnected: true,
                               writer: "nicolebecker@everyvoicechoirs.org"))
        #expect(line?.contains("chelsea@everyvoicechoirs.org") == true)
        #expect(line?.contains("ray@elsewhere.example") == true)
    }

    // A disconnected Gmail said itself only in a tooltip, which is invisible at rest (L49). It is the one
    // refusal with a plain next step, so it belongs on screen beside the button too.
    @Test func aDisconnectedGmailSaysSoOnScreenRatherThanOnlyOnHover() {
        let refusal = ReplyPanel.refusal(body: "Tuesday works.", subject: nil, audience: ["a@x.org"],
                                         gmailConnected: false, writer: nil)
        #expect(refusal == .gmailDisconnected)
        #expect(ReplyPanelCopy.refusalLine(refusal) == GmailCopy.notConnected)
    }

    // Nothing typed is not explained, deliberately: Dan is looking straight at his own empty box, and a
    // sentence telling him it is empty is the restatement #843 was about.
    @Test func anEmptyBoxIsNotExplainedBackToHim() {
        let refusal = ReplyPanel.refusal(body: "  ", subject: nil, audience: ["a@x.org"],
                                         gmailConnected: true, writer: nil)
        #expect(refusal == .nothingTyped)
        #expect(ReplyPanelCopy.refusalLine(refusal) == nil)
    }

    // Nor is an empty audience, because the header two lines above already says "No address to reply to"
    // in the same panel. Saying it twice is the other half of #843.
    @Test func anEmptyAudienceIsNotRestatedBesideTheButton() {
        let refusal = ReplyPanel.refusal(body: "Tuesday works.", subject: nil, audience: [],
                                         gmailConnected: true, writer: nil)
        #expect(refusal == .noAudience)
        #expect(ReplyPanelCopy.refusalLine(refusal) == nil)
        #expect(ReplyPanelCopy.noAddress == "No address to reply to")
    }

    // And a send that CAN go says nothing at all, so the line cannot become permanent furniture that
    // stops meaning anything.
    @Test func aSendableReplyCarriesNoRefusalLine() {
        let refusal = ReplyPanel.refusal(body: "Tuesday works.", subject: nil,
                                         audience: ["nicolebecker@everyvoicechoirs.org"],
                                         gmailConnected: true,
                                         writer: "nicolebecker@everyvoicechoirs.org")
        #expect(refusal == nil)
        #expect(ReplyPanelCopy.refusalLine(refusal) == nil)
    }

    // The mismatch outranks the empty box: with both true, the line Dan needs is the one he cannot work
    // out for himself.
    @Test func theWriterMismatchIsStatedEvenBeforeHeHasTyped() {
        let refusal = ReplyPanel.refusal(body: "", subject: nil, audience: ["chelsea@everyvoicechoirs.org"],
                                         gmailConnected: true,
                                         writer: "nicolebecker@everyvoicechoirs.org")
        #expect(refusal == .writerNotReached(writer: "nicolebecker@everyvoicechoirs.org",
                                             audience: ["chelsea@everyvoicechoirs.org"]))
    }

    // MARK: who wrote, and taking somebody off the reply (#2155)

    // Dan, looking at the live Pumpkin Singalong panel: "it's also not clear which email sent the message
    // I'm reading". Three addresses, one flat sentence, and the surface the send is approved from said
    // less about who he was answering than the row he opened it from.
    @Test func theAddressThatWroteIsMarkedAmongTheOthers() {
        let entries = ReplyPanel.audienceEntries(["nicolebecker@everyvoicechoirs.org",
                                                  "chelsea@everyvoicechoirs.org",
                                                  "nbecker@everyvoicechoirs.org"],
                                                 writer: "nicolebecker@everyvoicechoirs.org")
        #expect(entries.map(\.address) == ["nicolebecker@everyvoicechoirs.org",
                                           "chelsea@everyvoicechoirs.org",
                                           "nbecker@everyvoicechoirs.org"])
        #expect(entries.filter(\.wrote).map(\.address) == ["nicolebecker@everyvoicechoirs.org"])
    }

    // Matched the way reply detection matches, so a difference in casing cannot silently unmark the one
    // person the panel exists to identify.
    @Test func theWriterIsMarkedEvenWhenTheStoredSpellingDiffersInCase() {
        let entries = ReplyPanel.audienceEntries(["nicolebecker@everyvoicechoirs.org"],
                                                 writer: "NicoleBecker@EveryVoiceChoirs.org")
        #expect(entries.first?.wrote == true)
    }

    // A row with nothing recorded about who wrote marks nobody, rather than guessing at the first address
    // and telling Dan somebody wrote who may not have.
    @Test func anUnknownWriterMarksNobody() {
        let entries = ReplyPanel.audienceEntries(["a@x.org", "b@x.org"], writer: nil)
        #expect(entries.map(\.wrote) == [false, false])
    }

    // "if she changed it from nbecker to nicolebecker, she clearly wants that one. So I should be able to
    // remove the other one." Every address can come off, including the writer's: removing the writer is a
    // refusal to send, which the panel already states, not something to forbid at the control.
    @Test func anyAddressCanBeTakenOffWhileMoreThanOneRemains() {
        let entries = ReplyPanel.audienceEntries(["nicolebecker@everyvoicechoirs.org",
                                                  "nbecker@everyvoicechoirs.org"],
                                                 writer: "nicolebecker@everyvoicechoirs.org")
        #expect(entries.map(\.canRemove) == [true, true])
    }

    // The last one cannot, because an empty audience does not mean "send to nobody": SendGroup falls back
    // to the contact's own address, which would quietly deliver the reply to somebody Dan just removed
    // (L75). The control is absent rather than present and failing.
    @Test func theLastAddressCannotBeTakenOff() {
        let entries = ReplyPanel.audienceEntries(["nbecker@everyvoicechoirs.org"], writer: nil)
        #expect(entries.count == 1)
        #expect(entries[0].canRemove == false)
    }

    @Test func removingAnAddressLeavesTheRestInOrder() {
        let left = ReplyPanel.removing("nbecker@everyvoicechoirs.org",
                                       from: ["nicolebecker@everyvoicechoirs.org",
                                              "chelsea@everyvoicechoirs.org",
                                              "nbecker@everyvoicechoirs.org"])
        #expect(left == ["nicolebecker@everyvoicechoirs.org", "chelsea@everyvoicechoirs.org"])
    }

    // Same comparison as the marking above, so an address written one way in the thread and another way
    // on the contact cannot survive a removal Dan believes he performed.
    @Test func removingIgnoresCasing() {
        let left = ReplyPanel.removing("NBecker@EveryVoiceChoirs.org",
                                       from: ["nicolebecker@everyvoicechoirs.org",
                                              "nbecker@everyvoicechoirs.org"])
        #expect(left == ["nicolebecker@everyvoicechoirs.org"])
    }

    // Removing the last address is refused by the same rule the control is hidden by, so a caller that
    // reaches this another way cannot empty the audience either.
    @Test func removingTheLastAddressIsRefused() {
        #expect(ReplyPanel.removing("only@x.org", from: ["only@x.org"]) == ["only@x.org"])
    }

    // Dan's call on how far a removal reaches (2026-08-05): "drop it entirely. just like it would in a
    // real email client. if they want to add it back they can." So it comes off the reply AND the show
    // stops using that contact, through the same removeOrSuppressRecipient the card's own Remove uses.
    // An already-emailed contact is suppressed rather than deleted there, so nothing about the pitch it
    // received is lost and re-adding the address resumes it.
    @Test func takingAContactOffTheReplyAlsoStopsTheShowUsingThem() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] { r.replied = true; r.replyFromAddress = "nicolebecker@everyvoicechoirs.org" }
        nicole.replyAudience = ["nicolebecker@everyvoicechoirs.org",
                                "chelsea@everyvoicechoirs.org",
                                "nbecker@everyvoicechoirs.org"]

        #expect(ReplyPanel.removeFromReply("chelsea@everyvoicechoirs.org", on: nicole, of: p)
                == .fromReplyAndShow)

        // Off this reply, and the SEND reads the same narrowed list, so what Dan approved is what goes.
        #expect(SendGroup.replyAudience(of: nicole) == ["nicolebecker@everyvoicechoirs.org",
                                                        "nbecker@everyvoicechoirs.org"])
        // And off the show, without losing that she was pitched.
        #expect(chelsea.sendState == .suppressed)
        #expect(chelsea.suppressionReason == .removedByDan)
        #expect(p.recipients.contains { $0.id == chelsea.id }, "an emailed contact is suppressed, never deleted")
    }

    // The writer's own address is on no contact of this show, which is the whole reason this panel needed
    // fixing. Removing it narrows the reply and touches no contact record at all.
    @Test func takingOffAnAddressThatIsNobodysContactJustNarrowsTheReply() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        nicole.replied = true
        nicole.replyFromAddress = "nicolebecker@everyvoicechoirs.org"
        nicole.replyAudience = ["nicolebecker@everyvoicechoirs.org", "nbecker@everyvoicechoirs.org"]

        #expect(ReplyPanel.removeFromReply("nicolebecker@everyvoicechoirs.org", on: nicole, of: p)
                == .fromReply)
        #expect(SendGroup.replyAudience(of: nicole) == ["nbecker@everyvoicechoirs.org"])
        #expect(nicole.sendState == .sent, "no contact holds that address, so no contact changes")
    }

    // #2155 follow-up: the removal has to SAY what it did, because its two outcomes differ in a way Dan
    // cannot see. Taking off an address that is nobody's contact changes this reply alone; taking off a
    // contact also stops the show emailing them, and a banner claiming the wider effect on the narrower
    // action would be a claim its own check never measured (L11).
    @Test func eachOutcomeOfARemovalGetsItsOwnSentence() {
        let onlyReply = ReplyPanelCopy.removed(.fromReply, address: "nicolebecker@everyvoicechoirs.org")
        let alsoShow = ReplyPanelCopy.removed(.fromReplyAndShow, address: "chelsea@everyvoicechoirs.org")
        #expect(onlyReply != nil)
        #expect(alsoShow != nil)
        #expect(onlyReply != alsoShow, "both outcomes cannot report the same thing happened")
        #expect(onlyReply?.contains("nicolebecker@everyvoicechoirs.org") == true)
        #expect(alsoShow?.contains("chelsea@everyvoicechoirs.org") == true)
        // Only the wider one may claim the show stopped emailing them.
        #expect(alsoShow?.localizedCaseInsensitiveContains("won't email") == true)
        #expect(onlyReply?.localizedCaseInsensitiveContains("won't email") == false)
        // And a refused removal announces nothing at all, rather than a banner over a no-op (L12).
        #expect(ReplyPanelCopy.removed(.notRemoved, address: "only@x.org") == nil)
    }

    // Nothing is emptied. The audience falling back to the contact's own address would deliver the reply
    // to somebody Dan had just taken off it, which looks exactly like success (L75).
    @Test func theLastAddressSurvivesEvenIfSomethingAsksToRemoveIt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        nicole.replied = true
        nicole.replyAudience = ["nbecker@everyvoicechoirs.org"]

        #expect(ReplyPanel.removeFromReply("nbecker@everyvoicechoirs.org", on: nicole, of: p) == .notRemoved)
        #expect(SendGroup.replyAudience(of: nicole) == ["nbecker@everyvoicechoirs.org"])
        #expect(nicole.sendState == .sent, "a refused removal must not half-happen on the contact")
    }

    // MARK: an address that is on no contact of this show (#2151)

    // Measured on the live store: Dan pitched nbecker@ and chelsea@, and Nicole answered from
    // nicolebecker@. Nothing said the address was new, so she stayed a stranger to this show and every
    // future reply from her would be handled the same way again.
    @Test func anAddressOnNoContactOfThisShowIsOfferedForSaving() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        nicole.replied = true
        nicole.replyFromAddress = "nicolebecker@everyvoicechoirs.org"

        #expect(ReplyPanel.unknownWriter(on: nicole, of: p) == "nicolebecker@everyvoicechoirs.org")
    }

    // The ordinary case, and the one that must stay quiet: the person who wrote is somebody Dan pitched,
    // so there is nothing new to tell him and no offer to make.
    @Test func aWriterWhoIsAlreadyAContactIsNotOffered() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        nicole.replied = true
        nicole.replyFromAddress = "NBecker@EveryVoiceChoirs.org"   // same address, different spelling
        #expect(ReplyPanel.unknownWriter(on: nicole, of: p) == nil)
    }

    // Nothing recorded about who wrote is not an unknown address, it is an unknown fact. Offering to save
    // something Overture cannot name would be an offer with no subject.
    @Test func aRowWithNoRecordedWriterOffersNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org")
        r.replied = true
        #expect(ReplyPanel.unknownWriter(on: r, of: p) == nil)
    }

    // Saving her puts her ON the show as a peer of the conversation, which is the whole point: from then
    // on a reply from that address resolves to HER row rather than to whichever contact sorts first.
    @Test func savingTheWriterMakesHerRecognisedNextTime() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nbecker = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nbecker] {
            r.replied = true
            r.replyFromAddress = "nicolebecker@everyvoicechoirs.org"
        }
        nbecker.replyFromName = "Nicole Becker"

        #expect(ReplyPanel.saveWriterAsContact(on: nbecker, of: p))

        let saved = try #require(p.recipients.first { $0.id == "nicolebecker@everyvoicechoirs.org" })
        #expect(saved.name == "Nicole Becker", "the name from her reply is what makes the row readable")
        #expect(saved.sendGroupId == nbecker.sendGroupId, "she has to be a peer, or nothing resolves to her")
        // The point of the whole issue: she is no longer a stranger.
        #expect(ReplyIdentity.answering(for: chelsea, in: p).id == saved.id)
    }

    // And she must NEVER be cold-pitched. She is the person already in this conversation, so a contact
    // that could be picked up by the ordinary send path would put a first-contact pitch in front of
    // somebody mid-conversation. Suppressed with its own reason, distinct from Dan removing somebody and
    // from a real decline, so nothing reads her as either.
    @Test func theSavedWriterIsNeverPitched() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let nbecker = contact(p, "nbecker@everyvoicechoirs.org")
        nbecker.replied = true
        nbecker.replyFromAddress = "nicolebecker@everyvoicechoirs.org"

        #expect(ReplyPanel.saveWriterAsContact(on: nbecker, of: p))
        let saved = try #require(p.recipients.first { $0.id == "nicolebecker@everyvoicechoirs.org" })
        #expect(saved.isSendablePending == false, "a pitch must never go to somebody already replying")
        #expect(saved.sendState == .suppressed)
        #expect(saved.suppressionReason == .joinedFromReply)
        #expect(saved.resolution == nil, "she has not declined anything")
        // Resuming the show's paused contacts after triage must not turn her into a pitch target either.
        p.resumePausedRecipients()
        #expect(saved.isSendablePending == false)
    }

    // Asked twice, saved once. The offer disappears the moment she is on the show, and a second call
    // cannot mint a duplicate contact carrying the same address.
    @Test func savingHerTwiceIsSavingHerOnce() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let nbecker = contact(p, "nbecker@everyvoicechoirs.org")
        nbecker.replied = true
        nbecker.replyFromAddress = "nicolebecker@everyvoicechoirs.org"

        #expect(ReplyPanel.saveWriterAsContact(on: nbecker, of: p))
        #expect(ReplyPanel.saveWriterAsContact(on: nbecker, of: p) == false)
        #expect(p.recipients.filter { $0.id == "nicolebecker@everyvoicechoirs.org" }.count == 1)
        #expect(ReplyPanel.unknownWriter(on: nbecker, of: p) == nil, "the offer is gone once it is done")
    }

    // What the panel says about it. The sentence states the fact and the offer names the address, because
    // saving an address Dan cannot see is a decision he cannot make.
    @Test func theOfferNamesTheAddressItWouldSave() {
        let line = ReplyPanelCopy.writerNotAContact("nicolebecker@everyvoicechoirs.org")
        #expect(line.contains("nicolebecker@everyvoicechoirs.org"))
        #expect(ReplyPanelCopy.saveWriter.isEmpty == false)
        #expect(ReplyPanelCopy.savedWriter("nicolebecker@everyvoicechoirs.org")
                    .contains("nicolebecker@everyvoicechoirs.org"))
    }

    // MARK: the audience Dan approves

    // L64: what he reviews has to include WHO it goes to. The panel lists every address outright rather
    // than only naming the extras, because it is the approval surface for the send.
    @Test func everyAddressTheReplyReachesIsListed() {
        let entries = ReplyPanel.audienceEntries(["nbecker@everyvoicechoirs.org",
                                                  "ray@elsewhere.example"], writer: nil)
        #expect(entries.map(\.address) == ["nbecker@everyvoicechoirs.org", "ray@elsewhere.example"])
    }

    // A panel with nobody to write to says so, rather than showing a heading with nothing under it.
    @Test func anEmptyAudienceSaysSoRatherThanTrailingOff() {
        #expect(ReplyPanel.audienceEntries([], writer: nil).isEmpty)
        #expect(ReplyPanelCopy.noAddress == "No address to reply to")
    }

    // MARK: which contact the panel is about

    // The panel opens from a row that stands on the alphabetically first contact, but the reply, its
    // words and its audience all belong to whoever wrote. Everything the panel shows and sends must key
    // on that peer, or Dan answers Nicole and Overture emails Chelsea.
    @Test func thePanelIsAboutTheContactWhoWrote() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        }
        nicole.lastReplyText = "Thanks, that sounds good."
        nicole.replyAudience = ["nbecker@everyvoicechoirs.org"]

        let answering = ReplyIdentity.answering(for: chelsea, in: p)
        #expect(answering.id == nicole.id)
        #expect(ReplyPanel.theirWords(answering) == "Thanks, that sounds good.")
    }

    // Nothing was captured (a reply detected before the words were stored, or a reply-all somebody else
    // wrote). The panel says so plainly instead of showing an empty quote box.
    @Test func aReplyWithNoCapturedWordsSaysSo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "solo@example.org", group: nil)
        r.replied = true
        #expect(ReplyPanel.theirWords(r) == nil)
    }

    // MARK: which rows offer the panel at all

    // Only a row where somebody is actually waiting on an answer. A silent row's next email is a
    // follow-up, which is a different thing entirely and is not written in this panel.
    @Test func onlyARowAwaitingAnAnswerOffersOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let silent = contact(p, "silent@example.org", group: nil)
        #expect(!ReplyPanel.isOffered(for: silent, in: p))

        let wrote = contact(p, "wrote@example.org", group: nil)
        wrote.replied = true
        #expect(ReplyPanel.isOffered(for: wrote, in: p))
    }

    // A row standing on the contact who did NOT write still offers the panel, because the answer is owed
    // on that thread and this is the only row the list shows for it.
    //
    // The shape is measured, not invented: on a shared thread ReplyService marks EVERY peer replied and
    // records the writer on each, filing only the WORDS with whoever wrote. The live store agrees, both
    // rows of Dan's one real joint send carry 2026-08-04 20:56.
    @Test func aRowStandingOnTheColleagueWhoDidNotWriteStillOffersOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        }
        nicole.lastReplyText = "Thanks, that sounds good."
        #expect(ReplyPanel.isOffered(for: chelsea, in: p))
        #expect(ReplyIdentity.answering(for: chelsea, in: p).id == nicole.id)
    }

    // A contact already resolved is not waiting on anything, so the panel is not offered on their row.
    @Test func aResolvedContactIsNotOfferedOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "done@example.org", group: nil)
        r.replied = true
        r.resolution = .declinedHard
        #expect(!ReplyPanel.isOffered(for: r, in: p))
    }

    // MARK: what Dan approves before a reply goes (#2144)

    // The signature is composed onto the message at the send layer, so a panel that shows only Dan's typed
    // words is not showing the artifact that lands in the inbox. That gap shipped a white outline box to
    // every dark-mode recipient for two weeks (#2086). The confirmation carries the body and the signature
    // as INGREDIENTS, so the sheet renders them through the same helper the wire uses (L64).
    @Test func theConfirmationCarriesTheSignatureTheSendWillCompose() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]
        let sig = OutboundSignature(html: "<p>Dan Wright</p>", plainText: "Dan Wright")

        let c = try #require(SendConfirmation(replyFor: r, of: p, body: "Tuesday works.", signature: sig))
        #expect(c.bodyBeforeSignOff == "Tuesday works.")
        #expect(c.signature == sig)
        // The composed text/plain part is what the send hands Gmail, built the one way.
        #expect(c.body == GmailMessage.previewBody(body: "Tuesday works.", signature: sig))
        #expect(c.from == .danWright)
    }

    // The To line is the reply's audience, not the original email's, so what he approves names the people
    // the answer actually reaches.
    @Test func theConfirmationNamesEveryAddressTheReplyReaches() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyAudience = ["nicolebecker@everyvoicechoirs.org", "chelsea@everyvoicechoirs.org"]

        let c = try #require(SendConfirmation(replyFor: r, of: p, body: "Tuesday works."))
        #expect(c.recipient.contains("nicolebecker@everyvoicechoirs.org"))
        #expect(c.recipient.contains("chelsea@everyvoicechoirs.org"))
    }

    // The subject comes from the SAME place the sender takes it, so the line Dan reads on the sheet is the
    // line on the message. Two expressions of "what a reply is called" would drift silently.
    @Test func theConfirmationShowsTheSubjectTheSenderWillUse() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]
        r.replyDraftSubject = "Re: Photographing the Pumpkin Singalong"

        let c = try #require(SendConfirmation(replyFor: r, of: p, body: "Tuesday works."))
        #expect(c.subject == SendService.replySubject(for: r, of: p))
        #expect(c.subject == "Re: Photographing the Pumpkin Singalong")
    }

    // And with no subject stored on the reply it falls back to the same derived one the sender derives,
    // rather than an empty line the sheet would show as blank.
    @Test func aReplyWithNoStoredSubjectStillShowsTheOneThatWillGoOut() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]

        let c = try #require(SendConfirmation(replyFor: r, of: p, body: "Tuesday works."))
        #expect(c.subject == SendService.replySubject(for: r, of: p))
        #expect(c.subject.isEmpty == false)
    }

    // Nothing to confirm is nothing to send: no audience and no typed words each refuse to build a sheet,
    // so a confirmation can never stand for an email that could not go.
    @Test func thereIsNoConfirmationWithoutAnAudienceOrWords() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true

        r.replyAudience = []
        #expect(SendConfirmation(replyFor: r, of: p, body: "Tuesday works.") != nil,
                "an empty stored audience still falls back to the contact, which is a real destination")
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]
        #expect(SendConfirmation(replyFor: r, of: p, body: "   ") == nil)
    }

    // MARK: sending, and what survives a send that fails

    // The failure path Dan actually meets: Gmail refuses, and his words must not be lost. They are
    // written to the recipient BEFORE the send precisely so a failure leaves them stored, not living
    // only in a text box the panel is about to redraw (L5).
    @Test func aFailedSendKeepsTheWordsHeTyped() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true

        let sent = await ReplyPanel.commit(body: "Tuesday works, I will bring the 85mm.", on: r, of: p,
                                           now: Date(timeIntervalSince1970: 5_000), sender: AlwaysFailSender())
        #expect(sent == false, "a refused send must never report as sent")
        #expect(r.replyDraftBody == "Tuesday works, I will bring the 85mm.")
    }

    // And a send that works reports so, so the panel closes on a real send rather than a hopeful one.
    @Test func aSuccessfulSendReportsTrue() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]

        let sent = await ReplyPanel.commit(body: "Sounds good, see you then.", on: r, of: p,
                                           now: Date(timeIntervalSince1970: 5_000), sender: FakeReplySender())
        #expect(sent)
        // The send consumes the draft and freezes the committed copy, so the words Dan typed are what
        // went out and the box is not left holding a reply that has already gone.
        #expect(r.replyDraftBody == nil)
        #expect(r.sentReplyBody == "Sounds good, see you then.")
    }
}

private struct AlwaysFailSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
}

private struct FakeReplySender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t", messageID: "m-sent")
    }
}
