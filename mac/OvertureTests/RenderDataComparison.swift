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
//   - a member that holds MODELS (`queueScope`, `reachedOut`, `inquiriesByRowID`, the Reached out list) is
//     compared through a projection onto store identifiers and the values beside them, because a model's
//     equality is object identity and two passes over one store hold different objects for the same row;
//   - the one class, `CardStore`, is compared through `contents`, the value it holds.
// `RenderDataComparisonCoversEveryFieldTests` holds this list to RenderData's real members, derived by Mirror,
// and to the rule that no member is compared by its description.
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

    // Computed rather than stored: a stored static of closures is shared mutable state to the compiler, and
    // building the list costs nothing beside the comparison it serves.
    static var fields: [Field] { [
        Field(name: "cards", how: .projection) { $0.cards.contents == $1.cards.contents && preambleAgrees($0, $1) },
        Field(name: "queueScope", how: .projection) { $0.queueScope.map(\.persistentModelID) == $1.queueScope.map(\.persistentModelID) },
        Field(name: "selfBooking", how: .value) { $0.selfBooking == $1.selfBooking },
        Field(name: "agentInputs", how: .value) { $0.agentInputs == $1.agentInputs },
        Field(name: "gmailConnected", how: .value) { $0.gmailConnected == $1.gmailConnected },
        Field(name: "probeRunning", how: .value) { $0.probeRunning == $1.probeRunning },
        Field(name: "checkRunning", how: .value) { $0.checkRunning == $1.checkRunning },
        Field(name: "prepRunning", how: .value) { $0.prepRunning == $1.prepRunning },
        Field(name: "checkRunSince", how: .value) { $0.checkRunSince == $1.checkRunSince },
        Field(name: "checkLookups", how: .value) { $0.checkLookups == $1.checkLookups },
        Field(name: "reachedOut", how: .projection) { reachedOut($0.reachedOut) == reachedOut($1.reachedOut) },
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
        Field(name: "inquiriesByRowID", how: .projection) { $0.inquiriesByRowID.mapValues(\.persistentModelID) == $1.inquiriesByRowID.mapValues(\.persistentModelID) },
        Field(name: "reachedOutList", how: .projection) { list($0.reachedOutList) == list($1.reachedOutList) },
        Field(name: "dateProbeHeadings", how: .value) { $0.dateProbeHeadings == $1.dateProbeHeadings },
        Field(name: "stageCounts", how: .value) { $0.stageCounts == $1.stageCounts },
        Field(name: "geo", how: .value) { $0.geo == $1.geo },
        Field(name: "placement", how: .value) { $0.placement == $1.placement },
        Field(name: "now", how: .value) { $0.now == $1.now },
    ] }

    // MARK: projections

    /// The card preamble beside the cards: every member is a value, the tables compared through
    /// `TableReader`'s own equality over what it stores.
    private static func preambleAgrees(_ lhs: QueueView.RenderData, _ rhs: QueueView.RenderData) -> Bool {
        let a = lhs.cards.preamble, b = rhs.cards.preamble
        return a.tables == b.tables && a.calendarBySourceId == b.calendarBySourceId && a.overrides == b.overrides
            && a.clients == b.clients && a.now == b.now && a.day == b.day
    }

    private struct ReachedOutKey: Equatable {
        let show: PersistentIdentifier
        let contact: PersistentIdentifier
        let next: Date
    }

    private static func reachedOut(_ entries: [(prospect: Prospect, recipient: Recipient, next: Date)])
        -> [ReachedOutKey] {
        entries.map { ReachedOutKey(show: $0.prospect.persistentModelID, contact: $0.recipient.persistentModelID,
                                    next: $0.next) }
    }

    private enum EntryKey: Equatable {
        case show(PersistentIdentifier, PersistentIdentifier, Date)
        case inquiry(PersistentIdentifier, InquiryRow, Date)
    }

    private struct GroupKey: Equatable {
        let id: String
        let weekday: String
        let monthDay: String
        let year: String
        let rows: [EntryKey]
    }

    private struct ListKey: Equatable {
        let entries: [EntryKey]
        let groups: [GroupKey]
        let sourceCalendars: [String: String]
        let now: Date
    }

    private static func entry(_ e: ReachedOutEntry) -> EntryKey {
        switch e {
        case .prospect(let show, let contact, let next):
            return .show(show.persistentModelID, contact.persistentModelID, next)
        case .inquiry(let inquiry, let row, let next):
            return .inquiry(inquiry.persistentModelID, row, next)
        }
    }

    private static func list(_ l: QueueModel.ReachedOutList) -> ListKey {
        ListKey(entries: l.entries.map(entry),
                groups: l.groups.map { GroupKey(id: $0.id, weekday: $0.weekday, monthDay: $0.monthDay,
                                                 year: $0.year, rows: $0.rows.map(entry)) },
                sourceCalendars: l.sourceCalendars, now: l.now)
    }
}
