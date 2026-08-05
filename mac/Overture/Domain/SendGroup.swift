import Foundation

// #2033: the contacts that received the SAME email.
//
// One definition, because eleven surfaces need it and each of them was written when one contact meant
// one email. A shared thread makes them all wrong in a different way (two nudge buttons for one
// conversation, two OmniFocus tasks, a cap spent twice), and eleven private answers to the same question
// would drift the moment one of them was updated.
enum SendGroup {
    // Everyone who received this contact's email, including them, in a stable order.
    //
    // A contact who received their own email is a group of ONE rather than a special case, so a caller
    // never has to ask whether a group exists.
    static func peers(of recipient: Recipient, in prospect: Prospect) -> [Recipient] {
        guard let id = recipient.sendGroupId, !id.isEmpty else { return [recipient] }
        return prospect.recipients.filter { $0.sendGroupId == id }.sorted { $0.id < $1.id }
    }

    // #2063: who Dan's REPLY reaches, which is a different question from who his original email reached.
    //
    // Deliberately takes no prospect: the send group records what Overture did, and only the reply records
    // what the other side chose. Answering a private reply to the whole original group is the failure this
    // exists to prevent, so the group is not even in scope here.
    //
    // Falls back to the writer ALONE, never the group, when there is nothing to mirror (a reply captured
    // before the audience was recorded, or one that somehow arrived empty). The narrow reading is the safe
    // one: Dan can add somebody back, and cannot unsend.
    // Takes the protocol rather than `Recipient`, so the prospect reply path and the inquiry reply path are
    // one implementation and cannot answer "who does this reach" differently (L30).
    static func replyAudience(of recipient: any ReplyWatchableRecipient) -> [String] {
        if let captured = recipient.replyAudience?.filter({ !$0.isEmpty }), !captured.isEmpty {
            return captured
        }
        guard let own = recipient.replyWatchAddress, !own.isEmpty else { return [] }
        return [own]
    }

    // The one contact that stands for the group wherever a LIST would otherwise show it once per person.
    // Stable (lowest id) rather than "whoever is first in the relationship", because SwiftData's to-many
    // is unordered and a row that moves between launches reads as a different row.
    static func isRepresentative(_ recipient: Recipient, in prospect: Prospect) -> Bool {
        peers(of: recipient, in: prospect).first?.id == recipient.id
    }

    // Which conversation a contact belongs to. Its send group when it has one, otherwise itself: a contact
    // emailed alone is a group of one rather than a special case.
    static func groupKey(_ recipient: Recipient) -> String {
        if let id = recipient.sendGroupId, !id.isEmpty { return id }
        return recipient.id
    }

    // #2126: one row per EMAIL, chosen from the contacts that actually QUALIFY for the list asking.
    //
    // `isRepresentative` picks the lowest sorted id of the whole group and knows nothing about whether that
    // contact belongs in the list. Every surface then ANDs it with its own eligibility test, and the two
    // compose wrongly: when the alphabetically first contact is the one that stopped qualifying, the WHOLE
    // conversation disappears, because the list is standing on somebody it has already excluded. Measured
    // on the fixtures in OneRowPerGroupTests: a declined first contact took a live colleague's overdue
    // nudge and its entire reached-out row down with it, in both lists, silently.
    //
    // `peers(of:in:)` filters on sendGroupId alone with no resolution filter, so a booked or declined
    // contact stays the representative permanently. It cannot be taught otherwise without teaching it every
    // caller's idea of eligible, which is the thing that differs. So the order is inverted instead: each
    // list filters to what it wants FIRST and collapses after, and the row it keeps is the lowest id among
    // those, which is stable across launches for the same reason the old rule was.
    static func oneRowPerGroup<T>(_ qualifying: [T], recipient: (T) -> Recipient) -> [T] {
        var seen = Set<String>()
        return qualifying
            .sorted { recipient($0).id < recipient($1).id }
            .filter { seen.insert(groupKey(recipient($0))).inserted }
    }

    // #2033: the contacts the NEXT press of Send will email, which is the pre-send half of the same
    // question `peers` answers after the fact. One definition, so the card, the confirmation and the send
    // itself cannot disagree about who is about to be written to.
    //
    // Held contacts are excluded by `isSendablePending`, so a contact waiting on Dan's glance is never
    // quietly folded into somebody else's email.
    // #2046: everything a queue card needs to know about who its email reaches, worked out ONCE.
    //
    // Three of the card's fields are the same question asked three ways, and each was asking it from
    // scratch. Every ask filters the show's recipients through `isSendablePending`, which runs the draft
    // lint over each contact's whole outgoing letter, and it happens while a card is merely being built
    // for a scroll. Handed to the card rather than cached inside it, so a field cannot go back to
    // deriving its own without the card's initializer visibly changing.
    struct CardGroups {
        // Who the email goes to, no approval gate: what the message will LOOK like is a fact about the
        // draft (#2049).
        let preview: [Recipient]
        // Who the next press of Send actually reaches, which keeps the approval gate.
        let pending: [Recipient]

        // Whether anything on this show is waiting to be sent. The preview group is exactly the sendable
        // pending contacts (narrowed to the first when the show sends separately), so it is empty for the
        // same shows a direct scan would call empty.
        var hasPending: Bool { !preview.isEmpty }

        init(preview: [Recipient], pending: [Recipient]) {
            self.preview = preview
            self.pending = pending
        }

        // The one pass. Both groups come out of a single filter of the recipients.
        init(of prospect: Prospect) {
            let preview = SendGroup.previewGroup(of: prospect)
            self.init(preview: preview, pending: SendGroup.pending(from: preview, of: prospect))
        }
    }

    static func pendingGroup(of prospect: Prospect) -> [Recipient] {
        pending(from: previewGroup(of: prospect), of: prospect)
    }

    // The approval gate on its own, so a caller that already holds the preview group pays for the filter
    // once rather than again (#2046). The gate itself is unchanged and lives only here.
    private static func pending(from preview: [Recipient], of prospect: Prospect) -> [Recipient] {
        // The SHOW-level gate, the same one `SendService.nextPendingRecipient` applies: an unapproved draft
        // sends to nobody, whatever its contacts look like. Without this a card would name contacts on a
        // draft Dan has not approved, and a joint send would email them.
        guard prospect.status == .approved, prospect.draftBody != nil else { return [] }
        return preview
    }

    // #2017: every contact the send sheet offers, in send order. A contact a review guard is holding is
    // INCLUDED and marked, rather than dropped: a list that silently omits somebody on the show under-reports
    // who is on it, which is the same defect #2015 fixed on the draft card.
    static func candidates(of prospect: Prospect) -> [SendCandidate] {
        prospect.recipients
            .filter { $0.isSendablePending || $0.isBlockedAwaitingReview }
            .sorted { $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id }
            .compactMap { r in
                guard let email = r.email, !email.isEmpty else { return nil }
                return SendCandidate(id: r.id, name: r.name ?? email, email: email,
                                     isHeld: !r.isSendablePending)
            }
    }

    // #2017: the contacts Dan ticked that can ACTUALLY be sent to, in send order. The guard is applied here
    // rather than trusted from the ticks, because a guard that only lives on a screen is not a guard
    // (#2052): this is the one filter both the sheet's promise and the send itself go through, so what he
    // reads and what leaves cannot differ.
    static func sendableFor(_ prospect: Prospect, ids: [String]) -> [Recipient] {
        let wanted = Set(ids)
        return prospect.recipients
            .filter { wanted.contains($0.id) && $0.isSendablePending }
            .sorted { $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id }
    }

    // #2049: the same group WITHOUT the approval gate, for showing what the email will look like rather
    // than claiming who it is about to reach.
    //
    // Those are two different questions and they were being answered by one function. Naming the next
    // recipients is a claim about SENDING, so it must stay behind approval (#2015 caught a card naming
    // contacts on a draft nobody had approved). Previewing the greeting is a claim about the DRAFT, and
    // gating it on approval meant a drafted show, which is every show while Dan is reviewing it, showed
    // the "One email to everyone" switch directly above one greeting per contact. His reading of that
    // card: "is this saying that it's going to greet them by their emails?"
    //
    // Same body as before, so the two cannot bucket contacts differently: `pendingGroup` is now this plus
    // its gate.
    static func previewGroup(of prospect: Prospect) -> [Recipient] {
        let sendable = prospect.recipients
            .filter(\.isSendablePending)
            .sorted { $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id }
        guard prospect.sendsTogether else { return Array(sendable.prefix(1)) }
        return sendable
    }
}
