import Testing
import Foundation

// #3846: how many LIVE whole-table reads of the prospect table the app may hold at once.
//
// MEASURED 2026-09-12 by #3764, and it is why this is a rule rather than a preference: two identical
// BARE `FetchDescriptor<Prospect>`s held by two live views share NOTHING. The second costs 99.6% of the
// first, 158.8 ms against 159.5 ms over 1,238 rows, which is exactly what #3507 found for two held by
// ONE view. So every extra live whole-table `@Query` is another whole table read on EVERY store change,
// for as long as that view is on screen, and against an end-to-end store change of 350.7 ms one extra
// query is not a detail: it is the largest single term in the whole change.
//
// THE RULE. A view presented over another view that already holds the whole table does not hold its own.
// `RootView` is the owner of the one always-live read and hands the rows down; `QueueView` and
// `ArchiveView` receive them.
//
// This is a RATCHET, not a triage log. The list below is the whole set of whole-table prospect queries
// the app source contains, enumerated from the source on every run rather than remembered, and the test
// asserts EQUALITY: a new one fails the suite, and removing one fails until this list is edited down.
// An entry may only ever leave.
@Suite("One whole-table prospect query per screen (#3846)")
struct OneWholeTableProspectQueryTests {

    // Every `@Query` declaration in the app whose element type is `[Prospect]` and which carries NO
    // `filter:`, so it reads the whole table. Derived from the source rather than from a hand-kept list,
    // because a hand-kept one only ever checks what somebody remembered (L96).
    private static func wholeTableProspectQueries() -> [String] {
        // Through `AppSourceWalk` rather than a private enumerator, so this inherits the refusal that
        // separates "walked the app and found nothing wrong" from "walked nothing" (#2311, L98). A guard
        // standing on its own walker passes silently the day the path resolves elsewhere.
        AppSourceWalk.appFiles()
            .filter { file in
                file.text.components(separatedBy: .newlines).contains { declaresAWholeTableQuery($0) }
            }
            .map(\.name)
            .sorted()
    }

    // ONE reading of what a whole-table prospect query looks like, used by both tests below, so the two
    // cannot come to disagree about what they are counting (L70).
    private static func declaresAWholeTableQuery(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // A COMMENT naming the declaration is not a declaration. `FollowUpsRenderPass.swift` quotes this
        // exact shape in its header to explain what it replaced, and a scan that counted it would report
        // a query that does not exist (L135).
        guard !line.hasPrefix("//") else { return false }
        guard line.contains("@Query"), line.contains("[Prospect]") else { return false }
        // A FILTERED query reads a fraction of the table and is not what this rule is about.
        return !line.contains("filter:")
    }

    // The whole set, with the reason each one is still here. An entry carrying no reason is evidence it
    // was never reasoned about (L233), so every one names either its ownership or the issue that owes it.
    private static let allowed: [String: String] = [
        // THE OWNER. One live whole-table read, held by the view that is always on screen, handed down to
        // `QueueView` and to `ArchiveView` rather than re-read by each of them.
        "RootView.swift": "the owner: the app's one always-live whole-table read",

        // The eight sheets. Each is presented OVER RootView, so each one that is open costs a second
        // whole table read per store change on top of the owner's. #3871 is the issue that converts them,
        // ranked by whether Dan actually sits on the sheet: `OutcomePatternsView` is the worst, because it
        // CONTAINS `WrittenOffBacklogSection` and `EmptyAnswerSection`, which hold their own, and can
        // present `ExperimentReportView`, which holds a fourth.
        "OutcomePatternsView.swift": "sheet over the owner, owed to #3871",
        "WrittenOffBacklogSection.swift": "section inside OutcomePatternsView, owed to #3871",
        "EmptyAnswerSection.swift": "section inside OutcomePatternsView, owed to #3871",
        "ExperimentReportView.swift": "sheet from inside OutcomePatternsView, owed to #3871",
        "FollowUpsView.swift": "sheet over the owner, owed to #3871",
        "OrganisationsView.swift": "sheet over the owner, owed to #3871",
        "SourcesView.swift": "sheet over the owner, owed to #3871",
        "StruckAddressesView.swift": "sheet over the owner, owed to #3871",
    ]

    @Test func everyWholeTableProspectQueryIsOneThisRuleAccountsFor() throws {
        let found = Self.wholeTableProspectQueries()
        // The positive control first: a scan that found NOTHING would pass every claim below while
        // measuring nothing at all, and this app certainly holds some (L98).
        #expect(found.count >= Self.allowed.count,
                Comment(rawValue: "the scan found \(found.count) whole-table prospect queries in the app "
                        + "source, fewer than the \(Self.allowed.count) this list accounts for, so the "
                        + "scan has stopped being able to see them rather than the app having lost any"))

        let unexpected = found.filter { Self.allowed[$0] == nil }
        #expect(unexpected.isEmpty, Comment(rawValue:
            "a NEW live whole-table prospect query in \(unexpected.joined(separator: ", ")). Measured "
            + "2026-09-12, a second identical bare descriptor held by a second live view costs 99.6% of "
            + "the first (158.8 ms against 159.5 ms over 1,238 rows), so this adds a whole table read to "
            + "every store change for as long as that view is on screen. Take the rows from the view "
            + "that presents this one, the way ArchiveView takes them from RootView, or add the entry "
            + "here with the issue that owes it"))

        let gone = Self.allowed.keys.filter { !found.contains($0) }
        #expect(gone.isEmpty, Comment(rawValue:
            "\(gone.sorted().joined(separator: ", ")) no longer holds a whole-table prospect query, which "
            + "is the direction this ratchet exists to hold. Delete the entry from `allowed` in the same "
            + "change, so the list stays the count of what is left rather than of what was once true"))
    }

    // The two the measurement priced, named individually, because the list above would go on passing if
    // one of them quietly took its own query back and an entry was added for it.
    @Test func theQueueAndTheArchiveTakeTheirRowsFromTheOwner() throws {
        let app = AppSourceWalk.appFiles()
        for name in ["QueueView.swift", "ArchiveView.swift"] {
            let file = try #require(app.first { $0.name == name },
                                    Comment(rawValue: "\(name) was not in the app walk at all"))
            // Bound to a Bool first, and the file's TEXT is never an operand: a failing expectation
            // renders what it compared, and a whole source file between the reader and the sentence
            // explaining the failure is how a red run stops being readable (L445).
            let declares = file.text.components(separatedBy: .newlines).contains(where: Self.declaresAWholeTableQuery)
            #expect(!declares, Comment(rawValue:
                "\(name) holds its own whole-table prospect query again. It is presented by RootView, "
                + "which already holds one, so this is a second whole table read on every store change "
                + "(158.8 ms measured 2026-09-12) for a list RootView could have handed it"))
        }

        let rootView = try #require(app.first { $0.name == "RootView.swift" }).text
        let handsTheQueueItsRows = rootView.contains("allProspects: allProspects,")
        #expect(handsTheQueueItsRows,
                "RootView no longer hands the queue its rows, so the queue is deriving from something else")
        let handsTheArchiveItsRows = rootView.contains("ArchiveView(prospects: allProspects,")
        #expect(handsTheArchiveItsRows,
                "RootView no longer hands the Archive its rows, so the sheet is reading the table itself")
    }
}
