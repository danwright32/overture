import Testing
import Foundation

// #3341. When a check comes home with no way in, the triage card says so and its own words tell Dan to
// add a contact by hand. There was nowhere on that card to put one: the add-contact field lives inside
// DraftReviewView, which ProspectRowView only draws under `if item.hasDraft`, so acting on the card's
// advice cost a Prep run on a show the card had just called a long shot. That is the shape #2629 already
// fixed one layer down, where the add refused the only route the card told him to add (L109).
//
// WHICH cards offer it is derived from the app's own advice rather than chosen: `emptyAnswerHelp` tells
// him to add a contact by hand on five of the eight states and points him at another check on the other
// three, and `routeNamedButNotSupplied` says so outright ("another check is worth more here than a search
// by hand"). A control offered where the card does not ask for one is the noise #1595 cut back.
@Suite("Where the card asks for a contact by hand (#3341)")
struct HandAddedContactOfferTests {

    // Total over the enum, so a state added later cannot silently take a default. A default here is the
    // L113 defect exactly: a missing entry takes the fallback branch, and a fallback is indistinguishable
    // from a deliberate choice.
    @Test func everyEmptyReasonHasAnExplicitAnswer() {
        for reason in Reachability.EmptyReason.allCases {
            _ = ReachabilityCopy.adviceAsksForAHandAddedContact(reason)
        }
        // The `nil` reason is a real state (the default "couldn't find an email" sentence) and is asked
        // the same question, so it cannot be forgotten either.
        _ = ReachabilityCopy.adviceAsksForAHandAddedContact(Reachability.EmptyReason?.none)
    }

    // The classification, checked against the SENTENCE rather than restated beside it, so a rewrite of
    // the copy that stops advising a hand-added contact fails here instead of leaving a control standing
    // over advice that no longer exists (L210: a token check leaves the sentence beside it unverified).
    @Test func theOfferFollowsWhatTheCardActuallySays() {
        var mismatched: [String] = []
        for reason in Reachability.EmptyReason.allCases.map(Optional.some) + [nil] {
            let help = ReachabilityCopy.emptyAnswerHelp(reason)
            let advises = help.contains("add a contact by hand")
                || help.contains("a search by name often turns up an address")
            let offers = ReachabilityCopy.adviceAsksForAHandAddedContact(reason)
            if advises != offers {
                mismatched.append("\(String(describing: reason)): says \(advises), offers \(offers)")
            }
        }
        #expect(mismatched.isEmpty, Comment(rawValue: mismatched.joined(separator: "\n")))
    }

    // The three that point at another check instead, named so the decision is visible rather than
    // inferred from a passing total. `routeNamedButNotSupplied` is the sharpest: its own sentence says a
    // search by hand is worth LESS here, so a field inviting one would contradict the line above it.
    @Test func aCardThatAsksForAnotherCheckOffersNoField() {
        #expect(!ReachabilityCopy.adviceAsksForAHandAddedContact(Reachability.EmptyReason.routeNamedButNotSupplied))
        #expect(!ReachabilityCopy.adviceAsksForAHandAddedContact(Reachability.EmptyReason.onlySocialProfile))
        #expect(!ReachabilityCopy.adviceAsksForAHandAddedContact(Reachability.EmptyReason.unconfirmedSocialProfile))
    }

    // And the five that do ask, including the default sentence, which is the commonest of them all.
    @Test func aCardThatAsksForAContactOffersTheField() {
        for reason in [Reachability.EmptyReason.onlyVenueContact, .onlyPressContact, .noOneIdentified,
                       .namedButNoRoute, .nothingPublished] {
            #expect(ReachabilityCopy.adviceAsksForAHandAddedContact(reason), "\(reason) asks and is not offered")
        }
        #expect(ReachabilityCopy.adviceAsksForAHandAddedContact(Reachability.EmptyReason?.none))
    }
}
