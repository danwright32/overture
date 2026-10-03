import Testing
import Foundation

// #4406: no unsorted read of the show table goes unclassified.
//
// A fetch with no sort has no order to promise (L343), and SwiftData's is not repeatable: on a context holding
// any unsaved change it came back in a different order on each of six opens of one store file (measured for
// #4397, 2026-09-30). A reader that keeps the FIRST row matching something (`.first`, `first(where:)`, a tie
// in `max(by:)` or in a sort, a dictionary keeping the first or the last writer, a loop that stops early)
// therefore picks a different row from run to run on unchanged data, which is how two landings of the same
// inputs left two different stores (L1002).
//
// The fix where the order matters is `Prospect.inKeyOrder` applied AT the read, on the same line, so a reader
// of the call site sees the order is decided there. Every other unsorted read is listed below with the reason
// its result does not depend on order, so the next one written is refused until somebody has asked that
// question of it. The list of reads is DERIVED from the app's source, never written out by hand (L96, L41),
// and the reasons are claims about the reader as it stands: when a reader changes so the claim stops being
// true, the entry is what has to change, and an entry whose read is gone fails the run (L346).
//
// What this cannot do, stated so nobody expects it to: it cannot read a reason and check it is true. It makes
// the question be asked once per read, with the answer written beside the read's name.
enum UnsortedProspectFetchAudit {

    enum Kind: Equatable {
        // The reader uses the rows as a set: each row is written on its own, counted, or keyed by its unique
        // natural key, so no row decides anything for another.
        case orderFree
        // The order matters to a reader below this one, and that reader imposes its own total order before it
        // takes a first match (`LocalHistory.records`, `ScoutLandingStore`, `DownbeatBooking`'s sort).
        case orderedDownstream
        // Named rather than passed: the read was not audited all the way down, and the entry says why.
        case notYetAudited
    }

    // One unsorted read: the file holding it and the function (or property) it sits in.
    struct Site: Hashable, Comparable, CustomStringConvertible {
        let file: String
        let scope: String
        static func < (a: Site, b: Site) -> Bool { (a.file, a.scope) < (b.file, b.scope) }
        var description: String { "\(file) \(scope)" }
    }

    struct Entry {
        let file: String
        let scope: String
        let reads: Int
        let kind: Kind
        let why: String
        var site: Site { Site(file: file, scope: scope) }
    }

    private static let historyOrdersItself = """
        Its only reader is `LocalHistory.forMatching`, which puts the rows in key order itself before the \
        matcher takes its first possible match (#4397).
        """
    private static let perRow = """
        Every row is judged and written on its own; nothing kept from one row decides what happens to another.
        """
    private static let bookingSortsItself = """
        `DownbeatBooking.reconcileBooked` sorts by date, kind, title and natural key before it consumes a \
        booking, which is a total order, and the score settle beside it is per row.
        """

    static let classified: [Entry] = [
        // The window.
        Entry(file: "RootView.swift", scope: "allProspects", reads: 1, kind: .notYetAudited, why: """
            The whole table every window surface derives from (the queue, the archive, follow ups, sources, \
            organisations). The reads checked here take a first match only by natural key, which is unique, but \
            the derivations below it were not each audited, and sorting this query changes the hottest read in \
            the app without a measured price. Named rather than passed (#4406).
            """),
        Entry(file: "RootView.swift", scope: "toPrepByStatus", reads: 1, kind: .orderFree, why: """
            Counted by the start gate, keyed by natural key in `PrepNightPlan`, and sorted for display by \
            `PrepQueueBuilder.prepSelectionOrder` (#3375) before the sheet draws a row.
            """),
        Entry(file: "RootView.swift", scope: "ingestScoutExtract", reads: 1, kind: .orderedDownstream,
              why: historyOrdersItself),
        Entry(file: "RootView.swift", scope: "offerPendingScoutIngests", reads: 1, kind: .orderedDownstream,
              why: historyOrdersItself),
        // #4335: the idle recovery builds the same match history the ingest it replays does.
        Entry(file: "RootView.swift", scope: "recoverAnInterruptedLandingIfIdle", reads: 1, kind: .orderedDownstream,
              why: historyOrdersItself),
        Entry(file: "RootView.swift", scope: "syncOmniFocus", reads: 1, kind: .orderFree, why: """
            Every show earns its own tasks, collapsed per send group inside that show, and completions are \
            found by natural key, which is unique.
            """),
        Entry(file: "RootView.swift", scope: "ingestPrep", reads: 1, kind: .orderFree, why: """
            Read into a set of forbidden terms (`VoiceGuidanceGuard.forbiddenTerms`).
            """),
        Entry(file: "LeadIntakeModel.swift", scope: "importAll", reads: 1, kind: .orderedDownstream,
              why: historyOrdersItself),
        Entry(file: "FollowUpsView.swift", scope: "#Preview", reads: 1, kind: .orderFree, why: """
            An Xcode preview over a container it owns; nothing ships from it.
            """),

        // The reconcile tick.
        Entry(file: "ReconcileScheduler.swift", scope: "stillStored", reads: 1, kind: .orderFree, why: """
            The rows holding one persistent identifier (#4417), which at most one row can hold, so its \
            `.first` is the only row there is.
            """),
        Entry(file: "ReconcileScheduler.swift", scope: "reconcileBookings", reads: 1, kind: .orderedDownstream,
              why: bookingSortsItself),
        Entry(file: "ReconcileScheduler.swift", scope: "republishDueBadge", reads: 1, kind: .orderFree, why: """
            Counted (`DueWork.counts`) and reduced to the earliest instant (`DueWork.nextChange`); neither \
            keeps a row.
            """),
        Entry(file: "DownbeatBooking.swift", scope: "bookingEntities", reads: 1, kind: .orderedDownstream,
              why: bookingSortsItself),

        // The detached runs and their handoff files.
        Entry(file: "ReplyClassifyService.swift", scope: "buildQueue", reads: 1, kind: .orderFree, why: """
            Every reply needing a classification becomes its own item and the run answers each one; nothing \
            is chosen between them.
            """),
        Entry(file: "PrepQueueService.swift", scope: "eligibleProspects", reads: 1, kind: .orderFree, why: """
            Every eligible show goes into the work list, none capped or chosen over another, and the \
            experiment arm is a coin drawn per show.
            """),
        Entry(file: "PrepQueueService.swift", scope: "houses", reads: 1, kind: .orderFree, why: """
            Folded into a set of house keys and returned sorted (`ProducerGate.houses`), each spelled by its \
            shortest then lowest name rather than the first one seen.
            """),
        Entry(file: "PrepQueueService.swift", scope: "markProbed", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "PrepQueueService.swift", scope: "settleReachabilityProbe", reads: 1, kind: .orderFree,
              why: perRow),
        Entry(file: "PrepQueueService.swift", scope: "recordHeldBack", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "PrepQueueService.swift", scope: "sweepStaleHeldBackMarks", reads: 1, kind: .orderFree,
              why: perRow),
        Entry(file: "PrepQueueService.swift", scope: "markHandedToRun", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "PrepImporter.swift", scope: "ingestFile", reads: 1, kind: .orderedDownstream,
              why: historyOrdersItself),
        Entry(file: "ReprepRelease.swift", scope: "releaseAfterRun", reads: 1, kind: .orderFree, why: perRow),

        // The scout.
        Entry(file: "ScoutService.swift", scope: "readProspectTable", reads: 1, kind: .orderedDownstream, why: """
            The landing holds it in key order (`ScoutLandingStore`, #4397), the history is ordered by \
            `LocalHistory`, and the venue brand corpus built from it is a set.
            """),
        Entry(file: "PossibleMatchRecheck.swift", scope: "run", reads: 1, kind: .orderedDownstream, why: """
            The history it matches against is ordered by `LocalHistory`, the brand corpus is a set, and each \
            flagged row is then judged on its own.
            """),
        Entry(file: "PossibleMatchFanOut.swift", scope: "findings", reads: 1, kind: .orderFree, why: """
            Grouped into sets of acts per match, then sorted by count and name, which is a total order.
            """),

        // Single rows and launch passes.
        Entry(file: "Prospect.swift", scope: "stored", reads: 1, kind: .orderFree, why: """
            Filtered to one natural key, which is unique, with a fetch limit of one.
            """),
        Entry(file: "NaturalKeyVenueMigration.swift", scope: "run", reads: 1, kind: .orderFree, why: """
            Every group is ordered by `ingestedAt` then natural key inside `groupsOfOneShow` (#3780) before \
            any survivor rung reads it, so the read's order never reaches a first match.
            """),
        Entry(file: "DuplicateContactMerge.swift", scope: "run", reads: 1, kind: .orderFree, why: """
            Merges duplicate contacts inside one show at a time; no show is compared with another.
            """),
        Entry(file: "DayOff.swift", scope: "reapplyAll", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "PresenterWithheldRecheck.swift", scope: "candidates", reads: 1, kind: .orderFree, why: """
            Every candidate is stamped or counted; none is chosen over another.
            """),
        Entry(file: "RecipientBackfill.swift", scope: "repairThreadDown", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "DismissReasonMigration.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "AnsweredReplyBackfill.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "WentByRetirement.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "PassedKeptRetirement.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "CatchAllFitReasonMigration.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "LocationRepair.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "LocationBackfill.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "EmptyReasonSupersededRepair.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "RoomPresenterSweep.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "ActIsThePartyRealignment.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "ExcludedTownRetirement.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "ExcludedTownRetirement.swift", scope: "restore", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "ShowOutcomeBackfill.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "FitReasonRealignment.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "ContactFormResultMigration.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "ReachabilityVerdictRefresh.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "FirstSeenBackfill.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "DisciplineMigration.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "DeadRunWriteOffRepair.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "FragmentMatchCorrection.swift", scope: "run", reads: 1, kind: .orderFree, why: perRow),
        Entry(file: "WatchedSourceBackfill.swift", scope: "stampCarnegieProspects", reads: 1, kind: .orderFree,
              why: perRow),
        Entry(file: "DebugStaging.swift", scope: "clearDebugLeads", reads: 1, kind: .orderFree, why: """
            Deletes every debug row; a debug build only.
            """),
        Entry(file: "DebugSeed.swift", scope: "clearStore", reads: 1, kind: .orderFree, why: """
            Deletes every row; a debug build only.
            """),
    ]

    // MARK: the reader

    private static let descriptorToken = "FetchDescriptor<Prospect>"
    private static let keyOrder = "Prospect.inKeyOrder("

    // Every unsorted read of the show table in one file, one entry per read. A read is a `FetchDescriptor`
    // over `Prospect` CONSTRUCTED (a type annotation is not a read) with no `sortBy`, or a `@Query` over
    // `[Prospect]` with no `sort`. One whose line passes it through `Prospect.inKeyOrder` is ordered where it
    // is read, and is not reported.
    static func unsortedReads(inSource source: String, file: String) -> [Site] {
        let lines = SwiftSource.scannableLines(in: source, skipping: [])
        var found: [Site] = []
        for (at, entry) in lines.enumerated() {
            let code = entry.code
            if let range = code.range(of: descriptorToken) {
                let after = code[range.upperBound...].drop { $0 == " " }
                guard after.first == "(" else { continue }
                let arguments = balanced(from: at, startingAt: String(after), in: lines)
                if arguments.contains("sortBy") || code.contains(keyOrder) { continue }
                found.append(Site(file: file, scope: scope(of: at, in: lines)))
            } else if code.contains("@Query") {
                guard let attribute = code.range(of: "@Query") else { continue }
                let rest = code[attribute.upperBound...]
                let arguments = rest.first == "(" ? balanced(from: at, startingAt: String(rest), in: lines) : ""
                guard !arguments.contains("sort"),
                      let property = prospectQueryProperty(from: at, in: lines) else { continue }
                found.append(Site(file: file, scope: property))
            }
        }
        return found
    }

    // The text from an opening parenthesis to the one that closes it, across lines.
    private static func balanced(from at: Int, startingAt text: String,
                                 in lines: [(line: Int, code: String)]) -> String {
        var depth = 0
        var out = ""
        var index = at
        var current = text
        while true {
            for ch in current {
                out.append(ch)
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1; if depth == 0 { return out } }
            }
            index += 1
            guard index < lines.count else { return out }
            current = lines[index].code
        }
    }

    // The property a `@Query` declares, when it is a list of shows: the next `var name: [Prospect]`.
    private static func prospectQueryProperty(from at: Int, in lines: [(line: Int, code: String)]) -> String? {
        for index in at..<min(at + 12, lines.count) {
            let code = lines[index].code
            guard let varRange = code.range(of: "var ") else { continue }
            let rest = code[varRange.upperBound...]
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let name = rest[..<colon].trimmingCharacters(in: .whitespaces)
            let type = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return type.hasPrefix("[Prospect]") ? name : nil
        }
        return nil
    }

    // The function, preview or stored property a read sits in: a `static let` or `static var` on the read's
    // own line names itself, otherwise the nearest `func` or `#Preview` above it.
    private static func scope(of at: Int, in lines: [(line: Int, code: String)]) -> String {
        if let name = identifier(after: ["static let ", "static var "], in: lines[at].code) { return name }
        for index in stride(from: at, through: 0, by: -1) {
            let code = lines[index].code
            if code.contains("#Preview") { return "#Preview" }
            if let name = identifier(after: ["func "], in: code) { return name }
        }
        return "(top level)"
    }

    private static func identifier(after markers: [String], in code: String) -> String? {
        for marker in markers {
            guard let range = code.range(of: marker) else { continue }
            let name = code[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    // MARK: the verdict

    enum Finding: Equatable, CustomStringConvertible {
        case readerFoundNothing
        case unclassified(Site, reads: Int)
        case countChanged(Site, listed: Int, found: Int)
        case entryIsGone(Site)
        case reasonMissing(Site)

        var description: String {
            switch self {
            case .readerFoundNothing:
                return """
                    the walk read the app's Swift and found no unsorted read of the show table anywhere. That is \
                    a broken reader, not a clean app: the bare whole table read is the commonest spelling in it \
                    (L98).
                    """
            case let .unclassified(site, reads):
                return """
                    \(site) reads the show table with no sort (\(reads) read\(reads == 1 ? "" : "s")), and \
                    nothing says whether its reader depends on the order. SwiftData hands an unsorted read back \
                    in a different order on each read of a context holding unsaved changes (#4397), so a first \
                    match taken from it changes on unchanged data. Either pass the read through \
                    `Prospect.inKeyOrder(...)` on the same line, or add it to \
                    UnsortedProspectFetchAudit.classified with the reason its reader does not care (#4406).
                    """
            case let .countChanged(site, listed, found):
                return """
                    \(site) is classified for \(listed) unsorted read\(listed == 1 ? "" : "s") and now holds \
                    \(found). The reason was written about the reads that were there; a new one needs the \
                    question asked of it too (#4406).
                    """
            case let .entryIsGone(site):
                return """
                    UnsortedProspectFetchAudit.classified still lists \(site), and no unsorted read of the show \
                    table is there any more. An entry defending a read that is gone reads as a considered \
                    decision to the next person (L346). Delete it.
                    """
            case let .reasonMissing(site):
                return "\(site) is classified with no reason that begins with a word (L675)."
            }
        }
    }

    static func findings(found: [Site], classified: [Entry]) -> [Finding] {
        guard !found.isEmpty else { return [.readerFoundNothing] }
        var counts: [Site: Int] = [:]
        for site in found { counts[site, default: 0] += 1 }
        let listed = Dictionary(classified.map { ($0.site, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Finding] = []
        for (site, reads) in counts.sorted(by: { $0.key < $1.key }) {
            guard let entry = listed[site] else { out.append(.unclassified(site, reads: reads)); continue }
            if entry.reads != reads { out.append(.countChanged(site, listed: entry.reads, found: reads)) }
        }
        for entry in classified.sorted(by: { $0.site < $1.site }) {
            if counts[entry.site] == nil { out.append(.entryIsGone(entry.site)) }
            if entry.why.first.map({ !$0.isLetter && $0 != "`" }) ?? true { out.append(.reasonMissing(entry.site)) }
        }
        return out
    }
}

@Suite("Every unsorted read of the show table is classified (#4406)")
struct UnsortedProspectFetchGuardTests {

    @Test func everyUnsortedReadOfTheShowTableInTheAppIsOrderedOrClassified() {
        let found = AppSourceWalk.appFiles().flatMap {
            UnsortedProspectFetchAudit.unsortedReads(inSource: $0.text, file: $0.name)
        }
        let findings = UnsortedProspectFetchAudit.findings(found: found,
                                                          classified: UnsortedProspectFetchAudit.classified)
        #expect(findings.isEmpty, Comment(rawValue: findings.map(\.description).joined(separator: "\n\n")))
    }

    // MARK: the reader, against text it has to get right

    private func reads(_ source: String) -> [String] {
        UnsortedProspectFetchAudit.unsortedReads(inSource: source, file: "F.swift").map(\.scope)
    }

    @Test func aBareWholeTableReadIsFoundAndNamedByItsFunction() {
        let source = """
            enum Pass {
                static func run(in context: ModelContext) -> Int {
                    let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
                    return all.count
                }
            }
            """
        #expect(reads(source) == ["run"])
    }

    @Test func aReadOrderedByKeyOnItsOwnLineIsNotReported() {
        let source = """
            func run(in context: ModelContext) {
                let all = Prospect.inKeyOrder((try? context.fetch(FetchDescriptor<Prospect>())) ?? [])
            }
            """
        #expect(reads(source).isEmpty)
    }

    @Test func aSortedReadIsNotReportedEvenWhenItsSortIsOnALaterLine() {
        let source = """
            func run(in context: ModelContext) {
                let d = FetchDescriptor<Prospect>(
                    predicate: #Predicate { $0.statusRaw == "new" },
                    sortBy: [SortDescriptor(\\.naturalKey)])
            }
            """
        #expect(reads(source).isEmpty)
    }

    @Test func aPredicatedReadWithNoSortIsStillAReadAcrossLines() {
        let source = """
            func retire(in context: ModelContext) {
                let d = FetchDescriptor<Prospect>(
                    predicate: #Predicate { $0.statusRaw == "new" }
                )
            }
            """
        #expect(reads(source) == ["retire"])
    }

    @Test func aTypeAnnotationIsNotARead() {
        let source = """
            func measure(_ descriptor: FetchDescriptor<Prospect>) -> Double { 0 }
            """
        #expect(reads(source).isEmpty)
    }

    @Test func aReadInACommentIsNotARead() {
        let source = """
            func run() {
                // was `context.fetch(FetchDescriptor<Prospect>())` before #4406
            }
            """
        #expect(reads(source).isEmpty)
    }

    @Test func aStoredClosureIsNamedByItsProperty() {
        let source = """
            enum Scout {
                static let readTable: Read = { try $0.fetch(FetchDescriptor<Prospect>()) }
            }
            """
        #expect(reads(source) == ["readTable"])
    }

    @Test func aPreviewIsNamedAsOne() {
        let source = """
            func helper() {}
            #Preview {
                let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            }
            """
        #expect(reads(source) == ["#Preview"])
    }

    @Test func anUnsortedQueryOverShowsIsARead() {
        let source = """
            struct V: View {
                @Query private var everything: [Prospect]
                @Query(filter: #Predicate<Prospect> { $0.statusRaw == "new" })
                private var fresh: [Prospect]
                @Query(sort: \\Prospect.naturalKey) private var sorted: [Prospect]
                @Query private var inquiries: [Inquiry]
            }
            """
        #expect(reads(source) == ["everything", "fresh"])
    }

    // MARK: the verdict, one test per finding it can give (L151)

    private let site = UnsortedProspectFetchAudit.Site(file: "F.swift", scope: "run")
    private func entry(reads: Int = 1, why: String = "Per row.") -> UnsortedProspectFetchAudit.Entry {
        .init(file: "F.swift", scope: "run", reads: reads, kind: .orderFree, why: why)
    }

    @Test func aReaderThatFindsNothingIsRefused() {
        #expect(UnsortedProspectFetchAudit.findings(found: [], classified: [entry()]) == [.readerFoundNothing])
    }

    @Test func anUnclassifiedReadIsRefused() {
        #expect(UnsortedProspectFetchAudit.findings(found: [site], classified: [])
                == [.unclassified(site, reads: 1)])
    }

    @Test func aSecondReadInAClassifiedFunctionIsRefused() {
        #expect(UnsortedProspectFetchAudit.findings(found: [site, site], classified: [entry()])
                == [.countChanged(site, listed: 1, found: 2)])
    }

    @Test func anEntryWhoseReadIsGoneIsRefused() {
        let other = UnsortedProspectFetchAudit.Site(file: "G.swift", scope: "go")
        #expect(UnsortedProspectFetchAudit.findings(found: [other], classified: [entry()])
                == [.unclassified(other, reads: 1), .entryIsGone(site)])
    }

    @Test func anEntryWithNoReasonIsRefused() {
        #expect(UnsortedProspectFetchAudit.findings(found: [site], classified: [entry(why: "")])
                == [.reasonMissing(site)])
    }

    @Test func aClassifiedReadPasses() {
        #expect(UnsortedProspectFetchAudit.findings(found: [site], classified: [entry()]).isEmpty)
    }
}
