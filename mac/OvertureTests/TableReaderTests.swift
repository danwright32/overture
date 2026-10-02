import Foundation
import SwiftData
import Testing

// #4356 (plan v7 Phase 2, section 4): a card and a queue row depend on NOTHING they did not record reading.
//
// The engine (Phase 4) will rebuild a retained card only when a table entry it READ changes, so a read that
// is not recorded is a card that silently stays stale (L55, L214). This proves the recording complete the
// only way that does not trust the recorder: build each card once while recording, then build it again from
// a reader that answers ONLY the recorded keys and reports every other key absent. If the card read anything
// the log missed, by any route, the second card differs.
//
// The fixture is built so every table has something to say: an arrival tag pointing at a stored row and one
// pointing at a key no row holds (an ABSENT read, which a later insert of that key would change), a later
// lookalike, a duplicate contact naming another row, a collapsed group, a contradicted flagged row, a
// cross-venue engagement, and a presenter that is its building's brand.
@Suite("A card and a row depend on nothing they did not record reading (#4356)")
@MainActor
struct TableReaderRecordsEveryReadTests {

    static let now = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26, Eastern

    static func show(_ ctx: ModelContext, _ title: String, venue: String?, date: String,
                     presenter: String? = nil, missed: Int = 0) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: title, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theatre", venue: venue,
                         performanceDate: date, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered", fitScore: 5,
                         tier: "medium", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        p.presenter = presenter
        p.missedScoutCount = missed
        ctx.insert(p)
        return p
    }

    static func fixture(_ ctx: ModelContext) throws -> [Prospect] {
        let anchor = show(ctx, "Invented Anchor Revue", venue: "Teal Room", date: "2026-11-10",
                          presenter: "Grand Lantern Hall")
        let twin = show(ctx, "Invented Anchor Revue", venue: "Teal Room", date: "2026-11-10")
        // A second row for the same show, as a merge would leave it: its own key, so the store's unique
        // constraint and every table keyed by row hold, and ShowLink still joins the two on title and night.
        twin.naturalKey += "|copy"
        let pitched = show(ctx, "Invented Pitched Evening", venue: "Ochre Stage", date: "2026-11-12")
        let later = show(ctx, "Invented Later Arrival", venue: "Ochre Stage", date: "2026-11-14")
        let flagged = show(ctx, "Invented Vanishing Gala", venue: "Slate Hall", date: "2026-11-20", missed: 2)
        let live = show(ctx, "Invented Vanishing Gala", venue: "Slate Hall", date: "2026-11-20")
        live.naturalKey += "|live"   // the live twin of the flagged row, under a key of its own
        let touring = show(ctx, "Invented Touring Quartet", venue: "Birch House", date: "2026-11-21")
        let touringElsewhere = show(ctx, "Invented Touring Quartet", venue: "Cedar Annex", date: "2026-11-22")
        let brand = show(ctx, "Invented House Party", venue: "Grand Lantern Hall", date: "2026-11-23",
                         presenter: "Grand Lantern Hall")
        anchor.arrivedLookingLike = pitched.naturalKey
        anchor.arrivedOnAPitchedNight = "a-key-no-row-holds"
        later.arrivedLookingLike = anchor.naturalKey
        let contact = Recipient(id: "contact@invented.example", email: "contact@invented.example",
                                provenance: .manual)
        ctx.insert(contact)
        contact.prospect = anchor
        contact.looksLikeDuplicateContact = true
        contact.looksLikeDuplicateContactKey = pitched.naturalKey
        try ctx.save()
        return [anchor, twin, pitched, later, flagged, live, touring, touringElsewhere, brand]
    }

    static func scope(_ rows: [Prospect]) -> QueueModel.Scope {
        QueueModel.scope(from: rows, corpus: rows, now: now)
    }

    @Test func everyCardIsTheSameFromOnlyTheKeysItRecorded() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let rows = try Self.fixture(container.mainContext)
        let pre = Self.scope(rows).cards.preamble
        var tablesRead: Set<TableReader.Table> = []
        var absentReads = 0
        for p in rows {
            let log = TableReader.Log()
            let recorded = QueueModel.card(p, contacts: p.countedRecipients,
                                           preamble: pre.reading(through: pre.tables.recording(into: log)))
            tablesRead.formUnion(log.reads.map(\.table))
            absentReads += log.reads.filter { !$0.present }.count
            let narrowed = QueueModel.card(p, contacts: p.countedRecipients,
                                           preamble: pre.reading(through: pre.tables.answeringOnly(log.reads)))
            let differing = QueueModel.differingFieldNames(recorded, narrowed)
            #expect(differing.isEmpty, Comment(rawValue: "a card read cross-row tables its log does not "
                + "show, so a retained copy would not know to rebuild: " + differing.joined(separator: ", ")))
        }
        // The positive controls: the fixture exercised the tables it was built for, and an absent key was
        // asked for and recorded as absent (L159).
        let wanted: Set<TableReader.Table> = [.titles, .nights, .laterLookalikes, .collapsedFronts, .contradicted,
                                              .linked, .venueBrands, .roomNames, .rowCounts, .sameShowGroups,
                                              .inherited]
        let unexercised = wanted.subtracting(tablesRead).map(\.rawValue).sorted()
        #expect(unexercised.isEmpty, Comment(rawValue: "the fixture never read these tables, so the check above "
            + "says nothing about them: " + unexercised.joined(separator: ", ")))
        #expect(absentReads > 0, "no absent read was recorded, so a later insert could not be seen to matter")
    }

    // The other half of the control: hiding ONE recorded key does change a card, so the comparison above can
    // fail at all.
    @Test func hidingARecordedKeyChangesTheCard() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let rows = try Self.fixture(container.mainContext)
        let pre = Self.scope(rows).cards.preamble
        let anchor = rows[0]
        let log = TableReader.Log()
        let card = QueueModel.card(anchor, contacts: anchor.countedRecipients,
                                   preamble: pre.reading(through: pre.tables.recording(into: log)))
        let title = try #require(log.reads.first { $0.table == .titles && $0.present })
        let missingOne = pre.tables.answeringOnly(log.reads.subtracting([title]))
        let narrowed = QueueModel.card(anchor, contacts: anchor.countedRecipients,
                                       preamble: pre.reading(through: missingOne))
        #expect(narrowed != card, "hiding a title the card read left the card unchanged")
    }

    // A row entry reads the collapse and the inherited answers through the same reader (plan v7 section 4:
    // "Cards and row entries read through it").
    @Test func theRowsReadTheCollapseThroughTheReader() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let rows = try Self.fixture(container.mainContext)
        let full = Self.scope(rows)
        // The twin of the anchor is hidden behind it, so the rows hold one of the pair.
        let anchorKeys = Set([rows[0].naturalKey, rows[1].naturalKey])
        #expect(full.rows.filter { anchorKeys.contains($0.id) }.count == 1,
                "the collapsed pair did not collapse, so this fixture checks nothing about the rows")
        let log = TableReader.Log()
        _ = QueueModel.scope(from: rows, corpus: rows, now: Self.now, tableLog: log)
        let hiddenReads = log.reads.filter { $0.table == .collapsedHidden }
        #expect(Set(hiddenReads.map(\.key)) == Set(rows.map(\.naturalKey)),
                "the row loop did not ask the reader whether each row is hidden")
        #expect(log.reads.contains { $0.table == .inherited },
                "the row loop did not read the inherited answers through the reader")
    }
}

// #4356 (plan v7 Phase 2, section 4): the cross-row tables can be reached through `TableReader`'s keyed reads
// and in no other way.
//
// Swift's `private` is what makes this structural rather than a convention, so the scan's job is to keep it
// true: every table the reader stores is declared `private`, no other file in the app names one, and the
// card preamble carries no table of its own beside the reader. Each of those is the shape a bypass would
// take, a widened field, a second copy of a table, or a new table added to the preamble where nothing
// records reading it (L621).
@Suite("Only TableReader can reach the cross-row tables (#4356)")
@MainActor
struct TableReaderIsTheOnlyWayInTests {

    /// The reader's stored properties, as `(line, declaration)`, read from its own source.
    static func storedProperties() throws -> [(line: Int, code: String)] {
        let file = try #require(AppSourceWalk.appFiles().first { $0.name == "TableReader.swift" })
        var inside = false
        var found: [(line: Int, code: String)] = []
        for (line, code) in SwiftSource.scannableLines(in: file.text) {
            if code.hasPrefix("struct TableReader") { inside = true; continue }
            if code.hasPrefix("}") { inside = false }
            guard inside, code.hasPrefix("    "), !code.hasPrefix("     ") else { continue }
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(separator: " ").map(String.init)
            guard words.contains("let") || words.contains("var"), !words.contains("static"),
                  !words.contains("func"), !trimmed.hasSuffix("{") else { continue }
            found.append((line, trimmed))
        }
        return found
    }

    @Test func everyTableTheReaderStoresIsPrivate() throws {
        let stored = try Self.storedProperties()
        #expect(stored.count >= TableReader.Table.allCases.count,
                "fewer stored properties were found than the reader has tables, so the scan read nothing")
        let open = stored.filter { !$0.code.hasPrefix("private ") }.map { "line \($0.line): \($0.code)" }
        #expect(open.isEmpty, Comment(rawValue: "these are stored on the reader and reachable without a keyed "
            + "read, so a card or row could read them unrecorded: " + open.joined(separator: "; ")))
    }

    @Test func noOtherFileNamesTheStoredTables() throws {
        let names = try Self.storedProperties().compactMap { entry -> String? in
            let afterLet = entry.code.components(separatedBy: "let ").dropFirst().first
            return afterLet?.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }.filter { $0.hasPrefix("stored") }
        #expect(names.count >= TableReader.Table.allCases.count - 1, "the stored table names were not read")
        var found: [String] = []
        for file in AppSourceWalk.appFiles() where file.name != "TableReader.swift" {
            for (line, code) in SwiftSource.scannableLines(in: file.text) {
                let words = Set(code.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
                for name in names where words.contains(name) { found.append("\(file.name):\(line) names \(name)") }
            }
        }
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
    }

    // The preamble keeps only what is not about OTHER rows: the reader itself, and the small inputs every
    // card reads the same way whatever else is stored (the source calendars, the overrides, the client window,
    // the instant and the day). A new cross-row table added here instead of to the reader would be read with
    // nothing recording it.
    @Test func theCardPreambleHoldsNoTableBesideTheReader() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let rows = try TableReaderRecordsEveryReadTests.fixture(container.mainContext)
        let pre = TableReaderRecordsEveryReadTests.scope(rows).cards.preamble
        let labels = Set(Mirror(reflecting: pre).children.compactMap(\.label))
        #expect(labels == ["tables", "calendarBySourceId", "overrides", "clients", "now", "day"],
                Comment(rawValue: "the card preamble holds " + labels.sorted().joined(separator: ", ")))
    }
}

// #4356 (plan v7 Phase 2, section 5): the declared dependency graph is a real order, says what the plan says,
// and covers every table a card reads.
//
// The plan's edges are spelled out HERE, independently of `QueueEngineNode.dependsOn`, quoted from discussion
// #4267's section 5, so a dropped edge is a disagreement between two statements rather than one statement
// agreeing with itself (L70). The one that matters most is ShowLink into the row entries: dismissing a
// collapsed group's front changes which sibling is a row with no change to that sibling (#4106 fact 4).
@Suite("The queue engine's dependency graph is the plan's, and an order (#4356)")
struct QueueEngineGraphTests {

    typealias Node = QueueEngineNode

    /// Plan v7 section 5, node by node.
    static let planEdges: [Node: Set<Node>] = [
        .rows: [],                                          // 1. the sources
        .queueScope: [.rows],                               // 2. depends on rows
        .producerTables: [.rows],                           // 3. over the whole corpus
        .ledger: [.rows, .producerTables],                  // 4. brand verdicts and venue counts from T4
        .showLink: [.rows, .queueScope],                    // 5. group over the corpus, collapse over `drawn`
        .contradictions: [.rows],                           // 6. T2 over the corpus
        .feedBreaks: [.rows, .contradictions],              // 6. T3 from rows, T2 and the clock
        .engagementLink: [.queueScope],                     // 7. over the drawn rows
        .rowEntries: [.rows, .showLink, .ledger],           // 8. `hidden` from T1, `inherited` from T5
        .derivedOutputs: [.rowEntries],                     // 9. over T7's membership and entries
        .cards: [.rows, .showLink, .contradictions, .producerTables, .ledger, .engagementLink,
                 .rowEntries],                              // 10. every TableReader read, row counts from T7
        .tickLaps: [],                                      // 11. a write re-enters as a new change
    ]

    @Test func theEdgesAreThePlansEdges() {
        #expect(Set(Self.planEdges.keys) == Set(Node.allCases), "the plan's list and the type name different nodes")
        for node in Node.allCases {
            let declared = node.dependsOn
            let planned = Self.planEdges[node] ?? []
            #expect(declared == planned, Comment(rawValue: "\(node) depends on "
                + declared.map(\.rawValue).sorted().joined(separator: ", ") + " and the plan says "
                + planned.map(\.rawValue).sorted().joined(separator: ", ")))
        }
    }

    @Test func theOrderNamesEveryNodeOnceAfterEverythingItReads() {
        let order = QueueEngineGraph.order
        #expect(order.count == Node.allCases.count && Set(order) == Set(Node.allCases),
                "the order does not name every node exactly once")
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for node in order {
            for dependency in node.dependsOn {
                #expect((position[dependency] ?? .max) < (position[node] ?? .min),
                        Comment(rawValue: "\(node) is applied before \(dependency), which it reads"))
            }
        }
    }

    // Every table a card reads names the node that builds it, and the cards depend on that node, so a change
    // to the table's producer reaches the cards that read it.
    @Test func everyTableACardReadsIsBuiltByANodeTheCardsDependOn() {
        for table in TableReader.Table.allCases {
            let producer = QueueEngineGraph.producer(of: table)
            #expect(Node.cards.dependsOn.contains(producer),
                    Comment(rawValue: "cards read the \(table) table, built by \(producer), and do not depend on it"))
        }
    }
}
