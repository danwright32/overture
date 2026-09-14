import Foundation

// #3707 (milestone 82, Phase 1): when Overture can offer to link a reply that arrived on a thread it was
// never watching.
//
// #3706's case: the pitch went out by email to one contact, that contact forwarded it, and somebody else
// wrote back with a subject line of their own. `ReplyDetection` only ever fetches the thread the pitch
// went out on, so the message is invisible to it however plainly it is about the show, and all three
// existing hand routes refuse for reasons that are each correct about the case they were written for:
// #2718's inline control asks `isAskable`, which is the FORM pitch question; `AttachConversation` refuses
// a contact that already holds a thread; #2711's hand mark refuses for the same reason. Together they
// leave this shape with no control at all, the row goes on reading as silent, and `PostEventPrompt`
// closes it out as `neverHeardBack`, which is exactly the zero that cannot be told from a measurement
// (L90).
//
// THIS PHASE ONLY MAKES THE QUESTION REACHABLE. Nothing here widens what the picker searches (#3708) or
// what confirming it may write (#3709), so the two land before this control can do its job.
enum LinkReplyFromAnotherThread {
    // The words are Dan's question back to Overture, not a description of the control. "Another thread"
    // is the whole content of the case: a different PERSON was never the problem, since `hasReply`
    // already accepts any non-self writer on a watched thread and `ReplyIdentity.answering` already
    // resolves a writer who is a peer.
    static let menuLabel = "Link a reply from another thread"

    // Can this contact be asked about at all?
    //
    // DELIBERATELY NOT `ProposedConversation.isAskable`, which asks whether this is a hand-sent pitch with
    // no conversation. That question belongs to the form-pitch route and stays that. This one asks
    // whether a reply could have arrived somewhere Overture is not watching, which is true of an emailed
    // pitch and of a form pitch whose attached conversation is not the one that answered.
    //
    // `hasProvenOutreach` rather than `sentAt`, so the two routes into "this contact was reached" cannot
    // come to different answers (L16), and because #331/#378 already established that a bare `sentAt`
    // with no message id is a staged or corrupt record that never went anywhere.
    //
    // BOUNCED IS DELIBERATELY NOT ASKED. A bounced pitch is excluded from the reached-out list by
    // `isInPlay` before this is ever consulted, and on any surface that does draw it the useful act is
    // still this one: the reply that reaches Dan by another route is often how the right address is
    // learned. Refusing there would be a guard wider than its reason (L615).
    static func isOffered(_ r: Recipient) -> Bool {
        guard r.hasProvenOutreach else { return false }
        // The pitch is over. Reopening the question here would contradict the ending recorded on the row
        // directly above this control.
        guard r.resolution == nil else { return false }
        // Overture already knows a reply arrived, by its own reading or because Dan said so. Offering to
        // link one now would put a second writer beside reply detection for no gain.
        guard !r.replied, r.replyMarkedByHandAt == nil else { return false }
        // ONE route to the picker per row. Where #2718's inline control is already offering exactly this,
        // the menu item is absent, because a row carrying both would state one fact twice (L605).
        return !ProposedConversation.offersManualLink(r)
    }
}
