import Foundation
import SwiftData

// #4357 slice I1 (plan v7 Phase 3, step 7): the RenderData comparator.
//
// `differingFields(_:_:)` compares every stored member of two passes' `QueueView.RenderData` by VALUE and names
// each member that differs, by name only, never by a value (a value can carry a show's title or a contact's
// address, L222). Oracle part one needs it for any ported term whose output is RenderData as a whole, and the
// Phase 4 verifier compares a published pass against a rebuild with it.
//
// BY VALUE, three ways, and never by description:
//   - a member that is already a value with real equality is compared with `==`;
//   - a member that held MODELS (none since #4358 slice E4a gave the Reached out list identities) would be
//     compared through a projection onto store identifiers and the values beside them, because a model's
//     equality is object identity and two passes over one store hold different objects for the same row;
//   - the one class, `CardStore`, is compared through `contents`, the value it holds.
// `RenderDataComparisonCoversEveryFieldTests` holds this list to RenderData's real members, derived by Mirror,
// and to the rule that no member is compared by its description.
//
// #4358 slice E4b: IN THE APP, moved from the test target, because the queue engine's derivation is now one of
// its readers: `QueueEnginePass.differingFields` is this comparison, which the engine's floor records and the
// verifier's comparison (iii) name fields with. One comparator, so the oracle and the verifier cannot answer
// "do these two passes agree" differently (L263, L370). The engine hands in each pass's card contents as it
// captured them when the pass was derived (`cards:`), because the verifier compares on its own thread and the
// card store is a class the main thread goes on writing to as rows are drawn.
enum RenderDataComparison {

    /// One member's comparison: its name exactly as Mirror labels it, and whether the two passes agree on it.
    struct Field {
        let name: String
        /// How it is compared, so the guard can hold class and model members to a projection.
        let how: How
        let agrees: (QueueView.RenderData, QueueView.RenderData) -> Bool

        enum How { case value, projection }
    }

    /// The names of every member that differs, in declaration order, or empty when the two passes agree.
    static func differingFields(_ lhs: QueueView.RenderData, _ rhs: QueueView.RenderData) -> [String] {
        fields.filter { !$0.agrees(lhs, rhs) }.map(\.name)
    }

    /// The same comparison with each pass's card contents handed in as captured when it was derived, so the card
    /// store itself is never read: the verifier's thread compares, and the store is written on the main thread.
    static func differingFields(_ lhs: QueueView.RenderData, _ rhs: QueueView.RenderData,
                                cards: (lhs: QueueModel.CardStore.Contents, rhs: QueueModel.CardStore.Contents))
        -> [String] {
        fields.filter { field in
            guard field.name == cardsField else { return !field.agrees(lhs, rhs) }
            return !(cards.lhs == cards.rhs && preambleAgrees(lhs, rhs))
        }.map(\.name)
    }

    /// The member compared through the card store, which the captured form above replaces.
    static let cardsField = "cards"


    // Computed rather than stored: a stored static of closures is shared mutable state to the compiler, and
    // building the list costs nothing beside the comparison it serves.
    static var fields: [Field] { [
        Field(name: cardsField, how: .projection) { $0.cards.contents == $1.cards.contents && preambleAgrees($0, $1) },
        // #4357 step 5: identities now, so compared as the values they are.
        Field(name: "queueScope", how: .value) { $0.queueScope == $1.queueScope },
        Field(name: "selfBooking", how: .value) { $0.selfBooking == $1.selfBooking },
        Field(name: "agentInputs", how: .value) { $0.agentInputs == $1.agentInputs },
        Field(name: "gmailConnected", how: .value) { $0.gmailConnected == $1.gmailConnected },
        Field(name: "probeRunning", how: .value) { $0.probeRunning == $1.probeRunning },
        Field(name: "checkRunning", how: .value) { $0.checkRunning == $1.checkRunning },
        Field(name: "prepRunning", how: .value) { $0.prepRunning == $1.prepRunning },
        Field(name: "checkRunSince", how: .value) { $0.checkRunSince == $1.checkRunSince },
        Field(name: "checkLookups", how: .value) { $0.checkLookups == $1.checkLookups },
        Field(name: "reachedOut", how: .value) { $0.reachedOut == $1.reachedOut },
        Field(name: "reachedOutKeys", how: .value) { $0.reachedOutKeys == $1.reachedOutKeys },
        Field(name: "feedBreaks", how: .value) { $0.feedBreaks == $1.feedBreaks },
        Field(name: "mergeSurvivorsDropped", how: .value) { $0.mergeSurvivorsDropped == $1.mergeSurvivorsDropped },
        Field(name: "pendingBookings", how: .value) { $0.pendingBookings == $1.pendingBookings },
        Field(name: "summary", how: .value) { $0.summary == $1.summary },
        Field(name: "missedByACheckKeys", how: .value) { $0.missedByACheckKeys == $1.missedByACheckKeys },
        Field(name: "fanOutLine", how: .value) { $0.fanOutLine == $1.fanOutLine },
        Field(name: "rows", how: .value) { $0.rows == $1.rows },
        Field(name: "visibleRows", how: .value) { $0.visibleRows == $1.visibleRows },
        Field(name: "cardCheck", how: .value) { $0.cardCheck == $1.cardCheck },
        Field(name: "focusedRows", how: .value) { $0.focusedRows == $1.focusedRows },
        Field(name: "dateGroups", how: .value) { $0.dateGroups == $1.dateGroups },
        Field(name: "inquiryRows", how: .value) { $0.inquiryRows == $1.inquiryRows },
        Field(name: "inquiryGroups", how: .value) { $0.inquiryGroups == $1.inquiryGroups },
        // #4579: identities now, so compared as the values they are.
        Field(name: "inquiriesByRowID", how: .value) { $0.inquiriesByRowID == $1.inquiriesByRowID },
        // #4371 and #4358 slice E4a: identities now, so compared as the values they are.
        Field(name: "reachedOutList", how: .value) { $0.reachedOutList == $1.reachedOutList },
        Field(name: "dateProbeHeadings", how: .value) { $0.dateProbeHeadings == $1.dateProbeHeadings },
        Field(name: "stageCounts", how: .value) { $0.stageCounts == $1.stageCounts },
        Field(name: "geo", how: .value) { $0.geo == $1.geo },
        Field(name: "placement", how: .value) { $0.placement == $1.placement },
        Field(name: "now", how: .value) { $0.now == $1.now },
    ] }

    // MARK: projections

    /// One member of the card preamble, named exactly as Mirror labels it, so the guard can hold this list to
    /// the preamble's real members the way `fields` is held to RenderData's.
    struct PreambleField {
        let name: String
        let agrees: (QueueModel.CardPreamble, QueueModel.CardPreamble) -> Bool
    }

    /// The card preamble beside the cards: every member is a value, the tables compared through
    /// `TableReader`'s own equality over what it stores.
    static var preambleFields: [PreambleField] { [
        PreambleField(name: "tables") { $0.tables == $1.tables },
        PreambleField(name: "calendarBySourceId") { $0.calendarBySourceId == $1.calendarBySourceId },
        PreambleField(name: "overrides") { $0.overrides == $1.overrides },
        PreambleField(name: "clients") { $0.clients == $1.clients },
        PreambleField(name: "now") { $0.now == $1.now },
        PreambleField(name: "day") { $0.day == $1.day },
    ] }

    private static func preambleAgrees(_ lhs: QueueView.RenderData, _ rhs: QueueView.RenderData) -> Bool {
        preambleFields.allSatisfy { $0.agrees(lhs.cards.preamble, rhs.cards.preamble) }
    }

    /// How each stored member of the card store is accounted for: through `contents`, through the preamble, or
    /// left out with its reason. Held to the store's real members by Mirror, so a member added later has to be
    /// placed here before the guard passes.
    // copy-inventory:ignore-start  member names and the reasons a comparator leaves one out, never said to Dan
    static let cardStoreMembers: [String: String] = [
        "cards": "contents.cards",
        // #4357 step 5: one member holding both maps, over whatever rows the store was built from.
        "sources": "contents.shows, contents.contacts",
        "requestedKeys": "contents.requestedKeys",
        "preamble": "preambleFields",
        "registry": "left out: where the NEXT pass's requests are recorded, not what this pass produced",
        "expectedFirstFrameMisses": "left out: counted by the surfaces that read the store after the pass",
        "unexpectedCardMisses": "left out: counted by the surfaces that read the store after the pass",
    ]
    // copy-inventory:ignore-end
}
