import Testing
import Foundation

// #2893: `method: "form_or_dm"` means "reach this person through a form or a DM". A contact carrying it
// with no `formUrl` names the way in and supplies none. The app discarded both such contacts correctly
// and then reported the show as `named_but_no_route`, whose card says "a check worked out who is putting
// this on and found no way to reach any of them": a claim about a FINISHED search, made about a run that
// stated a route type and skipped the step that finds one (L11).
//
// Measured 2026-08-17, and the run reasoned its way into the shape deliberately: mid-run it read the
// app's own Swift and concluded "Good, `formUrl` is optional. That confirms a `form_or_dm` contact can
// carry no `formUrl`". `formUrl` is optional because the other two methods have no form. An AI writer
// that can read the code consuming its output takes the schema's permissiveness as permission (L167).
@Suite("A route named but not supplied")
struct ARouteNamedButNotSuppliedTests {
    private func contact(method: String?, email: String? = nil, formUrl: String? = nil) -> PrepContact {
        PrepContact(name: "A Person", role: nil, tier: nil, email: email, method: method,
                    confidence: "low", formUrl: formUrl, provenance: "performer",
                    overrideBody: nil, sourceUrl: nil)
    }

    // MARK: - The contradiction itself, per method

    @Test func aFormOrDmWithNoFormUrlNamesARouteItDoesNotHave() {
        #expect(Reachability.declaredRouteIsMissing(contact(method: "form_or_dm")))
        #expect(Reachability.declaredRouteIsMissing(contact(method: "form_or_dm", formUrl: "   ")))
    }

    // The siblings, derived from `ContactMethod` rather than remembered: every method promises a field,
    // and each fails the same way (L30).
    @Test func anAddressMethodWithNoAddressIsTheSameContradiction() {
        #expect(Reachability.declaredRouteIsMissing(contact(method: "named_decision_maker")))
        #expect(Reachability.declaredRouteIsMissing(contact(method: "generic_inbox")))
        #expect(Reachability.declaredRouteIsMissing(contact(method: "generic_inbox", email: "")))
    }

    @Test func aMethodCarryingWhatItPromisesIsNotAContradiction() {
        #expect(!Reachability.declaredRouteIsMissing(contact(method: "form_or_dm",
                                                            formUrl: "https://example.invalid/contact")))
        #expect(!Reachability.declaredRouteIsMissing(contact(method: "generic_inbox",
                                                            email: "info@example.invalid")))
        #expect(!Reachability.declaredRouteIsMissing(contact(method: "named_decision_maker",
                                                            email: "jo@example.invalid")))
    }

    // A bare homepage root is a weaker route than a form and still a route: it lands Dan on the act's
    // own site. Refusing it would delete a usable way in to enforce a tidier shape (L116). Two contacts
    // in the same 2026-08-17 run carried one.
    @Test func aBareHomepageRootStillCountsAsARoute() {
        #expect(!Reachability.declaredRouteIsMissing(contact(method: "form_or_dm",
                                                            formUrl: "https://example.invalid/")))
    }

    // Silence is not a claim. An absent or unrecognised method declares no route, so there is nothing to
    // contradict, and reading it as a claim would fire this on every run predating the vocabulary.
    @Test func aContactDeclaringNoMethodIsNotAContradiction() {
        #expect(!Reachability.declaredRouteIsMissing(contact(method: nil)))
        #expect(!Reachability.declaredRouteIsMissing(contact(method: "carrier_pigeon")))
    }

    // #2893: the value a run uses to say it found the person and no route. It promises nothing, so it
    // can contradict nothing, and it is what a name-only performer entry carries.
    //
    // It exists because `method` is REQUIRED by the results contract, so "leave it out" was not
    // available: the runbook's oldest rule in that section says a named performer is ALWAYS surfaced,
    // and asking for a route-naming method on somebody with no route is what produced #2893 in the first
    // place. Caught by the paid eval, which failed `five-named-performers-none-dropped` on the first
    // attempt at this fix with "results[0].contacts[1].method must be a non-empty string".
    @Test func noRouteFoundIsAnHonestAnswerRatherThanAContradiction() {
        #expect(!Reachability.declaredRouteIsMissing(contact(method: "no_route_found")))
        #expect(ContactMethod(rawValue: "no_route_found") == .noRouteFound)
    }

    // And a show whose only contacts say that reads as names with no route, which is the true finding.
    @Test func aShowOfNameOnlyPerformersReadsAsNamesWithNoRoute() {
        #expect(Reachability.emptyReason(afterIngesting: [contact(method: "no_route_found"),
                                                          contact(method: "no_route_found")],
                                         usableRecipients: 0) == .namedButNoRoute)
    }

    // MARK: - What the show is left saying

    @Test func aRunThatNamedARouteAndSuppliedNoneGetsItsOwnReason() {
        let reason = Reachability.emptyReason(afterIngesting: [contact(method: "form_or_dm"),
                                                               contact(method: "form_or_dm")],
                                              usableRecipients: 0)
        #expect(reason == .routeNamedButNotSupplied)
    }

    // One contradictory contact is enough: the run has shown it will state a route it did not find, so
    // nothing it emitted for this show establishes that anything was searched properly.
    @Test func oneContradictoryContactDecidesItForTheWholeShow() {
        let reason = Reachability.emptyReason(
            afterIngesting: [contact(method: "named_decision_maker"),
                             contact(method: "form_or_dm", formUrl: "https://instagram.com/someact")],
            usableRecipients: 0)
        #expect(reason == .routeNamedButNotSupplied)
    }

    // The two reasons it must not be confused with, each still reached by its own shape.
    @Test func aGenuineNoRouteAndAGenuineSocialOnlyKeepTheirOwnReasons() {
        #expect(Reachability.emptyReason(afterIngesting: [contact(method: nil)], usableRecipients: 0)
                == .namedButNoRoute)
        #expect(Reachability.emptyReason(
            afterIngesting: [contact(method: "form_or_dm", formUrl: "https://instagram.com/someact")],
            usableRecipients: 0) == .onlySocialProfile)
    }

    // Somebody usable survived, so there is nothing to explain at all.
    @Test func aShowWithSomebodyReachableSaysNothing() {
        #expect(Reachability.emptyReason(afterIngesting: [contact(method: "form_or_dm")],
                                         usableRecipients: 1) == nil)
    }

    // MARK: - What Dan reads

    // The badge deliberately breaks the "Only" family the other four share: those report a finished
    // search that found little, and this reports a search that stopped mid step.
    @Test func theBadgeSaysTheCheckFellShortRatherThanTheShowBeingHard() {
        let badge = ReachabilityCopy.emptyAnswerBadge(.routeNamedButNotSupplied)
        #expect(badge == "Check named a route it never found")
        #expect(badge != ReachabilityCopy.emptyAnswerBadge(.namedButNoRoute))
        #expect(badge != ReachabilityCopy.emptyAnswerBadge(.onlySocialProfile))
    }

    // Every reason must earn a DISTINCT sentence Dan can act on differently, or a new one is a second
    // line telling him nothing the first did not (#843).
    @Test func everyEmptyReasonStillSaysSomethingDifferent() {
        let badges = Reachability.EmptyReason.allCases.map { ReachabilityCopy.emptyAnswerBadge($0) }
        let helps = Reachability.EmptyReason.allCases.map { ReachabilityCopy.emptyAnswerHelp($0) }
        #expect(Set(badges).count == badges.count)
        #expect(Set(helps).count == helps.count)
    }

    @Test func theHelpSaysAnotherCheckIsWorthMoreThanASearchByHand() {
        let help = ReachabilityCopy.emptyAnswerHelp(.routeNamedButNotSupplied)
        #expect(help.contains("another check is worth more here than a search by hand"))
    }
}
