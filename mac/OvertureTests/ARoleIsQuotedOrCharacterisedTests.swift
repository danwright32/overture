import Testing
import Foundation
import SwiftData

// #3078. A role the run WROTE and a role the page SAID reach the card as the same words.
//
// `PrepContact.role` is unbounded free text and the app derives nothing from it, deliberately and
// correctly. Nothing asks whether the word the run chose appears on the page it cited, so a paraphrase is
// recorded with the same authority as a quote. The measured case, 2026-08-17 (identities redacted, L155):
// a run recorded `role: "Playwright"` for a named performer whose cited page describes them as "an actor
// and writer" and contains the word "playwright" exactly once, inside the NAME OF A THEATRE in an
// unrelated regional credit.
//
// WHY THIS IS A DECLARATION AND NOT A MEASUREMENT, which is the decision #3078 leaves open. It says to
// decide with #2269 whether the app fetches a cited page at ingest. #2269 CLOSED on 2026-09-06 with that
// answer: every `WebFetch` result the run receives is PROSE written by a small model against the page, so
// the run never holds the page in bytes or markdown and there is nothing at ingest to check the role
// against. Measuring it would need a fetch this app performs itself, which that issue records as its own
// separate proposal with its own cost. So the alternative #3078 names applies: the run declares which it
// is, and the card stops presenting a characterisation as a quote (L192).
//
// TRUE IS THE UNREMARKABLE VALUE and absent means nobody said, which is every contact written before this
// and every run that ignores the field. Absence may never be read as a characterisation: doing so would
// mark every role from every older run at once (L98, L128).
@MainActor
@Suite("A role is quoted from the page, or it is the run's own words (#3078)")
struct ARoleIsQuotedOrCharacterisedTests {

    @Test func aRoleTheRunCharacterisedIsMarkedAsItsOwnWords() {
        #expect(ContactRoleClaim.isCharacterisation(roleQuoted: false, role: "Playwright"))
    }

    @Test func aRoleQuotedFromThePageIsNotMarked() {
        #expect(!ContactRoleClaim.isCharacterisation(roleQuoted: true, role: "Music Director"))
    }

    // The half that decides whether this can ship at all. Every contact written before this field existed
    // carries nil, and a run that has not adopted it sends nothing, so reading absence as a
    // characterisation would put the marker on 270 of the 447 contacts in the archives at once.
    @Test func aRoleNobodyHasSpokenAboutIsNotMarked() {
        #expect(!ContactRoleClaim.isCharacterisation(roleQuoted: nil, role: "performer"))
    }

    // A declaration about a role that is not there claims nothing, and marking it would put a note on a
    // line with no role on it.
    @Test func aDeclarationWithNoRoleToDescribeMarksNothing() {
        #expect(!ContactRoleClaim.isCharacterisation(roleQuoted: false, role: nil))
        #expect(!ContactRoleClaim.isCharacterisation(roleQuoted: false, role: "   "))
    }

    // What the card says. It keeps the role, because a characterised role is still useful context about
    // who this person is; what it stops doing is presenting it as something the page said.
    @Test func theCardKeepsTheRoleAndSaysWhoseWordsItIs() {
        let quoted = ContactDisplay.from(name: "Nessa Halloway", role: "Music Director",
                                         email: "nessa@example.org", formURL: nil, roleQuoted: true)
        #expect(quoted == .person(name: "Nessa Halloway", role: "Music Director",
                                  roleIsACharacterisation: false, email: "nessa@example.org"))

        let characterised = ContactDisplay.from(name: "Nessa Halloway", role: "Playwright",
                                                email: "nessa@example.org", formURL: nil, roleQuoted: false)
        #expect(characterised == .person(name: "Nessa Halloway", role: "Playwright",
                                         roleIsACharacterisation: true, email: "nessa@example.org"))
    }

    // Every existing call site is unaffected, which is what keeps this additive: the parameter is last and
    // defaulted, and a caller that says nothing gets exactly what it got before.
    @Test func acallerThatSaysNothingGetsWhatItAlwaysGot() {
        #expect(ContactDisplay.from(name: "Nessa Halloway", role: "performer",
                                    email: "nessa@example.org", formURL: nil)
                == .person(name: "Nessa Halloway", role: "performer",
                           roleIsACharacterisation: false, email: "nessa@example.org"))
    }

    // MARK: - Wired, not merely built (L3)

    // The rule is pure and its own tests would stay green while nothing in the app ever asked it.
    @Test func theDeclarationReachesTheRow() throws {
        let ctx = ModelContext(try ModelContainer(
            for: AppSchema.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet",
                                          performanceDate: "2027-10-03", venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-10-03", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try ctx.save()

        var c = PrepContact()
        c.name = "Nessa Halloway"
        c.role = "Playwright"
        c.email = "nessa@example.org"
        c.method = "named_decision_maker"
        c.confidence = "low"
        c.provenance = "performer"
        c.sourceUrl = "https://example.org/bio"
        c.roleQuoted = false
        PrepImporter.ingest(PrepResults(version: 12, generatedAt: "2027-09-01T00:00:00Z",
                                        results: [PrepResult(naturalKey: key, contacts: [c])]),
                            into: ctx, isProbe: true)

        #expect(try #require(p.recipients.first).roleIsACharacterisation)
    }

    // A run that says nothing leaves the row unmarked, which is every run before this one.
    @Test func arunThatSaysNothingLeavesTheRowUnmarked() throws {
        let ctx = ModelContext(try ModelContainer(
            for: AppSchema.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let key = Prospect.makeNaturalKey(groupName: "Rowan Trio",
                                          performanceDate: "2027-10-04", venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Rowan Trio", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-10-04", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try ctx.save()

        var c = PrepContact()
        c.name = "Wren Ashby"
        c.role = "performer"
        c.email = "wren@example.org"
        c.method = "named_decision_maker"
        c.confidence = "low"
        c.provenance = "performer"
        PrepImporter.ingest(PrepResults(version: 12, generatedAt: "2027-09-01T00:00:00Z",
                                        results: [PrepResult(naturalKey: key, contacts: [c])]),
                            into: ctx, isProbe: true)

        #expect(!(try #require(p.recipients.first).roleIsACharacterisation))
    }

    // The sentence itself, read cold beside the role it qualifies.
    @Test func theMarkerSaysWhoseWordsRatherThanThatAFieldIsSet() {
        #expect(ContactRoleCopy.characterisationNote == "Overture's words, not the page's")
    }
}
