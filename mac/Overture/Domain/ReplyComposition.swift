import Foundation
import SwiftData

// #2145: what the shared reply screen is answering.
//
// The Reached out list renders scouted shows and hire inquiries together, and they answered replies
// through two separate implementations of one job. This is the seam between them: the screen renders,
// this says what it is rendering ABOUT, and each call site builds one.
//
// Anything LIVE arrives as a closure, deliberately. The AI drafter is detached and its result lands on
// the contact while the screen is open (#2143), so a copy captured when this value was built would go
// stale the moment the run came back, which is the exact defect #2143 shipped to fix. Values are used
// only for what genuinely cannot change while the screen is up (the title, an inquiry's notes).
//
// Every closure is @MainActor: they capture SwiftData models, the context and the feedback banner, none
// of which are Sendable, and this project builds with Swift 6 language mode.
@MainActor
struct ReplyComposition {
    let title: String
    // Context under the title that is not the message itself. An inquiry carries Dan's own note about
    // where the enquiry came from; a show has nothing to say here.
    let subtitle: String?
    // The contact whose thread is being answered. Held as the shared seam so the screen can ask it for
    // their words and how it was addressed without knowing which entity it belongs to.
    let contact: any ReplyWatchableRecipient
    // Nil when the entity has no subject to type, which is a different thing from an empty one: a show
    // answers into a Gmail thread that already has a subject.
    let editableSubject: String?
    let aiDraft: AIDraft?
    let audienceControls: AudienceControls?
    // What Dan is about to approve, and the send itself. Both take the body (and, for an entity that has
    // one, the subject) as they stand NOW, so what he approves cannot differ from what goes out (L64).
    // #2796: why this conversation cannot be continued at all, or nil when it can. A closure for the
    // same reason everything live here is one: the parent it looks for is written by reply detection,
    // which lands on the contact while this screen is open, so a value captured when the composition was
    // built would go on refusing after the reason had gone.
    //
    // It belongs to the COMPOSITION rather than to `ReplyPanel.refusal`, which is deliberately a pure
    // function over the body, the subject and the audience and knows nothing of entities. Each entity
    // names itself, which is what lets one sentence say WHICH conversation is meant (L80).
    let cannotContinue: @MainActor () -> String?
    let confirmation: @MainActor (_ body: String, _ subject: String?) -> SendConfirmation?
    let send: @MainActor (_ body: String, _ subject: String?) async -> Bool

    // Asked, never remembered: taking somebody off the reply has to show without rebuilding the screen.
    var audience: [String] { SendGroup.replyAudience(of: contact) }
    var writer: String? { contact.replyFromAddress }

    // The one refusal rule, asked with this composition's own subject. A show passes nil and can never be
    // refused for a subject; an inquiry passes what Dan typed (L16, one predicate both go through).
    func refusal(body: String, gmailConnected: Bool) -> ReplyPanel.SendRefusal? {
        // #2796: first, because it is the only one of these Dan can do nothing about from this screen.
        // Connecting Gmail, fixing the audience or typing something all leave it exactly where it was, so
        // reporting either of those instead would name a step that changes nothing (L111).
        if let reason = cannotContinue() { return .cannotContinue(reason) }
        return ReplyPanel.refusal(body: body, subject: editableSubject, audience: audience,
                                  gmailConnected: gmailConnected, writer: writer)
    }

    // The drafter, for an entity that has one. An inquiry has no draft fields at all, so it passes nil
    // and the screen offers no AI control rather than one that could not work.
    struct AIDraft {
        let current: @MainActor () -> String?
        let isRunning: @MainActor () -> Bool
        let requestedAt: @MainActor () -> Date?
        let request: @MainActor () -> Void
        // #2177: whether the draft sitting here is Dan's own work rather than the drafter's. Closures for
        // the same reason everything live here is one: he can write or edit while the screen is open, and a
        // value captured when the composition was built would go on calling his words the model's. The two
        // states are kept apart rather than folded into one flag because they are the Archive card's own
        // two ("Written by you", "Edited"), and folding them here would make this the second place the app
        // decides what those mean.
        let writtenByDan: @MainActor () -> Bool
        let editedByDan: @MainActor () -> Bool
    }

    // Taking an address off the reply, and saving an address that wrote but is on no contact. Both mean
    // something specific to a show's contact list and nothing to an inquiry, which is one person.
    struct AudienceControls {
        let remove: @MainActor (String) -> Void
        let unknownWriter: @MainActor () -> String?
        let saveWriter: @MainActor () -> Void
    }
}

extension ReplyComposition {
    // #2145: a hire inquiry's reply. An inquiry is its own single watched thread, so it is both the entity
    // and its own contact, which is why it can hand ITSELF to the screen as the contact.
    //
    // No drafter and no audience controls, and both absent rather than inert: an inquiry has no reply
    // draft fields at all, and it is one person, so "take this address off and stop emailing it" has
    // nothing to mean.
    static func answering(_ inquiry: Inquiry, context: ModelContext, feedback: ActionFeedback,
                          sender: MailSender = ProspectMutations.liveSender()) -> ReplyComposition {
        ReplyComposition(
            title: InquiryCopy.replyTitle(to: inquiry.inquirerName),
            subtitle: inquiry.notes,
            contact: inquiry,
            editableSubject: InquiryCopy.replySubjectDefault,
            aiDraft: nil,
            audienceControls: nil,
            // #2796: an inquiry names itself, so the sentence says which conversation is meant.
            cannotContinue: {
                AttachedConversation.refusalToContinue(inquiry,
                                                       displayName: inquiry.replyWatchDisplayName)
            },
            confirmation: { body, subject in
                // The subject he TYPED, never the default it started at, or the sheet would show one
                // subject while another shipped (L64).
                SendConfirmation(replyTo: SendGroup.replyAudience(of: inquiry),
                                 subject: subject ?? InquiryCopy.replySubjectDefault, body: body)
            },
            send: { body, subject in
                // What to do next is decided in InquiryMutations (tested, including the sent-but-not-saved
                // path), exactly as it was before this screen was shared.
                switch await InquiryMutations.sendReply(inquiry,
                                                        subject: subject ?? InquiryCopy.replySubjectDefault,
                                                        body: body, now: Date(), sender: sender,
                                                        context: context, feedback: feedback) {
                case .sent: return true
                case .sendFailed: return false
                }
            })
    }

    // A scouted show's reply. `recipient` is the peer who actually WROTE, resolved by the caller through
    // ReplyIdentity.answering: the row the list stands on is picked by sorted id and is routinely
    // somebody else.
    static func answering(_ recipient: Recipient, of prospect: Prospect,
                          context: ModelContext, feedback: ActionFeedback,
                          sender: MailSender = ProspectMutations.liveSender()) -> ReplyComposition {
        ReplyComposition(
            title: prospect.groupName,
            subtitle: nil,
            contact: recipient,
            editableSubject: nil,
            aiDraft: AIDraft(
                current: { recipient.replyDraftBody },
                isRunning: { ReplyPanel.isDrafting(recipient) },
                requestedAt: { recipient.replyDraftRequestedAt },
                request: {
                    ProspectMutations.draftOneReply(prospect.naturalKey, recipient.id,
                                                    prospects: [prospect], context: context,
                                                    feedback: feedback)
                },
                writtenByDan: { recipient.replyDraftWrittenByDan },
                editedByDan: { recipient.replyDraftEditedByDan }),
            audienceControls: AudienceControls(
                remove: { address in
                    let removal = ReplyPanel.removeFromReply(address, on: recipient, of: prospect)
                    guard let said = ReplyPanelCopy.removed(removal, address: address) else { return }
                    // Announced only once the write COMMITS, so the banner is never shown over a removal
                    // that did not persist (L12).
                    guard context.saveOrWarn(org: prospect.groupName, feedback: feedback) else { return }
                    feedback.acknowledge(said)
                },
                unknownWriter: { ReplyPanel.unknownWriter(on: recipient, of: prospect) },
                saveWriter: {
                    guard let address = ReplyPanel.unknownWriter(on: recipient, of: prospect) else { return }
                    guard ReplyPanel.saveWriterAsContact(on: recipient, of: prospect) else { return }
                    guard context.saveOrWarn(org: prospect.groupName, feedback: feedback) else { return }
                    feedback.acknowledge(ReplyPanelCopy.savedWriter(address))
                }),
            // #2796: the show is what Dan knows this conversation by, so that is what the sentence names,
            // not the contact the row happens to stand on.
            cannotContinue: {
                AttachedConversation.refusalToContinue(recipient,
                                                       displayName: prospect.replyWatchDisplayName)
            },
            confirmation: { body, _ in
                SendConfirmation(replyFor: recipient, of: prospect, body: body)
            },
            send: { body, _ in
                let sent = await ReplyPanel.commit(body: body, on: recipient, of: prospect,
                                                   now: Date(), sender: sender)
                context.saveOrWarnSendNotConfirmed(org: prospect.groupName, feedback: feedback)
                return sent
            })
    }
}
