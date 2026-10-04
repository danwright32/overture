import Foundation

// #4356 (plan v7 Phase 2, section 4 "TableReader, structural"; L621, L55, L214): every cross-row table a card
// or a queue row reads, behind keyed reads that can be recorded.
//
// WHY. A card reads tables built over OTHER rows: the title of the row it arrived looking like, the night of
// the contact it may duplicate, the members of the group it fronts, the organisation's inherited answer.
// When the engine (Phase 4) keeps a card and another row changes, it must know whether that change reaches
// this card, and the only honest source for that is the reads the card actually made, under the keys it
// made them with, INCLUDING the keys it asked for and did not find: a card asking for a title that does not
// exist yet depends on that key, and a later row taking it must rebuild the card (#4106 plan fact 5).
//
// WHY STRUCTURAL. The tables used to be internal `let`s on `QueueModel.CardPreamble`, readable by anything,
// so a recording wrapper beside them would record only the reads somebody remembered to route through it
// (L621). Here the tables ARE the reader's private storage: no other file can reach them, so a card or a row
// reads through a keyed accessor or not at all, and `TableReaderIsTheOnlyWayInTests` fails if a stored table
// is ever declared anything but private or named outside this file.
//
// RECORDING COSTS NOTHING WHEN NOBODY RECORDS. The app's pass builds a reader with no log, and each read
// checks one optional. A test (and Phase 4's engine) hands a log in with `recording(into:)`.
struct TableReader {

    enum Table: String, CaseIterable, Sendable {
        case linked, inherited, venueBrands, roomNames, rowCounts, contradicted, sameShowGroups, titles,
             collapsedFronts, collapsedHidden, laterLookalikes, nights
    }

    /// One keyed read and whether the key held an answer. An absent read is recorded too, under the key that
    /// was asked for, because a later insert of that key changes what the reader would answer.
    struct Read: Hashable, Sendable {
        let table: Table
        let key: String
        let present: Bool
    }

    final class Log {
        private(set) var reads: Set<Read> = []
        fileprivate func record(_ table: Table, _ key: String, present: Bool) {
            reads.insert(Read(table: table, key: key, present: present))
        }
    }

    private let storedLinked: [String: [EngagementLink.Member]]
    private let storedInherited: [String: OrgAnswerLedger.Inherited]
    private let storedVenueBrands: ProducerGate.VenueBrands
    private let storedRowCounts: [String: Int]
    private let storedContradicted: Set<String>
    private let storedSameShowGroups: [String: [String]]
    private let storedTitles: [String: String]
    private let storedCollapsedFronts: [String: [String]]
    private let storedCollapsedHidden: Set<String>
    private let storedLaterLookalikes: [String: [String]]
    private let storedNights: [String: String]
    private let log: Log?
    /// When set, the only presenter names the venue brand table will answer for. That table is a judgement
    /// object rather than stored entries, so it cannot be narrowed by removing entries the way the rest are.
    private let visible: [Table: Set<String>]?

    init(linked: [String: [EngagementLink.Member]], inherited: [String: OrgAnswerLedger.Inherited],
         venueBrands: ProducerGate.VenueBrands, rowCounts: [String: Int], contradicted: Set<String>,
         sameShowGroups: [String: [String]], titles: [String: String], collapsedFronts: [String: [String]],
         collapsedHidden: Set<String>, laterLookalikes: [String: [String]], nights: [String: String]) {
        self.init(linked: linked, inherited: inherited, venueBrands: venueBrands, rowCounts: rowCounts,
                  contradicted: contradicted, sameShowGroups: sameShowGroups, titles: titles,
                  collapsedFronts: collapsedFronts, collapsedHidden: collapsedHidden,
                  laterLookalikes: laterLookalikes, nights: nights, log: nil, visible: nil)
    }

    private init(linked: [String: [EngagementLink.Member]], inherited: [String: OrgAnswerLedger.Inherited],
                 venueBrands: ProducerGate.VenueBrands, rowCounts: [String: Int], contradicted: Set<String>,
                 sameShowGroups: [String: [String]], titles: [String: String],
                 collapsedFronts: [String: [String]], collapsedHidden: Set<String>,
                 laterLookalikes: [String: [String]], nights: [String: String], log: Log?,
                 visible: [Table: Set<String>]?) {
        storedLinked = linked
        storedInherited = inherited
        storedVenueBrands = venueBrands
        storedRowCounts = rowCounts
        storedContradicted = contradicted
        storedSameShowGroups = sameShowGroups
        storedTitles = titles
        storedCollapsedFronts = collapsedFronts
        storedCollapsedHidden = collapsedHidden
        storedLaterLookalikes = laterLookalikes
        storedNights = nights
        self.log = log
        self.visible = visible
    }

    private func copy(log: Log?, visible: [Table: Set<String>]?) -> TableReader {
        TableReader(linked: storedLinked, inherited: storedInherited, venueBrands: storedVenueBrands,
                    rowCounts: storedRowCounts, contradicted: storedContradicted,
                    sameShowGroups: storedSameShowGroups, titles: storedTitles,
                    collapsedFronts: storedCollapsedFronts, collapsedHidden: storedCollapsedHidden,
                    laterLookalikes: storedLaterLookalikes, nights: storedNights, log: log, visible: visible)
    }

    /// The same tables, recording every read into `log`.
    func recording(into log: Log) -> TableReader { copy(log: log, visible: visible) }

    /// The same tables holding ONLY the entries `reads` names. The other entries are removed from the
    /// storage itself rather than hidden behind the accessors, so a consumer that reached the storage some
    /// other way would see them gone too, and its answer would move (`TableReaderRecordsEveryReadTests`).
    func answeringOnly(_ reads: Set<Read>) -> TableReader {
        var keys: [Table: Set<String>] = [:]
        for read in reads { keys[read.table, default: []].insert(read.key) }
        func kept<Value>(_ table: Table, _ storage: [String: Value]) -> [String: Value] {
            storage.filter { keys[table]?.contains($0.key) == true }
        }
        func kept(_ table: Table, _ storage: Set<String>) -> Set<String> {
            storage.filter { keys[table]?.contains($0) == true }
        }
        return TableReader(linked: kept(.linked, storedLinked), inherited: kept(.inherited, storedInherited),
                           venueBrands: storedVenueBrands, rowCounts: kept(.rowCounts, storedRowCounts),
                           contradicted: kept(.contradicted, storedContradicted),
                           sameShowGroups: kept(.sameShowGroups, storedSameShowGroups),
                           titles: kept(.titles, storedTitles),
                           collapsedFronts: kept(.collapsedFronts, storedCollapsedFronts),
                           collapsedHidden: kept(.collapsedHidden, storedCollapsedHidden),
                           laterLookalikes: kept(.laterLookalikes, storedLaterLookalikes),
                           nights: kept(.nights, storedNights), log: log,
                           visible: [.venueBrands: keys[.venueBrands] ?? [], .roomNames: keys[.roomNames] ?? []])
    }

    private func sees(_ table: Table, _ key: String) -> Bool {
        guard let visible, let keys = visible[table] else { return true }
        return keys.contains(key)
    }

    private func lookup<Value>(_ table: Table, _ key: String, in storage: [String: Value]) -> Value? {
        let value = sees(table, key) ? storage[key] : nil
        log?.record(table, key, present: value != nil)
        return value
    }

    private func member(_ table: Table, _ key: String, of storage: Set<String>) -> Bool {
        let found = sees(table, key) && storage.contains(key)
        log?.record(table, key, present: found)
        return found
    }

    // MARK: - The keyed reads, one per table

    /// The other dates and venues in this row's cross-venue engagement (T6).
    func linkedMembers(_ key: String) -> [EngagementLink.Member]? { lookup(.linked, key, in: storedLinked) }

    /// The organisation answer this row inherits (T5).
    func inherited(_ key: String) -> OrgAnswerLedger.Inherited? { lookup(.inherited, key, in: storedInherited) }

    /// Whether a presenter name is really its building's brand (T4), keyed by the name as asked.
    func isVenueBrand(_ presenter: String?) -> Bool {
        let key = presenter ?? ""
        let found = sees(.venueBrands, key) && storedVenueBrands.contains(presenter)
        log?.record(.venueBrands, key, present: found)
        return found
    }

    /// Whether a presenter name is spelled exactly like a room (T4), keyed by the name as asked.
    func isRoomName(_ presenter: String?) -> Bool {
        let key = presenter ?? ""
        let found = sees(.roomNames, key) && storedVenueBrands.isRoomName(presenter)
        log?.record(.roomNames, key, present: found)
        return found
    }

    /// How many rows the presenter's organisation carries across the store, keyed by its producer key.
    func organisationRowCount(_ presenter: String?) -> Int {
        guard let key = ProducerGate.key(presenter) else { return 0 }
        return lookup(.rowCounts, key, in: storedRowCounts) ?? 0
    }

    /// Whether the store holds a live row contradicting this flagged one (T2).
    func isContradicted(_ key: String) -> Bool { member(.contradicted, key, of: storedContradicted) }

    /// The other keys holding this same show (T1 group).
    func sameShowKeys(_ key: String) -> [String]? { lookup(.sameShowGroups, key, in: storedSameShowGroups) }

    /// A stored row's title, for naming a row another row points at.
    func title(_ key: String) -> String? { lookup(.titles, key, in: storedTitles) }

    /// Every row a collapsed group's front stands for, itself included (T1 collapse).
    func collapsedMembers(_ frontKey: String) -> [String]? {
        lookup(.collapsedFronts, frontKey, in: storedCollapsedFronts)
    }

    /// Whether this row is hidden behind its group's front (T1 collapse), so it is not drawn at all.
    func isCollapsedHidden(_ key: String) -> Bool { member(.collapsedHidden, key, of: storedCollapsedHidden) }

    /// The rows that arrived looking like this one, newest first.
    func laterLookalikes(_ key: String) -> [String]? { lookup(.laterLookalikes, key, in: storedLaterLookalikes) }

    /// A stored row's opening night, for naming the row a contact may duplicate.
    func night(_ key: String) -> String? { lookup(.nights, key, in: storedNights) }
}

// #4356 (plan v7 Phase 2, section 5 "the declared dependency graph"): which part of the queue's derivation
// reads which other part, as a TYPE the engine applies changes in, rather than as an order somebody keeps
// in their head.
//
// WHY IT IS DECLARED. Each term's own property test (Phase 4b) can prove that term patches itself correctly
// and still be blind to a HAND-OFF: dismissing a collapsed group's front changes which sibling is drawn, so a
// row enters the queue with no change to its own fields, and only the edge from ShowLink's collapse into the
// row entries carries that (#4106 plan fact 4, L220, L14). An edge nobody wrote down is a patch nobody runs.
// So the engine reads its order and its hand-offs from here, and `QueueEngineGraphTests` holds this to the
// plan's section 5, spelled out independently in the test, and to `TableReader`, whose every table must
// name the node that produces it.
//
// NOTHING RUNS THIS YET. The queue engine (Phase 4, #4358) applies changes in `order`.
enum QueueEngineNode: String, CaseIterable, Sendable {
    /// The sources: each row's `RowFacts`, plus the context and the clock.
    case rows
    /// Membership (every row not dismissed) and order. Its output, the drawn rows, feeds the collapse and T6.
    case queueScope
    /// T4: venue keys, presenter keys, witnesses and each presenter's distinct venue count.
    case producerTables
    /// T5: the inherited organisation answers.
    case ledger
    /// T1: the same-show groups over the corpus, and the collapse over what is drawn.
    case showLink
    /// T2: flagged rows the store itself contradicts.
    case contradictions
    /// T3: the feed break notices.
    case feedBreaks
    /// T6: cross-venue engagements among the drawn rows.
    case engagementLink
    /// T7: each row's entry, whose membership is the drawn rows minus those the collapse hides.
    case rowEntries
    /// T8: the ordered and derived outputs over the row entries.
    case derivedOutputs
    /// The cards, which read the row and every cross-row table through `TableReader`.
    case cards
    /// T9: the tick laps. A lap's WRITE re-enters as a new row change, so it is not an edge inside one.
    case tickLaps

    /// The nodes whose outputs this one reads within one change.
    var dependsOn: Set<QueueEngineNode> {
        switch self {
        case .rows, .tickLaps: return []
        case .queueScope, .producerTables, .contradictions: return [.rows]
        case .ledger: return [.rows, .producerTables]
        case .showLink: return [.rows, .queueScope]
        case .feedBreaks: return [.rows, .contradictions]
        case .engagementLink: return [.queueScope]
        case .rowEntries: return [.rows, .showLink, .ledger]
        case .derivedOutputs: return [.rowEntries]
        case .cards: return [.rows, .showLink, .contradictions, .producerTables, .ledger, .engagementLink,
                             .rowEntries]
        }
    }
}

enum QueueEngineGraph {
    /// The order the engine applies a change in. Every node comes after everything it depends on.
    static let order: [QueueEngineNode] = [
        .rows, .queueScope, .producerTables, .ledger, .showLink, .contradictions, .feedBreaks,
        .engagementLink, .rowEntries, .derivedOutputs, .cards, .tickLaps,
    ]

    /// The node that builds each table a card or a row reads through `TableReader`.
    static func producer(of table: TableReader.Table) -> QueueEngineNode {
        switch table {
        case .linked: return .engagementLink
        case .inherited: return .ledger
        case .venueBrands, .roomNames: return .producerTables
        case .rowCounts: return .rowEntries
        case .contradicted: return .contradictions
        case .sameShowGroups, .collapsedFronts, .collapsedHidden: return .showLink
        case .titles, .laterLookalikes, .nights: return .rows
        }
    }
}

// #4357 slice I1 (plan v7 Phase 3, step 7): two readers are EQUAL when every stored table and the visibility
// narrowing are equal, which is exactly when they answer every keyed read alike. The read log is left out on
// purpose: it records what a reader was ASKED, the history of whoever read it, not what it holds, so a reader
// that has been read and a fresh one over the same tables are the same reader. Written here, beside the
// tables, because they are private and must stay so (`TableReaderIsTheOnlyWayInTests`).
extension TableReader: Equatable {
    static func == (lhs: TableReader, rhs: TableReader) -> Bool {
        lhs.storedLinked == rhs.storedLinked
            && lhs.storedInherited == rhs.storedInherited
            && lhs.storedVenueBrands == rhs.storedVenueBrands
            && lhs.storedRowCounts == rhs.storedRowCounts
            && lhs.storedContradicted == rhs.storedContradicted
            && lhs.storedSameShowGroups == rhs.storedSameShowGroups
            && lhs.storedTitles == rhs.storedTitles
            && lhs.storedCollapsedFronts == rhs.storedCollapsedFronts
            && lhs.storedCollapsedHidden == rhs.storedCollapsedHidden
            && lhs.storedLaterLookalikes == rhs.storedLaterLookalikes
            && lhs.storedNights == rhs.storedNights
            && lhs.visible == rhs.visible
    }
}
