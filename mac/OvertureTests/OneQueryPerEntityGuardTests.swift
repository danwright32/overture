import Testing
import Foundation

// #3507: a view that holds TWO `@Query` properties over the same entity reads that table twice on every
// store notification, and the second read is paid in full.
//
// Measured against the live store on 2026-09-05 (`QueueRenderPassLiveStoreCostTests`, 1153 rows): a
// repeat of the IDENTICAL descriptor over objects the context already held cost 151.7 ms against a cold
// 152.9 ms, and the property touch over every row that came back was 0.8 ms of that. So nothing is shared
// between two descriptors over one entity. `QueueView` held two, differing only in scope, and paid 85.2 ms
// a notification for the narrower one; it now derives that scope from the single whole-table query.
//
// WHY THIS REPORTS AGAINST A LIST RATHER THAN REFUSING OUTRIGHT. The same measurement says the cost is
// per row RETURNED, not per query: `RootView`'s second descriptor returns ONE row on Dan's store and
// costs 1.3 ms. A rule banning the shape would fire on that, which is the ordinary case, and be switched
// off within a day (L93). What is worth catching is a NEW pair nobody has priced, so each accepted pair
// carries the reason it is accepted, and a pair with no reason is the finding (L233).
//
// The list of offenders is DERIVED FROM THE SOURCE, never written out beside the accepted ones, because a
// hand-written registry only ever checks what somebody remembered (L96, L30).
enum QueryPairAudit {

    // One `@Query` declaration: the file that holds it, the property, and the entity it reads.
    struct Declaration: Equatable, Sendable {
        let file: String
        let property: String
        let entity: String
    }

    // A file that legitimately holds more than one query over one entity, and WHY. The reason is a claim
    // about that file's own cost, measured, not a permission slip.
    struct Accepted: Equatable, Sendable {
        let file: String
        let entity: String
        let why: String
    }

    static let accepted: [Accepted] = [
        Accepted(file: "RootView.swift", entity: "Prospect",
                 why: """
                 `toPrep` is filtered to kept shows with no draft and `allProspects` is the whole table. \
                 Measured on the live store 2026-09-05: the filtered descriptor returned 1 row and cost \
                 1.3 ms, against 85.2 ms for the 632 rows QueueView's second query returned, because the \
                 cost is per row returned. Deriving it in memory would also delete \
                 PrepQueueBuilder.needsPrepPredicate, whose existence #367 records as deliberate.
                 """),
    ]

    enum Finding: Equatable, CustomStringConvertible {
        case nothingWalked
        case noQueriesFound
        case unpricedPair(file: String, entity: String, properties: [String])
        case acceptedPairIsGone(file: String, entity: String)

        var description: String {
            switch self {
            case .nothingWalked:
                return "the walk found no app Swift at all, so this guard checked nothing (#2311, L98)"
            case .noQueriesFound:
                return """
                    the walk read app Swift and found no @Query declaration anywhere in it. That is a \
                    broken reader, not an app without queries: a guard that can no longer see the shape \
                    it judges reports every file as clean (L98).
                    """
            case let .unpricedPair(file, entity, properties):
                return """
                    \(file) holds \(properties.count) @Query properties over \(entity) \
                    (\(properties.joined(separator: ", "))), and no reason for it is recorded. \
                    SwiftData satisfies each independently, so that table is read once per query on \
                    every store notification, at roughly 0.13 ms per row returned measured on the live \
                    store (#3507). Either derive the narrower one from the wider, as QueueView now does \
                    through QueueModel.queueScope, or add it to QueryPairAudit.accepted with the \
                    measured reason it is cheap enough to keep.
                    """
            case let .acceptedPairIsGone(file, entity):
                return """
                    QueryPairAudit.accepted still carries \(file) for \(entity), and that file no longer \
                    holds two queries over it. An entry defending code that is gone reads as a considered \
                    decision to the next person and is argued with rather than deleted (L346).
                    """
            }
        }
    }

    // A `@Query` may span several lines, because its filter and sort arguments do. So the entity is read
    // from the DECLARATION the attribute belongs to, which is the next `var name: [Entity]` after it,
    // rather than from the attribute's own line.
    static func declarations(in file: AppSourceWalk.File) -> [Declaration] {
        let lines = file.text.components(separatedBy: "\n")
        var found: [Declaration] = []
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let line = lines[i]
            guard line.contains("@Query") else { continue }
            // Not a declaration: a mention inside a comment or a string.
            let beforeQuery = line.prefix(while: { $0 != "@" })
            if beforeQuery.contains("//") { continue }
            for ahead in i..<min(i + 12, lines.count) {
                guard let d = property(in: lines[ahead], file: file.name) else { continue }
                found.append(d)
                i = ahead
                break
            }
        }
        return found
    }

    // `private var name: [Entity]`, in whatever order the modifiers appear.
    private static func property(in line: String, file: String) -> Declaration? {
        guard let varRange = line.range(of: "var ") else { return nil }
        let rest = line[varRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        let type = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard type.hasPrefix("["), let close = type.firstIndex(of: "]") else { return nil }
        let entity = String(type[type.index(after: type.startIndex)..<close])
        guard !entity.isEmpty, entity.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return Declaration(file: file, property: name, entity: entity)
    }

    static func findings(_ files: [AppSourceWalk.File]) -> [Finding] {
        guard !files.isEmpty else { return [.nothingWalked] }
        let all = files.flatMap(declarations(in:))
        guard !all.isEmpty else { return [.noQueriesFound] }

        var pairs: [String: [String]] = [:]      // "file|entity" -> property names
        for d in all { pairs["\(d.file)|\(d.entity)", default: []].append(d.property) }

        var findings: [Finding] = []
        for (key, properties) in pairs where properties.count > 1 {
            let parts = key.components(separatedBy: "|")
            let (file, entity) = (parts[0], parts[1])
            guard accepted.contains(where: { $0.file == file && $0.entity == entity }) else {
                findings.append(.unpricedPair(file: file, entity: entity,
                                              properties: properties.sorted()))
                continue
            }
        }
        for entry in accepted where (pairs["\(entry.file)|\(entry.entity)"]?.count ?? 0) <= 1 {
            findings.append(.acceptedPairIsGone(file: entry.file, entity: entry.entity))
        }
        return findings.sorted { $0.description < $1.description }
    }
}

@Suite("One @Query per entity per view (#3507)")
struct OneQueryPerEntityGuardTests {

    private var appFiles: [AppSourceWalk.File] {
        AppSourceWalk.files(under: RepoRoot.url.appendingPathComponent("mac/Overture"))
    }

    @Test("no view reads one table through two queries without a priced reason")
    func noUnpricedQueryPairs() {
        let findings = QueryPairAudit.findings(appFiles)
        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n\n"))")
    }

    // The reader itself, because a guard whose parser has quietly stopped matching reports every file as
    // clean and nothing else goes red (L98, L215).
    @Test("the reader still sees the queries the app actually declares")
    func theReaderStillFindsQueries() {
        let all = appFiles.flatMap(QueryPairAudit.declarations(in:))
        #expect(all.count > 20, "found only \(all.count) @Query declarations, so the reader is broken")
        #expect(all.contains(where: { $0.file == "QueueView.swift" && $0.entity == "Prospect" }),
                "the queue's own prospect query was not seen, so nothing here was measured")
        #expect(all.contains(where: { $0.file == "ArchiveView.swift" && $0.entity == "Prospect" }))
    }

    // #3507's own change, asserted directly rather than only through the absence of a finding: an absence
    // is what a broken reader also produces.
    @Test("the queue reads the prospect table exactly once")
    func theQueueHoldsOneProspectQuery() {
        let queue = appFiles.filter { $0.name == "QueueView.swift" }
        #expect(queue.count == 1, "QueueView.swift was not found, so this asserted nothing")
        let prospectQueries = queue.flatMap(QueryPairAudit.declarations(in:))
            .filter { $0.entity == "Prospect" }
        #expect(prospectQueries.map(\.property) == ["allProspects"],
                "the queue holds \(prospectQueries.map(\.property)) over Prospect")
    }

    @Test("every accepted pair carries a reason")
    func everyAcceptedPairCarriesAReason() {
        for entry in QueryPairAudit.accepted {
            #expect(entry.why.count > 60,
                    "\(entry.file) is accepted for \(entry.entity) with no real reason written")
        }
    }
}
