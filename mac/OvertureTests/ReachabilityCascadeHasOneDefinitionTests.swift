import Testing
import Foundation

// #3653 step 3b.5's remaining half: the route cascade keeps ONE definition.
//
// #3670 extracted `Reachability.result(from:)` so that a tier-one row could ask the same question the
// stored verdict is written from, and `Prospect.reachabilityResultFromRecipients` now calls it. What
// #3653 asked for beside that, and what did not ship with it, is the guard: the whole value of the
// extraction is that a second definition cannot appear, and nothing was asserting that.
//
// The rule's own comment states the stakes: it exists so "one definition, used by every writer" holds,
// "so the importer's upgrade and the row's own snapshot can never disagree" (L107, L263, L370).
//
// WHAT THIS ASSERTS, and it is deliberately not what #3653 first wrote. That plan asked for "exactly the
// two call sites, seen to fail by adding a third", which is unbuildable as stated: `Prospect.swift`
// alone calls it three times, once per arm. Restated over CONSUMERS, which is the quantity that matters.
//
// TWO CANDIDATE GUARDS WERE MEASURED AND REJECTED FIRST, and both look reasonable, so they are recorded
// here rather than left to be tried again (L248: a finding that rules a capability out must be measured
// under the same control as one that rules it in).
//
//   1. "The cascade's verdicts are returned from one place." Measured 2026-09-08 across `mac/Overture`:
//      `.emailFound` is produced in 4 files, `.contactFormOnly` in 4, `.socialOnly` in 4, `.noEmailFound`
//      in 4 or more. `Ranker` matches on them, `ContactFormResultMigration` writes them, the row view
//      renders them. All legitimate. A guard there fires on the ordinary case and is switched off within
//      a day (L93).
//   2. "Nobody names the `RouteFacts` fields outside `Reachability`." `hasUnguardedAddress` alone appears
//      in `PrepImporter`, `OrgReachabilityAnswer` and `Recipient` as an ordinary concept name, so that
//      half fires on the ordinary case too. It is only the FOUR TOGETHER that mean the cascade.
//
// So the subject is the recorded consumer set, checked two ways that must agree. A new consumer is NOT
// automatically wrong, which is why the message says what to check rather than just refusing: what must
// never happen is a consumer that decides the cascade FOR ITSELF.
@Suite("The route cascade has one definition (#3653 step 3b.5)")
struct ReachabilityCascadeHasOneDefinitionTests {

    /// The app files allowed to consume the cascade, each because it has been read and is not a second
    /// definition of it. Grows deliberately: Phase 3c's `RecipientFacts` is the next expected entry.
    private static let recordedConsumers: Set<String> = ["Prospect.swift"]

    /// The four facts together. Any file naming ALL of them is either the rule or something deciding the
    /// same question from the same inputs, which is the shape a second definition takes.
    private static let routeFactNames = ["hasUnguardedAddress", "hasGuardedAddress",
                                         "hasUsableContactForm", "hasSocialRoute"]

    private static let ruleFile = "Reachability.swift"

    private static func appFiles() -> [AppSourceWalk.File] {
        AppSourceWalk.files(under: RepoRoot.app)
    }

    @Test func onlyTheRecordedConsumersCallTheCascade() {
        let callers = Set(Self.appFiles()
            .filter { $0.text.contains("Reachability.result(from") }
            .map(\.name))
            .subtracting([Self.ruleFile])
        #expect(callers == Self.recordedConsumers,
                Comment(rawValue: """
                    the consumers of Reachability.result(from:) are \(callers.sorted()) against a \
                    recorded \(Self.recordedConsumers.sorted()). A NEW consumer is not automatically \
                    wrong: the extraction exists so a second caller can share the rule. What it must \
                    not be is a caller that then decides any part of the cascade for itself. Read it, \
                    then add it here.
                    """))
    }

    @Test func nobodyOutsideTheRuleAndItsConsumersNamesAllFourRouteFacts() {
        let namingAll = Set(Self.appFiles()
            .filter { file in Self.routeFactNames.allSatisfy { file.text.contains($0) } }
            .map(\.name))
            .subtracting([Self.ruleFile])
        #expect(namingAll.subtracting(Self.recordedConsumers).isEmpty,
                Comment(rawValue: """
                    \(namingAll.subtracting(Self.recordedConsumers).sorted()) name all four RouteFacts \
                    without being a recorded consumer of Reachability.result(from:). Gathering those \
                    four facts and not handing them to the cascade is what a second definition looks \
                    like: the importer's upgrade and the row's own snapshot would then be able to \
                    disagree, which is the whole thing the extraction prevents (L107, L263).
                    """))
    }

    /// The two nets must agree, or one is answering for the other and neither is checked (L70, L178).
    /// A consumer that calls the cascade and does NOT gather the facts is fine; one that gathers all four
    /// and never calls it is the defect. This asserts the recorded set is exactly the overlap.
    @Test func theTwoNetsAgreeAboutWhoTheConsumersAre() {
        let files = Self.appFiles()
        let callers = Set(files.filter { $0.text.contains("Reachability.result(from") }.map(\.name))
            .subtracting([Self.ruleFile])
        let gatherers = Set(files.filter { f in Self.routeFactNames.allSatisfy { f.text.contains($0) } }
            .map(\.name))
            .subtracting([Self.ruleFile])
        #expect(gatherers.isSubset(of: callers),
                Comment(rawValue: """
                    \(gatherers.subtracting(callers).sorted()) gather all four route facts and never \
                    call the cascade. That is the second definition this suite exists to find.
                    """))
    }

    /// And the rule itself is still there and still ordered, so the guards above are not standing over a
    /// function that has been emptied (L1: a guard is only real once what it guards can be seen).
    @Test func theCascadeItselfStillHoldsItsOrderedArms() throws {
        let source = SourceGuardHelper.source("Overture/Domain/Reachability.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "result", in: source),
                                "Reachability.result(from:) is gone, so every guard above is vacuous")
        let arms = ["hasUnguardedAddress", "hasGuardedAddress", "hasUsableContactForm", "hasSocialRoute"]
        var searchedFrom = body.startIndex
        for arm in arms {
            let found = try #require(body.range(of: arm, range: searchedFrom..<body.endIndex),
                                     Comment(rawValue: "the cascade no longer asks \(arm), or asks it out "
                                             + "of order. THE ORDER IS THE RULE and every step of it was "
                                             + "a decision somebody recorded (#3387, #1324, #1626)."))
            searchedFrom = found.upperBound
        }
    }
}
