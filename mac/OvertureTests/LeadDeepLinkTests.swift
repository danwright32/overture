import Testing
import Foundation

// #1927: the same show deep-linked twice in a row must land twice.
//
// This is #1774's bug, swept to its siblings rather than waiting for Dan to find each one. `.onChange`
// fires on a CHANGE, so a channel carrying WHERE to go cannot tell a repeat request from no request: the
// first tap sets it, the handler acts, and a second tap naming the same show sets it to the identical
// value, which is not a change and fires nothing. Dan hit exactly that on the search channel on
// 2026-08-01 ("I scrolled back up and then tried to search it again and then it's not working").
//
// The two deep-link channels did not have that bug, and the reason is worth stating because it is the
// whole point of this change: their handlers set the binding back to nil once done, so the next request
// was always a change from nil. That works, and it is a rule living nowhere but in two handlers. Delete
// either reset and the dead tap returns with every test still green. The identity below is what makes it
// structural instead.
@Suite("A repeat deep link is a second event (#1927)")
struct LeadDeepLinkTests {
    // The regression test for the shape #1774 hit, on the channel that had not hit it yet.
    @Test func twoLinksNamingOneShowAreDifferentEvents() {
        let first = LeadDeepLink(key: "2026-10-03|merkin-hall|tenet-vocal-artists")
        let second = LeadDeepLink(key: "2026-10-03|merkin-hall|tenet-vocal-artists")

        #expect(first.key == second.key)
        #expect(first != second)
    }

    // A request equals ITSELF, so a parent re-render handing the same one down again does not re-fire the
    // navigation and yank Dan off a row he has since scrolled to. This is the half a naive "never equal"
    // implementation (a fresh UUID read on every comparison) would get wrong.
    @Test func oneLinkHandedDownTwiceIsStillOneJump() {
        let request = LeadDeepLink(key: "2026-10-03|merkin-hall|tenet-vocal-artists")
        #expect(request == request)

        let copy = request
        #expect(copy == request)
    }

    @Test func aLinkStillCarriesTheShowItNames() {
        #expect(LeadDeepLink(key: "abc").key == "abc")
    }

    // The away-alert channel, which carries a SET. Two alerts naming the same leads are still two taps.
    @Test func twoAlertsNamingOneLeadSetAreDifferentEvents() {
        let first = LeadsDeepLink(keys: ["a", "b"])
        let second = LeadsDeepLink(keys: ["a", "b"])

        #expect(first.keys == second.keys)
        #expect(first != second)
    }

    @Test func oneAlertHandedDownTwiceIsStillOneEntry() {
        let request = LeadsDeepLink(keys: ["a", "b"])
        #expect(request == request)
    }

    @Test func anAlertStillCarriesItsLeads() {
        #expect(LeadsDeepLink(keys: ["a", "b"]).keys == ["a", "b"])
    }

    // Order is part of what the set names: `firstVisibleKey` walks these in order to pick the row to land
    // on, so two alerts naming the same leads in a different order are not the same request, and must not
    // be treated as one by an equality that sorts or set-compares (L228).
    @Test func theOrderOfTheLeadsIsPartOfWhatTheRequestSays() {
        let request = LeadsDeepLink(keys: ["a", "b"])
        #expect(request.keys != ["b", "a"])
    }
}
