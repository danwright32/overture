import Testing
import Foundation

// #3655 Phase 5a: whose data a searchable row carries out of a run, enforced rather than promised.
//
// `SearchableContact` is the FIRST identity to reach `QueueScopeRow`. Everything else on a row is a
// date, a score, a status or a send state; `RecipientFacts.standings` was checked when this was written
// and `RecipientStanding` carries no identity at all. So this type is the whole of the exposure, and it
// is a value type in a PUBLIC repository holding real people's names and addresses at run time.
//
// The routes out are ones no repository scanner inspects (L222). `scripts/check-test-identity-provenance.sh`
// and `TestDataEmailDomainGuardTests` read the REPOSITORY; a failure diff and a `dump()` land in
// `/tmp/overture-mutate-run.log` and `~/.overture-mac-test-diagnostics/` and in terminal scrollback.
//
// ALL THREE ROUTES ARE DRIVEN, including the two that were already safe when this was written. Only
// `dump()` leaked (it reflects stored properties and never consults `CustomStringConvertible`), and a
// guard written against that one route alone would pass while a toolchain change quietly reopened one of
// the others (L446, L11). The full reading, with its date and toolchain, is on #3655.
@Suite("A searchable contact cannot leave a run readable (#3655)")
struct PrivacyOfTheSearchableContactTests {

    // Invented for this test and matched as WHOLE tokens below, so a leak is unmistakable in the output
    // and no real identity is ever built here.
    private let nameToken = "Quillonbrace"
    private let localToken = "vantreshaw"

    private var populated: QueueScopeRow {
        QueueScopeRow(id: "k1", groupName: "A Group", discipline: "theater",
                      facts: RecipientFacts(standings: [], reachabilityAsHeld: nil,
                                            searchableContacts: [
                                                SearchableContact(name: "\(nameToken) Reed",
                                                                  email: "\(localToken)@example.invalid")
                                            ]))
    }

    private func assertRedacted(_ rendered: String, route: String) {
        #expect(rendered.contains(SearchableContact.redactedMark),
                Comment(rawValue: "\(route) rendered a searchable contact without the redaction marker, "
                        + "so nothing here proves the redaction ran at all: \(route) gave \(rendered.count) "
                        + "characters."))
        #expect(!rendered.contains(nameToken),
                Comment(rawValue: "\(route) LEAKED a contact's name. That text lands in a run log at a "
                        + "named path no repository scanner inspects (#3655 5a, L222, L446)."))
        #expect(!rendered.contains(localToken),
                Comment(rawValue: "\(route) LEAKED an address's local part. A scrub that replaces the "
                        + "domain and leaves the person as the local part is the exact shape L230 was "
                        + "minted from in this repository (#2839, #3110, #3140)."))
    }

    // THE ONE THAT LEAKED. `dump()` walks `Mirror(reflecting:)`, which is a different path from
    // `description` entirely, so this is the assertion the whole design was changed for.
    @Test("dump() of a row carrying contacts reaches no name and no address")
    func dumpIsRedacted() {
        var out = String()
        dump(populated, to: &out)
        assertRedacted(out, route: "dump()")
    }

    // A dump of the contact ON ITS OWN, not only nested in a row. The nested case is what a failing
    // comparison produces; this is what somebody debugging reaches for, and the empty mirror has to hold
    // for both or the guard covers the tidier half.
    @Test("dump() of the contact alone reaches no name and no address")
    func dumpOfTheContactAloneIsRedacted() {
        var out = String()
        dump(SearchableContact(name: "\(nameToken) Reed", email: "\(localToken)@example.invalid"), to: &out)
        assertRedacted(out, route: "dump() of the contact alone")
    }

    // The route a FAILING `#expect(rowA == rowB)` takes. Swift Testing renders its operands through
    // `String(describing:)`, so this is that rendering, taken without failing anything.
    @Test("a failure diff's rendering reaches no name and no address")
    func describingIsRedacted() {
        assertRedacted(String(describing: populated), route: "String(describing:)")
        assertRedacted("\(populated)", route: "string interpolation")
    }

    // What an `Issue.record` or a `Comment` built by interpolation carries.
    @Test("String(reflecting:) reaches no name and no address")
    func reflectingIsRedacted() {
        assertRedacted(String(reflecting: populated), route: "String(reflecting:)")
    }

    // The redaction must not be so total that the VALUE stops being usable, or the search it exists for
    // cannot run. This is what tells a working redaction apart from a type that lost its fields.
    @Test("the fields are still readable in code")
    func theFieldsSurviveTheRedaction() {
        let contact = SearchableContact(name: "\(nameToken) Reed", email: "\(localToken)@example.invalid")
        #expect(contact.name == "\(nameToken) Reed")
        #expect(contact.email == "\(localToken)@example.invalid")
    }
}
