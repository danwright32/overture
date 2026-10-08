import Foundation
import SwiftData

// #4357 slice I2 (plan v7 Phase 3, step 5, finding B3): the identity of the show behind a press, and the
// ONE rule that finds the live row it names.
//
// LIFTED, NOT WRITTEN. The rule is `ReachedOutSnapshot`'s (#3651), whose comment carries the whole
// argument: `persistentModelID` is the IDENTITY and the natural key is a WITNESS, because `naturalKey` is
// `@Attribute(.unique)` and reassigned at five sites, one of them a survivor adopting the key of the loser
// it just deleted. A key-only lookup then finds exactly one row and returns it with nothing to report, so a
// press meant for a merged-away show lands on the survivor (L145, L75, L15). The Reached out list was the
// only surface resolving that way; every other action found its show by key (`ProspectMutations.model(for:
// in:feedback:)`). Both now go through this type, so there is one answer to "which show did Dan press"
// rather than two (L263, L370).
//
// WHAT IS NOT HERE YET, and where it lands (#4358, the queue engine). The plan gives this resolver a fault
// set refusal, marks every resolved identifier dirty, falls back to `ModelContext.model(for:)` during the
// launch fill, and keeps a temporary to permanent identifier map for one generation. Each of those is a
// fact only the engine holds, so each would have no writer today and is left out rather than added
// unreachable (L65). The engine conforms to `ShowResolver` and adds them there.
//
// #4358 slice E4b: the engine conforms (`QueueEngine`'s `ShowResolver` extension), answering from its own members
// by identifier, falling back to the main context for a row the launch fill has not reached yet and marking it
// dirty, and refusing a row it knows to be out of step with the store (`Refusal.outOfStep`). The temporary to
// permanent identifier map is still not here: nothing an action holds needs it until the cutover (E4d) draws rows
// from the engine, so it would have no reader.
struct ShowIdentity: Equatable, Hashable, Sendable {
    let showID: PersistentIdentifier
    // The WITNESS, never the identity. If this disagrees with the row `showID` finds, the row is not the
    // one that was drawn and the press is refused.
    let naturalKey: String

    init(showID: PersistentIdentifier, naturalKey: String) {
        self.showID = showID
        self.naturalKey = naturalKey
    }

    init(_ show: some ProspectFacts) {
        self.init(showID: show.persistentModelID, naturalKey: show.naturalKey)
    }

    /// The show a card was drawn from, or nil for a card that names none. Every card the app builds carries
    /// its show's identifier (`QueueItem.init` over the facts fills it); a card built by hand, which only a
    /// test or a preview does, carries nil and resolves to nothing rather than to whatever holds its key.
    init?(_ item: QueueItem) {
        guard let showID = item.showID else { return nil }
        self.init(showID: showID, naturalKey: item.id)
    }

    // WHY A PRESS FINDS NOTHING. Three causes, three sentences, because two outcomes given the same
    // message are one outcome in practice and only one of these is "the show is gone" (L11, L260).
    // #4358 slice E4b adds a fourth, where the press DOES find the show and must still not act on it.
    enum Refusal: Equatable, CaseIterable, CustomStringConvertible {
        /// No row the resolver holds carries this identifier. It was deleted, or merged away.
        case gone
        /// The row is alive and its own key has moved, so it is not the show that was drawn.
        case reKeyed
        /// The row was drawn before its first save. A store identifier is minted AT that save, so the one
        /// the row was drawn with no longer names anything (pinned by `InsertedRowIdentifierAcrossSaveTests`),
        /// and with no map from the old identifier to the new one there is no way to tell this row from a
        /// different show that holds its key. Refused rather than resolved by key, which is the L75 shape
        /// this whole type exists to stop. #4358's map is what lets a press like this resolve.
        case drawnBeforeItsFirstSave
        /// #4358 slice E4b (plan v7 D7, plan item 11): the row is found, and the queue engine knows Overture's
        /// copy of it is out of step with the saved show (its verifier faulted it, or a save through another
        /// context touched it). Saving the main context's object would write the stale fields back over the saved
        /// ones, so the press is refused until the row is reloaded, by recovery or by Dan's "Reload this show".
        case outOfStep
        /// #4358 slice E4d: looking for the row THREW, which happens only while the launch fill has not reached it and
        /// the resolver reads it from the store instead. Not `gone`: nothing was measured about whether it exists,
        /// so saying it left the queue would claim something no read established (L11, L215).
        case unreadable

        var description: String {
            switch self {
            case .gone: return "gone"
            case .reKeyed: return "reKeyed"
            case .drawnBeforeItsFirstSave: return "drawnBeforeItsFirstSave"
            case .outOfStep: return "outOfStep"
            case .unreadable: return "unreadable"
            }
        }

        // Said in Dan's own words, one sentence each, in the shape #3651 settled. `gone` reuses the
        // wording already shipped for this case so the product does not grow a second way of saying one
        // thing. EACH BRANCH IS A WHOLE SENTENCE rather than one sentence with a name spliced into it, so
        // the copy inventory records sentences and never fragments (#2570, #2548).
        //
        // WHAT THE READER IS TOLD TO DO. Nothing here asks Dan to fix anything, because there is nothing
        // for him to fix: the save that moved the row has already rebuilt the list. Each says what
        // happened, that nothing was changed, and what the row in front of him now is.
        //
        // COLD READ, 2026-10-05, of the third branch, in the order Dan meets it: a show has just arrived,
        // he presses a control on its row, the row does not change, and this appears. "Added" rather
        // than "saved", because a show arriving is what he saw and a save is not his word (L399). It says
        // nothing was written, and does not promise the row is still there, because the row it was drawn
        // from may have been deleted before it was ever saved.
        func sentence(org: String?) -> String {
            switch self {
            case .gone:
                return ActionAck.couldNotFindShow(org: org)
            case .reKeyed:
                guard let org, !org.isEmpty else {
                    return "That show was merged, or moved to a different night, after this row was "
                        + "drawn. Nothing was changed. The list has caught up, so press it again"
                }
                return "\(org) was merged, or moved to a different night, after this row was drawn. "
                    + "Nothing was changed. The list has caught up, so press it again"
            case .drawnBeforeItsFirstSave:
                guard let org, !org.isEmpty else {
                    return "That show was still being added when this row was drawn, so Overture could "
                        + "not tell which show you pressed. Nothing was changed. The list has caught up, "
                        + "so press it again if it is still there"
                }
                return "\(org) was still being added when this row was drawn, so Overture could not tell "
                    + "which show you pressed. Nothing was changed. The list has caught up, so press it "
                    + "again if it is still there"
            // COLD READ, 2026-10-08, in the order Dan meets it: he presses a control on a card, the card does
            // not change, and this appears. The only refusal whose show IS there, so it is the only one that
            // asks him to do something first, and what it names is a button on that same card (L80, L111): a
            // reload is what changes the state he is stuck in, and pressing again without one is refused again.
            // "Saved show" rather than "the store", which is not his word (L399).
            case .outOfStep:
                guard let org, !org.isEmpty else {
                    return "Overture's copy of that show is out of step with the saved show, so nothing was "
                        + "changed. Press Reload this show on its card, then try again"
                }
                return "Overture's copy of \(org) is out of step with the saved show, so nothing was changed. "
                    + "Press Reload this show on its card, then try again"
            // COLD READ, 2026-10-08 (#4358 slice E4d), in the order Dan meets it: the queue has just opened and is still
            // taking his shows in, he presses a control, the card does not change, and this appears. It says the
            // read failed, not that the show is gone, and asks for the one thing that helps: the same press a moment
            // later, once Overture holds the show itself and no longer has to read it from the saved copy (L111).
            case .unreadable:
                guard let org, !org.isEmpty else {
                    return "Overture could not read that show from your saved shows just now, so nothing was "
                        + "changed. Press it again in a moment"
                }
                return "Overture could not read \(org) from your saved shows just now, so nothing was changed. "
                    + "Press it again in a moment"
            }
        }

        // #4532: the same causes, said for Cmd+Z. Separate from `sentence` because two of those
        // speak of a row Dan pressed and tell him to press it again, and pressing Cmd+Z again reverses the
        // NEXT action on the stack rather than retrying this one (L111). So these say what happened and
        // that nothing was undone, and ask for nothing. `org` is the name the Edit menu showed, which an
        // undo entry always holds.
        //
        // COLD READ, 2026-10-06, in the order Dan meets it: the menu said "Undo Dismiss: X", he pressed
        // it, nothing came back, and the banner says why. "Nothing was undone" rather than "nothing to
        // undo", because in the second case the show is there and a different night now.
        func undoSentence(org: String) -> String {
            switch self {
            case .gone:
                return "\(org) was merged into another show or removed since, so nothing was undone"
            case .reKeyed:
                return "\(org) was merged, or moved to a different night, since then, so nothing was undone"
            case .drawnBeforeItsFirstSave:
                return "\(org) was still being added when you acted on it, so Overture could not tell which "
                    + "show to put back. Nothing was undone"
            // COLD READ, 2026-10-08: the menu said "Undo Dismiss: X", he pressed it, and nothing came back. It
            // names the button that unsticks the row and never asks for Cmd+Z again, which would undo the NEXT
            // action instead (L111): what it asks is the reload, before the row is changed again.
            case .outOfStep:
                return "Overture's copy of \(org) is out of step with the saved show, so nothing was undone. "
                    + "Press Reload this show on its card before changing it again"
            // COLD READ, 2026-10-08: the menu said "Undo Dismiss: X", he pressed it, and the show could not be read.
            // It never asks for Cmd+Z again, which would undo the NEXT action (L111).
            case .unreadable:
                return "Overture could not read \(org) from your saved shows just now, so nothing was undone"
            }
        }
    }

    enum Outcome {
        case found(Prospect)
        case refused(Refusal)

        var show: Prospect? {
            if case .found(let show) = self { return show }
            return nil
        }
    }

    // ONE definition of "find the row behind this press" (L263, L370).
    //
    // `shows` must be LIVE, never a render pass's captured scope: resolving against a captured array
    // walks model references the pass took minutes ago (#3690, `RenderData`'s own comment).
    @MainActor
    func resolve(in shows: some ShowResolver) -> Outcome {
        guard let show = shows.liveShow(showID) else {
            // #4358 slice E4d: a look that THREW is said as itself, never as a show that is gone (L11).
            if shows.readFailed(showID) { return .refused(.unreadable) }
            // A store identifier carries the store it belongs to only once it has been saved, so its
            // absence is what marks one minted before the first save (`InsertedRowIdentifierAcrossSaveTests`
            // reads both halves). Such a row, drawn and then saved, now answers to a different identifier.
            return .refused(showID.storeIdentifier == nil ? .drawnBeforeItsFirstSave : .gone)
        }
        guard show.naturalKey == naturalKey else { return .refused(.reKeyed) }
        // Asked only once the row is found and is the one drawn: a gone or re-keyed row says so first, because
        // reloading would not help either.
        guard !shows.isOutOfStep(showID) else { return .refused(.outOfStep) }
        return .found(show)
    }
}

// What an action resolves its show THROUGH. Today that is the rows the caller already holds (the
// conformance below); the queue engine conforms in #4358, answering from its own members by identifier, so
// an action is written once against this and never against where the rows happen to live.
//
// Isolated per requirement rather than on the protocol, so a type that is not itself main actor isolated
// (an array) can conform without an isolated conformance, which this toolchain's language mode does not
// infer.
protocol ShowResolver {
    /// The live row carrying this identifier, or nil when none does. Never a lookup by key.
    @MainActor func liveShow(_ id: PersistentIdentifier) -> Prospect?
    /// The identity this resolver holds for each natural key asked about, for the callers that hold only
    /// a key (a reply, a nudge, a send confirmed from a sheet, a collapsed card's members, a night's rows).
    @MainActor func identities(forKeys keys: Set<String>) -> [String: ShowIdentity]
    /// Every row this resolver holds, for the actions that act on all of them and resolve none: the bulk
    /// re-prep, and the two reads that need a show's OTHER rows (the manual prep prefill's past addresses,
    /// and an organisation's do not contact mark). Never a way to find one show: that is `liveShow`.
    @MainActor var everyShow: [Prospect] { get }
    /// #4358 slice E4b: whether this resolver knows its copy of the row is out of step with the saved store, so an
    /// action on it would write stale fields back. Only the queue engine can know; rows a caller merely holds
    /// answer false (the extension below).
    @MainActor func isOutOfStep(_ id: PersistentIdentifier) -> Bool
    /// #4358 slice E4d: whether this resolver's last look for the row THREW, so a press that found nothing is said as
    /// a failed read. Only the queue engine reads the store to answer; rows a caller merely holds answer false.
    @MainActor func readFailed(_ id: PersistentIdentifier) -> Bool
}

extension ShowResolver {
    @MainActor
    func isOutOfStep(_ id: PersistentIdentifier) -> Bool { false }

    @MainActor
    func readFailed(_ id: PersistentIdentifier) -> Bool { false }

    @MainActor
    func identity(forKey key: String) -> ShowIdentity? {
        identities(forKeys: [key])[key]
    }

    /// The live rows for these keys, in the order asked, each resolved through its identity. A key with no
    /// row is skipped, which is what every caller of this did before it went through an identity: a row
    /// deleted since the keys were taken is not there to act on.
    @MainActor
    func shows(forKeys keys: [String]) -> [Prospect] {
        let held = identities(forKeys: Set(keys))
        var seen = Set<PersistentIdentifier>()
        return keys.compactMap { key in
            guard let identity = held[key], seen.insert(identity.showID).inserted else { return nil }
            return identity.resolve(in: self).show
        }
    }

    /// The show behind a card Dan pressed, or nil HAVING SAID SO (#1778): a control that does nothing with
    /// nothing said cannot be told from a broken one. Each refusal says its own cause.
    @MainActor
    func show(for item: QueueItem, feedback: ActionFeedback) -> Prospect? {
        guard let identity = ShowIdentity(item) else {
            feedback.acknowledge(ShowIdentity.Refusal.gone.sentence(org: item.groupName), tone: .warning)
            return nil
        }
        return said(identity.resolve(in: self), org: item.groupName, feedback: feedback)
    }

    /// The same question where the caller holds a key rather than a card. `org` is optional because those
    /// callers genuinely do not know it, and the sentence says so rather than naming the wrong show.
    @MainActor
    func show(forKey key: String, org: String?, feedback: ActionFeedback) -> Prospect? {
        guard let identity = identity(forKey: key) else {
            feedback.acknowledge(ShowIdentity.Refusal.gone.sentence(org: org), tone: .warning)
            return nil
        }
        return said(identity.resolve(in: self), org: org, feedback: feedback)
    }

    @MainActor
    private func said(_ outcome: ShowIdentity.Outcome, org: String?, feedback: ActionFeedback) -> Prospect? {
        switch outcome {
        case .found(let show):
            return show
        case .refused(let refusal):
            feedback.acknowledge(refusal.sentence(org: org), tone: .warning)
            return nil
        }
    }
}

// The rows a caller already holds, resolved by identifier. A linear walk, which is what every action
// already paid walking the same rows by key; the engine's dictionary replaces it in #4358.
extension Array: ShowResolver where Element == Prospect {
    @MainActor
    func liveShow(_ id: PersistentIdentifier) -> Prospect? {
        first { $0.persistentModelID == id }
    }

    @MainActor
    func identities(forKeys keys: Set<String>) -> [String: ShowIdentity] {
        var out: [String: ShowIdentity] = [:]
        // The FIRST row holding a key wins, as the dictionary every key caller built used to keep it.
        for show in self where keys.contains(show.naturalKey) && out[show.naturalKey] == nil {
            out[show.naturalKey] = ShowIdentity(show)
        }
        return out
    }

    @MainActor
    var everyShow: [Prospect] { self }
}

// What a surface hands the row factory: the rows a press resolves against, read only WHEN a press
// happens (#3690). Handed an array, a surface had to derive it before the press, and QueueView handed the
// render pass's own copy, model references frozen when the pass ran, so a merge left every action writing
// to a row the store had thrown away. Handed the LIVE list, `QueueModel.queueScope` (a whole store filter
// and a stable sort) would run once per drawn row. Read on the press, it runs zero times per row and is
// live by construction.
//
// DELIBERATELY NOT A `ShowResolver` ITSELF. A conformance would re-read the rows on every requirement it
// answers, and one press asks several: a keep on a collapsed card resolves its own row and then one per
// member, so a five night run would run the whole store filter seven times on a click (L383, L471). The
// read is a METHOD instead, named for when it happens, so its cost shows at the call site and each press
// pays it once.
//
// #4358 slice E4d: the queue hands the queue engine itself, which answers by identifier from its own members, so its
// presses cost no read at all; the Archive still hands its rows. Either way the press asks for the resolver once.
struct ShowsInHand {
    private let read: () -> any ShowResolver

    init(_ read: @escaping () -> [Prospect]) {
        self.read = { read() }
    }

    init(resolver: any ShowResolver) {
        self.read = { resolver }
    }

    /// The rows as they are at this press. Call once per press and hand the result to the action.
    @MainActor
    func onPress() -> any ShowResolver { read() }
}
