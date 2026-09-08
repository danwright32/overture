import Testing
import Foundation

// #3653 step 3b.5 (milestone #80): the route cascade as ONE pure rule, so tier one can ask it without
// hand-rolling a second copy.
//
// WHY THIS HAS TO EXIST BEFORE THE SPLIT. `Prospect.reachabilityResultFromRecipients` is the rule, and
// its own comment says why it is one: "One definition, used by every writer, so the importer's upgrade
// and the row's own snapshot can never disagree about what counts as sendable." It had no seam, so a
// tier-one row needing the same verdict could only re-implement it, and a rule's data shared while the
// code applying it is copied is not consolidation (L107, L263, L370).
//
// AND IT COLLAPSES THE WALKS, which is what #3653's `recipientWalks == rowsInScope` pin needs. The
// cascade asked the contacts up to four separate times (`hasUnguardedAddress`, `isHeldByAGuard`,
// `usableContactFormURLs`, `socialRouteURLs`). Gathering the four facts in one pass and handing them to
// a pure rule is one walk.
//
// THE ORDER IS THE RULE, and each step of it was a decision somebody made and recorded, so the tests
// below assert the ORDER rather than each verdict in isolation. A show holding several routes at once is
// the only thing that can tell a correct cascade from a reordered one.
@Suite("The route cascade, as one rule (#3653)")
struct ReachabilityRouteCascadeTests {

    private func facts(address: Bool = false, guarded: Bool = false,
                       form: Bool = false, social: Bool = false) -> Reachability.RouteFacts {
        Reachability.RouteFacts(hasUnguardedAddress: address, hasGuardedAddress: guarded,
                                hasUsableContactForm: form, hasSocialRoute: social)
    }

    @Test func anUnguardedAddressBeatsEverythingElse() {
        #expect(Reachability.result(from: facts(address: true)) == .emailFound)
        // #1324's ranking: an address wins even when every other route is present too, which is the only
        // arrangement that can catch a reordered cascade.
        #expect(Reachability.result(from: facts(address: true, guarded: true, form: true, social: true))
                == .emailFound)
    }

    // #1324/#1798: an address held by a guard is REAL but not sendable, which is weak rather than absent.
    @Test func anAddressHeldByAGuardIsWeakRatherThanMissing() {
        #expect(Reachability.result(from: facts(guarded: true)) == .weakContactOnly)
        #expect(Reachability.result(from: facts(guarded: true, form: true, social: true)) == .weakContactOnly,
                "a guarded address must outrank both hand routes, which is #1324's tested order")
    }

    // #1626/#2612: a form on the act's own site is the stronger of the two hand routes.
    @Test func aFormOnTheirOwnSiteOutranksASocialProfile() {
        #expect(Reachability.result(from: facts(form: true)) == .contactFormOnly)
        #expect(Reachability.result(from: facts(form: true, social: true)) == .contactFormOnly,
                "a show holding both hand routes must name the one Dan reaches for first (#2612)")
    }

    @Test func aSocialProfileIsARouteRatherThanTheAbsenceOfOne() {
        #expect(Reachability.result(from: facts(social: true)) == .socialOnly)
    }

    @Test func nothingAtAllIsTheOnlyWayToNoEmailFound() {
        #expect(Reachability.result(from: facts()) == .noEmailFound)
    }

    // THE CONSOLIDATION ITSELF, because a shared rule with one caller is not shared, and a second
    // hand-rolled copy is exactly what this exists to prevent (L263, L370).
    @Test("the cascade has one definition and the Prospect rule calls it")
    func theProspectRuleGoesThroughTheSharedCascade() throws {
        let prospect = SourceGuardHelper.source("Overture/Domain/Prospect.swift")
        // Sliced here rather than through `SourceGuardHelper`, which reads FUNCTION bodies and this is a
        // computed property. The slice runs from the declaration to the next closing brace at the type's
        // own indent, which is where a computed property ends in this file.
        let opening = "var reachabilityResultFromRecipients: Reachability.ProbeResult {"
        let start = try #require(prospect.range(of: opening),
                                 "the rule is gone, so this guard is about nothing (L98)")
        let rest = prospect[start.upperBound...]
        let close = try #require(rest.range(of: "\n    }"),
                                 "could not find where the rule ends, so nothing below was measured")
        let body = String(rest[..<close.lowerBound])
        #expect(body.contains("Reachability.result(from:"),
                Comment(rawValue: "`reachabilityResultFromRecipients` no longer goes through the shared "
                        + "cascade, so there are two definitions of what counts as reachable and they "
                        + "can drift. Its own comment says it exists so the importer's upgrade and the "
                        + "row's snapshot can never disagree (L263, L370)."))
        // And the arms are GONE from it, not merely joined by a call: a body that still branches on
        // `hasUnguardedAddress` itself is a second copy standing beside the shared one.
        #expect(!body.contains("return .emailFound"),
                Comment(rawValue: "the cascade's arms are still written out here as well as in the "
                        + "shared rule, which is two definitions rather than one."))
    }
}
