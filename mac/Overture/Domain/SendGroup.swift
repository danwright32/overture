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
        peers(of: recipient, among: prospect.recipients)
    }

    // #4357 slice E2: the same over any contacts, handed in, so a retained row answers it by the one body.
    static func peers<C: ContactFacts>(of recipient: C, among contacts: [C]) -> [C] {
        guard let id = recipient.sendGroupId, !id.isEmpty else { return [recipient] }
        return contacts.filter { $0.sendGroupId == id }.sorted { $0.id < $1.id }
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
        replyAudience(captured: recipient.replyAudience, own: recipient.replyWatchAddress)
    }

    // #4357 slice G2: the same for a contact read as `ContactFacts`, whose own address is the one
    // `Recipient.replyWatchAddress` names, answered by the one body below.
    static func replyAudience(ofContact recipient: some ContactFacts) -> [String] {
        replyAudience(captured: recipient.replyAudience, own: recipient.email)
    }

    private static func replyAudience(captured audience: [String]?, own: String?) -> [String] {
        if let captured = audience?.filter({ !$0.isEmpty }), !captured.isEmpty {
            return captured
        }
        guard let own, !own.isEmpty else { return [] }
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
    static func groupKey(_ recipient: some ContactFacts) -> String {
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
    //
    // #4531: then the store's identifier, because one show can hold two contacts on one address, and with
    // `id` alone which of the two was kept followed the order the relationship handed them over in.
    static func oneRowPerGroup<T, C: ContactFacts>(_ qualifying: [T], recipient: (T) -> C) -> [T] {
        var seen = Set<String>()
        return qualifying
            .sorted {
                let (a, b) = (recipient($0), recipient($1))
                return a.id != b.id ? a.id < b.id : a.persistentModelID < b.persistentModelID
            }
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
    // #4357 slice G2: generic over the contacts, so a retained show's card groups by the same body; the
    // model's own is `CardGroups`.
    struct Groups<C: ContactFacts> {
        // Who the email goes to, no approval gate: what the message will LOOK like is a fact about the
        // draft (#2049).
        let preview: [C]
        // Who the next press of Send actually reaches, which keeps the approval gate.
        let pending: [C]

        // Whether anything on this show is waiting to be sent. The preview group is exactly the sendable
        // pending contacts (narrowed to the first when the show sends separately), so it is empty for the
        // same shows a direct scan would call empty.
        var hasPending: Bool { !preview.isEmpty }

        init(preview: [C], pending: [C]) {
            self.preview = preview
            self.pending = pending
        }

        // The one pass. Both groups come out of a single filter of the contacts handed in.
        // #4356: `today` is the day the send gate judges a passed show against, handed in, because the
        // render pass builds these and must not read the wall clock for itself (`PassClockScanTests`).
        init<Row: ProspectFacts>(of row: Row, among contacts: [C], today: String) where Row.Contact == C {
            // #2046 collapsed three of these into one per card and nothing pinned that it stayed one.
            // #2048 counts them, so #2033's shape cannot come back without a number moving.
            QueueRenderPass.WorkTally.recordSendGroupBuild()
            let preview = SendGroup.previewGroup(of: row, among: contacts, today: today)
            self.init(preview: preview, pending: SendGroup.pending(from: preview, of: row))
        }
    }

    typealias CardGroups = Groups<Recipient>

    // #4168: carries `together` through for the same reason `previewGroup` takes it. The approval gate
    // below is unaffected by the choice, so only the grouping half moves.
    // #4356: judged on the caller's day, like `previewGroup`, so a caller holding both judges them alike.
    static func pendingGroup(of prospect: Prospect, together: Bool? = nil, today: String) -> [Recipient] {
        pending(from: previewGroup(of: prospect, together: together, today: today), of: prospect)
    }

    // The approval gate on its own, so a caller that already holds the preview group pays for the filter
    // once rather than again (#2046). The gate itself is unchanged and lives only here.
    private static func pending<Row: ProspectFacts>(from preview: [Row.Contact], of prospect: Row) -> [Row.Contact] {
        // The SHOW-level gate, the same one `SendService.nextPendingRecipient` applies: an unapproved draft
        // sends to nobody, whatever its contacts look like. Without this a card would name contacts on a
        // draft Dan has not approved, and a joint send would email them.
        guard prospect.status == .approved, prospect.draftBody != nil else { return [] }
        return preview
    }

    // #2017: every contact the send sheet offers, in send order. A contact a review guard is holding is
    // INCLUDED and marked, rather than dropped: a list that silently omits somebody on the show under-reports
    // who is on it, which is the same defect #2015 fixed on the draft card.
    // #4502: judged on the same `today` as the selection and the send, so the sheet never offers a contact
    // the send would then drop, or marks one held that would go.
    static func candidates(of prospect: Prospect, today: String) -> [SendCandidate] {
        Recipient.inSendOrder(
            prospect.recipients.filter { $0.isSendablePending(today: today) || $0.isBlockedAwaitingReview })
            .compactMap { r in
                guard let email = r.email, !email.isEmpty else { return nil }
                return SendCandidate(id: r.id, name: r.name ?? email, email: email,
                                     isHeld: !r.isSendablePending(today: today))
            }
    }

    // #2017: the contacts Dan ticked that can ACTUALLY be sent to, in send order. The guard is applied here
    // rather than trusted from the ticks, because a guard that only lives on a screen is not a guard
    // (#2052): this is the one filter both the sheet's promise and the send itself go through, so what he
    // reads and what leaves cannot differ.
    static func sendableFor(_ prospect: Prospect, ids: [String], today: String) -> [Recipient] {
        let wanted = Set(ids)
        return Recipient.inSendOrder(
            prospect.recipients.filter { wanted.contains($0.id) && $0.isSendablePending(today: today) })
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
    // #4168: `together` is taken as a VALUE, defaulting to the show's own stored answer.
    //
    // The Send sheet previews a choice Dan has ticked but not committed, and it used to do that by
    // writing the choice onto the live `Prospect` and restoring it in a `defer`. Those are two writes to
    // an observed SwiftData model inside a SwiftUI body evaluation, seven times a pass, and a write to an
    // observed property invalidates the views that read it, so the pass scheduled the next one. Measured
    // 2026-09-22 as one core pinned at 100% with the sheet open, ended by a force quit.
    //
    // Absent, this is `prospect.sendsTogether` exactly, so every existing call site is unchanged.
    // #4356: and judged on a given day, the one a card is built for, rather than the wall clock's.
    static func previewGroup(of prospect: Prospect, together: Bool? = nil, today: String) -> [Recipient] {
        previewGroup(of: prospect, among: prospect.recipients, together: together, today: today)
    }

    // #4357 slice G2: the same over any contacts, handed in. Each contact is judged against this show, the
    // one its model would reach through its back reference, and the greeting's audience is this show's
    // over the same contacts, so a model and a retained row group by one body.
    static func previewGroup<Row: ProspectFacts>(of row: Row, among contacts: [Row.Contact], together: Bool? = nil,
                                                today: String) -> [Row.Contact] {
        let sendable = Recipient.inSendOrder(contacts.filter {
            $0.passesTheSendGate(today: today, on: row, audience: row.greetingAudienceSize(among: contacts))
        })
        guard together ?? row.sendsTogether else { return Array(sendable.prefix(1)) }
        return sendable
    }
}

// The model's own card groups, from its own `recipients`, as they were built before #4357 slice G2.
extension SendGroup.Groups where C == Recipient {
    init(of prospect: Prospect, today: String) {
        self.init(of: prospect, among: prospect.recipients, today: today)
    }
}
