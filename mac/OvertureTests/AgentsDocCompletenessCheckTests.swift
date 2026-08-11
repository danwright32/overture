import Testing
import Foundation

// The four-item completeness enumeration must stay in AGENTS.md.
//
// Two defects shipped from this repo on 2026-08-10 and were filed as new issues within hours of the
// changes that introduced them. #2453 named an activating issue for two of its three unwritten enum
// cases; the third had no writer and no issue, and became #2490. #2478 scoped out the sibling case
// where the same feed's client list empties, and that became #2495. Both were visible in the diff
// that created them, and both rules (name a writer for every new value, fix the class rather than
// the instance) were ALREADY written down here and in the global lessons.
//
// That is the point worth protecting. The rules were not missing; being made to answer them before
// the PR opened was. A rule that is stated but never demanded is indistinguishable from no rule,
// which is why this lives as a checked item rather than a paragraph somebody may or may not read
// (L27, and L57 on a correction that lives only in a transcript recurring).
//
// This test deliberately checks only that each item is STILL DEMANDED, never the wording around it.
// Asserting the prose would make this a second copy of the document, which is the defect one level
// up and exactly what AgentsDocSuiteCountsTests refuses to do with the suite's size.
@Suite("AGENTS.md still demands the PR completeness enumeration")
struct AgentsDocCompletenessCheckTests {

    // #1993: found through the shared search, which halts loudly if the repo is not there. A doc this
    // could not find would make every assertion below vacuously true, which is #1967's exact failure.
    private var agentsDoc: String {
        get throws {
            try String(contentsOf: RepoRoot.url.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        }
    }

    // One phrase per item, each short enough to survive ordinary rewording and specific enough that
    // deleting the item takes it with them.
    private let demandedItems = [
        "Every new value has a writer",
        "Every new value has a reader",
        "The class, not the instance",
        "Every guard was seen to fail",
    ]

    @Test func everyItemIsStillDemanded() throws {
        let doc = try agentsDoc
        let missing = demandedItems.filter { !doc.contains($0) }
        #expect(missing.isEmpty, """
            AGENTS.md no longer demands \(missing.joined(separator: ", ")) before a PR opens.
            Each of these exists because a defect shipped that it would have caught: a value nothing \
            writes reads as zero and zero looks like a measurement (#2490), and a sibling scoped out \
            without being named is the same defect left in place (#2495). If an item is genuinely \
            obsolete, delete it here too and say in the commit which defect class stopped happening.
            """)
    }

    // The enumeration is worthless if it can be satisfied by writing "checked". The document has to
    // keep asking for the list itself, which is the only form that makes a missing entry visible.
    @Test func theDocAsksForTheListRatherThanAnAssurance() throws {
        let doc = try agentsDoc
        #expect(doc.contains("Not \"checked\": the actual list."),
                """
                AGENTS.md no longer insists the PR body carry the actual enumeration. An author who \
                may answer "checked" reports on the rule instead of applying it, and a missing entry \
                becomes invisible again, which is the state that produced #2490 and #2495.
                """)
    }

    // The reason has to travel with the rule. A checklist whose provenance is forgotten reads as
    // ceremony and gets trimmed by the next person tidying this file (L65).
    @Test func theRuleStillCarriesTheDefectsThatCausedIt() throws {
        let doc = try agentsDoc
        #expect(doc.contains("#2490") && doc.contains("#2495"),
                """
                AGENTS.md no longer names the two defects this enumeration exists to prevent. Without \
                them it reads as ceremony, and ceremony is what gets cut the next time somebody \
                shortens this file.
                """)
    }
}
