import Testing
import Foundation

// #1778. Every row action in `ProspectMutations` begins by finding the show behind the row Dan
// pressed. Fifty of them did it inline and returned silently when it found nothing:
//
//     guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
//
// So the control is offered, Dan presses it, and nothing happens with nothing said. That is this
// issue's own test ("is there an input for which this control is shown and pressing it changes
// nothing") answered yes, fifty times over, by a route the issue did not name: it expected a DOMAIN
// rule refusing, and this is the lookup itself.
//
// The refusals BESIDE it already say their piece. `recordOutcome` guards the outcome menu and
// acknowledges `ShowOutcome.refusedLine` when the rule declines. Only the lookup was silent, and it is
// the one every action shares, so one helper covers all fifty (L30).
//
// #4357 slice I2: and the lookup is no longer by KEY at all. A key-only lookup finds whichever row holds
// the key, which after a merge is a survivor Dan did not press (B3), so every action now resolves the
// card's store identifier through `ShowIdentity`, which says each refusal's own cause. This guard used to
// count `prospects.first(where:` lines; it now refuses any show lookup written in this file at all,
// because the only lookup allowed is the one rule, which lives in `ShowIdentity`.
//
// Whether a stale snapshot can really outlive its model is not the point. A silent no-op cannot be
// told from a control that is broken, and if it never fires the message costs nothing (L11, L98).
@MainActor
@Suite("A control that cannot find its show says so (#1778)")
struct AControlThatFindsNothingSaysSoTests {

    // The spellings of a show lookup written by hand: a predicate on a show's key or identifier, or a
    // walk of the rows for one. A row's own recipients are walked by `recipients.first(where:` and are
    // not shows, so they are deliberately not matched.
    private static func isAShowLookup(_ code: String) -> Bool {
        code.contains("$0.naturalKey") || code.contains("persistentModelID")
            || code.contains("prospects.first") || code.contains("prospects.last")
            || code.range(of: #"naturalKey\s*=="#, options: .regularExpression) != nil
    }

    @Test func noRowActionFindsItsShowExceptThroughTheOneResolver() throws {
        let source = SourceGuardHelper.source("Overture/UI/ProspectMutations.swift")
        #expect(!source.isEmpty, "Could not read ProspectMutations.swift, so nothing was measured.")

        // Comments stripped and nothing skipped: a comment ABOUT the old lookup is how this file records
        // why it went, and must not read as the lookup coming back (L103).
        let code = SwiftSource.scannableLines(in: source, skipping: [])
        let lookups = code.filter { Self.isAShowLookup($0.code) }
            .map { "line \($0.line)  \($0.code.trimmingCharacters(in: .whitespaces))" }

        #expect(lookups.isEmpty, """
            ProspectMutations finds a show by hand. A lookup by key lands on whichever row holds the key, \
            which after a merge is a show Dan did not press (#4357 slice I2, B3), and a lookup that returns \
            silently is #1778. Resolve the card through ShowIdentity, which refuses by name.
            \(lookups.joined(separator: "\n"))
            """)

        // UNMEASURED is its own outcome (L98): a file with nothing left to find and a scan that read the
        // wrong file leave the same empty list, so the actions must be SEEN going through the resolver.
        let throughTheResolver = code.filter {
            $0.code.contains("shows.show(for: item, feedback: feedback)")
                || $0.code.contains("shows.show(forKey: naturalKey, org: nil, feedback: feedback)")
        }.count
        #expect(throughTheResolver > 40, """
            Only \(throughTheResolver) actions resolve their show through the resolver, so this guard \
            is reading something other than the actions it exists for.
            """)
        // And the resolver's own answer is the one rule: through the card's identity, never its key.
        let resolver = SourceGuardHelper.source("Overture/Domain/ShowIdentity.swift")
        let answer = try #require(SourceGuardHelper.bodyOfFunction(named: "show", in: resolver),
                                  "ShowResolver.show(for:feedback:) was not found, so nothing was measured")
        #expect(answer.contains("ShowIdentity(item)") && answer.contains("resolve(in: self)"),
                "ShowResolver.show(for:) no longer resolves the card through ShowIdentity")
    }

    // #4357 slice I2, the PARAMETER half. A lookup can only be written against what an action is handed,
    // and an action handed `[Prospect]` is handed the thing the old key lookup walked, with nothing at the
    // signature saying how it may be searched. Every action takes `shows: some ShowResolver` instead, which
    // offers resolution by identity, and the row factory takes `ShowsInHand`, which is read on a press. So
    // a parameter of the array shape coming back is refused here, whatever it is named.
    //
    // A local or a return value of `[Prospect]` is not a parameter and is not matched: `siblings` and
    // `bulkReprepEligible` RETURN rows they resolved, and that is their whole job.
    private static func declaresAnArrayOfShows(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") { return false }
        // A label, an optional internal name, a colon, then the array: alone, or returned by a closure.
        // Anchored at the start of a parameter, which is the line's start or just after `(` or `,`.
        let parameter = #"(?:^|[(,])\s*(?:_\s+)?[A-Za-z]\w*(?:\s+[A-Za-z]\w*)?\s*:\s*(?:@escaping\s*)?(?:\(\)\s*->\s*)?\[Prospect\]"#
        return code.range(of: parameter, options: .regularExpression) != nil
    }

    @Test func noRowActionIsHandedAnArrayOfShows() {
        var offenders: [String] = []
        var resolverParameters = 0
        for file in ["Overture/UI/ProspectMutations.swift", "Overture/UI/ProspectRowFactory.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty, "Could not read \(file), so nothing was measured.")
            let code = SwiftSource.scannableLines(in: source, skipping: [])
            offenders += code.filter { Self.declaresAnArrayOfShows($0.code) }
                .map { "\(file) line \($0.line)  \($0.code.trimmingCharacters(in: .whitespaces))" }
            resolverParameters += code.filter {
                $0.code.contains("shows: some ShowResolver") || $0.code.contains("shows: ShowsInHand")
            }.count
        }
        #expect(offenders.isEmpty, """
            A row action is handed an array of shows. An array can be searched by key, which after a merge \
            finds a survivor Dan did not press (#4357 slice I2, B3). Take `shows: some ShowResolver` and \
            resolve the card through it.
            \(offenders.joined(separator: "\n"))
            """)
        // UNMEASURED (L98): the parameters this scan exists for must be SEEN, or a scan of the wrong file,
        // or a renamed label, would read as a clean pass.
        #expect(resolverParameters > 50, """
            Only \(resolverParameters) actions take `shows: some ShowResolver`, so this scan is reading \
            something other than the actions it exists for.
            """)
    }

    // The scan's own pattern, seen to separate the shapes it must from the ones it must not. A pattern that
    // never matched anything would pass the file scan above on every tree (L1, L104).
    @Test func theParameterPatternTellsAParameterFromALocalOrAReturn() {
        #expect(Self.declaresAnArrayOfShows("    static func a(_ item: QueueItem, prospects: [Prospect], context: ModelContext) {"))
        #expect(Self.declaresAnArrayOfShows("                          rows: [Prospect], context: ModelContext,"))
        #expect(Self.declaresAnArrayOfShows("    static func b(_ shows: [Prospect], now: Date) -> [Prospect] {"))
        #expect(Self.declaresAnArrayOfShows("    static func c(in shows: [Prospect]) -> Int {"))
        #expect(Self.declaresAnArrayOfShows("    static func row(_ item: QueueItem, prospects: @escaping () -> [Prospect], x: Int) {"))
        #expect(!Self.declaresAnArrayOfShows("    private static func siblings(of item: QueueItem, in shows: some ShowResolver) -> [Prospect] {"))
        #expect(!Self.declaresAnArrayOfShows("        let every: [Prospect] = shows.everyShow"))
        #expect(!Self.declaresAnArrayOfShows("    static func d(_ item: QueueItem, shows: some ShowResolver, context: ModelContext) {"))
    }
}
