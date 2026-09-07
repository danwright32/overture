import Testing
import Foundation

// #2641 and #2925: two rules that live only in the prep runbook, and no way to tell a run that ignored
// one from a run that had nothing to report.
//
// #2622/#2612 asked every contact to carry a `tier`. #2893 added `no_route_found`, the value a run uses
// to say it found a person and no way to reach them, plus a boundary check that refuses a contact naming
// a route it does not supply. The app reads all of them faithfully and reads their ABSENCE as a
// legitimate answer, which is the trap: a run that quietly ignored the instruction and a run with
// nothing to report are indistinguishable (L27 meeting L128).
//
// The cost is specific. If nothing ever carries a tier, the tier stays empty on every future show and the
// score keeps using the unknown weight, silently and for ever. And if runs never adopt `no_route_found`,
// the refusal built to catch a misbehaving run fires on ordinary shows instead, the card tells Dan a
// check fell short when it did what it always did, and the line gets ignored and then removed, which is
// a guard firing on the common case (L93).
//
// WHY A RUN AND NOT A SHOW. Both of these are facts about the RUN, not about any one show: a single
// contact with no tier means nothing, and every contact in a run having none means the instruction did
// not reach the model at all. Judged over what one run answered, which is the smallest unit where the
// question can be asked honestly.
@Suite("A run that ignored a runbook instruction is told apart from one with nothing to report (#2641, #2925)")
struct RunInstructionComplianceTests {

    private func contact(tier: String? = "primary", method: String? = "named_decision_maker",
                         email: String? = "someone@example.com", formUrl: String? = nil) -> PrepContact {
        var c = PrepContact()
        c.name = "Nessa Halloway"
        c.tier = tier
        c.method = method
        c.email = email
        c.formUrl = formUrl
        return c
    }

    // MARK: - Nothing to judge

    // A run that answered no contacts at all says nothing about either instruction, and reporting one
    // would be an accusation with no evidence behind it. Zero examined is its own outcome (L98).
    @Test func arunThatAnsweredNoContactsAtAllIsNotAccused() {
        let c = RunInstructionCompliance.measure(contacts: [])
        #expect(c.contacts == 0)
        #expect(!c.tierInstructionIgnored)
        #expect(c.notes.isEmpty, "a run with nothing to judge was accused of ignoring something")
    }

    // MARK: - The tier instruction (#2641)

    @Test func arunWhereNotOneContactCarriesATierIsNamed() {
        let c = RunInstructionCompliance.measure(contacts: [contact(tier: nil), contact(tier: nil)])
        #expect(c.contacts == 2)
        #expect(c.withATier == 0)
        #expect(c.tierInstructionIgnored)
        #expect(c.notes.count == 1)
        #expect(c.notes.first?.contains("tier") == true)
    }

    // ONE contact carrying a tier is enough to show the instruction reached the model. A partial run is a
    // different thing from an ignored one, and accusing on a partial would fire on the ordinary case,
    // which is how a warning gets switched off (L93).
    @Test func onecontactCarryingATierIsEnoughToShowTheInstructionArrived() {
        let c = RunInstructionCompliance.measure(contacts: [contact(tier: nil), contact(tier: "secondary")])
        #expect(c.withATier == 1)
        #expect(!c.tierInstructionIgnored)
        #expect(c.notes.isEmpty)
    }

    // A tier that is present and blank is no tier. A stored empty string would otherwise read as
    // compliance and silence the whole check.
    @Test func ablankTierIsNoTier() {
        let c = RunInstructionCompliance.measure(contacts: [contact(tier: "   "), contact(tier: "")])
        #expect(c.withATier == 0)
        #expect(c.tierInstructionIgnored)
    }

    // MARK: - The no_route_found instruction (#2925)

    // The state the issue is about: the run stated a route on somebody it had no route for, which is
    // what #2893's refusal catches, and adopted the value meant for that case zero times. That pairing is
    // the evidence that runs have NOT adopted it, which is exactly when the refusal cannot be trusted.
    @Test func arunRefusingRoutesWhileAdoptingNoRouteFoundNeverIsNamed() {
        let c = RunInstructionCompliance.measure(contacts: [
            contact(method: "form_or_dm", email: nil, formUrl: nil),
            contact(method: "form_or_dm", email: nil, formUrl: nil),
        ])
        #expect(c.routeNamedButNotSupplied == 2)
        #expect(c.declaredNoRouteFound == 0)
        #expect(c.notes.contains { $0.contains("no route") },
                "a run naming routes it never found, having never once used the value for that case, said nothing")
    }

    // Adoption. Once a run uses the value, the refusal above is doing its job on real misbehaviour rather
    // than on the ordinary case, so there is nothing to say.
    @Test func arunThatAdoptedTheValueIsNotNamed() {
        let c = RunInstructionCompliance.measure(contacts: [
            contact(method: "no_route_found", email: nil, formUrl: nil),
            contact(method: "form_or_dm", email: nil, formUrl: nil),
        ])
        #expect(c.declaredNoRouteFound == 1)
        #expect(c.routeNamedButNotSupplied == 1)
        #expect(!c.notes.contains { $0.contains("no route") })
    }

    // A run whose contacts are all fine says nothing about either.
    @Test func ahealthyRunSaysNothing() {
        let c = RunInstructionCompliance.measure(contacts: [contact(), contact(tier: "tertiary")])
        #expect(c.notes.isEmpty)
        #expect(c.routeNamedButNotSupplied == 0)
    }

    // The two are counted APART even when both fire, and produce two sentences rather than one covering
    // both, because they are different instructions with different remedies (L11).
    @Test func bothInstructionsIgnoredIsTwoSentences() {
        let c = RunInstructionCompliance.measure(contacts: [
            contact(tier: nil, method: "form_or_dm", email: nil, formUrl: nil),
        ])
        #expect(c.tierInstructionIgnored)
        #expect(c.notes.count == 2)
    }

    // MARK: - Built is not wired (L3)

    // The measurement reaches the sentence Dan actually reads at the end of a run. Without this it is a
    // counter nobody looks at, which is the defect rather than a fix (L46).
    @Test func therunSummaryCarriesTheNotes() {
        let source = SourceGuardHelper.source("Overture/Domain/PrepRunSummary.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("outcome.instructionCompliance.notes", in: source),
                "a run that ignored a runbook instruction says nothing at the end of the run (#2641)")
    }

    // Measured over what the RUN SAID, not over what survived the ingest. A contact refused for naming a
    // route it never found is exactly the evidence being counted, and the ingest discards it, so counting
    // survivors would count zero of the thing in question and the check would report a clean run for ever.
    //
    // Asserted as the RULE rather than as one spelling of it. It used to pin the exact expression, and
    // #3347 refined that expression legitimately (it measures per show now, so each contact is judged
    // against its own listing) and the guard went red for formatting while the rule it exists for was
    // untouched. A guard that goes red for the wrong reason teaches the next person to edit it until it
    // is quiet (L103).
    @Test func theimporterMeasuresTheResultsRatherThanTheSurvivors() {
        let source = SourceGuardHelper.source("Overture/Persistence/PrepImporter.swift")
        #expect(!source.isEmpty)
        // Bounded at the loop that follows it, so the region really is the assignment. An end marker
        // that does not match makes `between` run to the end of the file, at which point every
        // assertion below is about the whole importer and the one that forbids `recipients` fires on
        // code that has nothing to do with this (measured, first try).
        let assignment = SourceGuardHelper.between("outcome.instructionCompliance =",
                                                   and: "for r in results.results {", in: source)
        let measured = try! #require(assignment)
        // It reads what the RUN wrote, which is `contacts` off the results entries.
        #expect(measured.contains("results.results"),
                "the compliance count is taken from something other than the run's own results (#2925)")
        #expect(measured.contains("contacts"),
                "the compliance count no longer reads the run's contacts at all (#2925)")
        // And never the survivors. `recipients` is what the ingest LEAVES, and a contact refused for
        // naming a route it never found is exactly the evidence being counted, so counting survivors
        // would count zero of the thing in question and report a clean run for ever.
        #expect(!measured.contains("recipients"), Comment(rawValue:
            "the compliance count is taken from what survived the ingest rather than from what the run "
            + "said, so the evidence it exists to count is discarded before it is counted (#2925)"))
    }

    // MARK: - #3347: a rank the show's own listing contradicts

    private var castOnlyListing: ShowListing {
        ShowListing(status: ShowListing.read, url: "https://example.org/chills",
                    text: "An evening of songs. Featuring: Nessa Halloway, Rennick Slade.")
    }

    @Test func aPrimaryTheListingBillsOnlyAsCastIsCounted() {
        let m = RunInstructionCompliance.measure(contacts: [contact()], listing: castOnlyListing)
        #expect(m.primaryContradictedByTheListing == 1)
        #expect(m.notes.contains { $0.contains("ranked as a decision maker") })
    }

    // The page CREDITS her, so the rank stands and nothing is counted. Without this the count would be
    // "how many primary contacts are there", which fires on the ordinary case (L93).
    @Test func aPrimaryTheListingCreditsIsNotCounted() {
        let credited = ShowListing(
            status: ShowListing.read, url: "https://example.org/chills",
            text: "Produced by Nessa Halloway. Featuring: Nessa Halloway, Rennick Slade.")
        let m = RunInstructionCompliance.measure(contacts: [contact()], listing: credited)
        #expect(m.primaryContradictedByTheListing == 0)
        #expect(!m.notes.contains { $0.contains("ranked as a decision maker") })
    }

    // NO listing counts nothing, which is the half that decides whether this is safe: a run measured by
    // a caller holding no work-list must never be reported as contradicted by a page nobody read (L98).
    @Test func withNoListingNothingIsContradicted() {
        #expect(RunInstructionCompliance.measure(contacts: [contact()])
            .primaryContradictedByTheListing == 0)
    }

    // The sum is what turns per-show measurements into a run, and EVERY field has to move. A field added
    // later and left out of `+` keeps whatever the FIRST show reported for the whole run, which is a
    // number that looks perfectly reasonable and is measured over one item (L63).
    @Test func summingTwoShowsAddsEveryFieldRatherThanSome() {
        let a = RunInstructionCompliance.Measurement(
            contacts: 1, withATier: 2, declaredNoRouteFound: 3, routeNamedButNotSupplied: 4,
            citedAtHigh: 5, citedAtHighSayingWhetherItCorroborates: 6,
            primaryContradictedByTheListing: 7, tieredWithNoName: 8)
        let b = RunInstructionCompliance.Measurement(
            contacts: 10, withATier: 20, declaredNoRouteFound: 30, routeNamedButNotSupplied: 40,
            citedAtHigh: 50, citedAtHighSayingWhetherItCorroborates: 60,
            primaryContradictedByTheListing: 70, tieredWithNoName: 80)
        #expect(a + b == RunInstructionCompliance.Measurement(
            contacts: 11, withATier: 22, declaredNoRouteFound: 33, routeNamedButNotSupplied: 44,
            citedAtHigh: 55, citedAtHighSayingWhetherItCorroborates: 66,
            primaryContradictedByTheListing: 77, tieredWithNoName: 88))
        // The identity, so a run of no shows reports the same nothing measuring an empty pool did.
        #expect(RunInstructionCompliance.empty + a == a)
    }

    // Summed ACROSS shows, each judged against ITS OWN page, which is the whole reason the measurement
    // moved per show: one flat pool would have to pair a contact with a listing after the fact, and a
    // mismatched pairing produces a confident number about nothing (L420).
    @Test func eachShowIsJudgedAgainstItsOwnPage() {
        let credited = ShowListing(status: ShowListing.read, url: "https://example.org/b",
                                   text: "Produced by Nessa Halloway. Featuring: Nessa Halloway.")
        let contradicted = RunInstructionCompliance.measure(contacts: [contact()],
                                                            listing: castOnlyListing)
        let supported = RunInstructionCompliance.measure(contacts: [contact()], listing: credited)
        let run = RunInstructionCompliance.empty + contradicted + supported
        #expect(run.contacts == 2)
        #expect(run.primaryContradictedByTheListing == 1)
    }

    // #2625: a tier declared about an address with nobody behind it, counted and refused. Measured
    // across every archived run 2026-09-06: 22 of 447 contacts carry no name and 13 of those carry
    // `primary`, so this is not a corner case.
    @Test func aTierDeclaredAboutNobodyIsCountedAndSaidOutLoud() {
        var c = contact()
        c.name = nil
        let m = RunInstructionCompliance.measure(contacts: [c])
        #expect(m.tieredWithNoName == 1)
        #expect(m.notes.contains { $0.contains("without naming anybody") })
    }

    // A NAMED contact is not counted, or the number would be "how many tiers are there".
    @Test func aTierAboutSomebodyNamedIsNotCounted() {
        #expect(RunInstructionCompliance.measure(contacts: [contact()]).tieredWithNoName == 0)
    }

    // And a nameless contact the run declined to tier is not counted either: there is no claim to
    // refuse, and counting it would make a run that behaved correctly look like one that did not.
    @Test func anUntieredNamelessContactIsNotCounted() {
        var c = contact(tier: nil)
        c.name = nil
        #expect(RunInstructionCompliance.measure(contacts: [c]).tieredWithNoName == 0)
    }

    // MARK: - The refusal has ONE definition (L16)

    // Whether a contact names a route it does not carry is `Reachability.declaredRouteIsMissing` and
    // nothing else. A second predicate here would let the count and the card's own reason disagree about
    // the same contact.
    @Test func therefusalIsAskedThroughTheOneDefinitionOfIt() {
        let source = SourceGuardHelper.source("Overture/Domain/RunInstructionCompliance.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("Reachability.declaredRouteIsMissing"),
                "the compliance count asks for itself whether a route is missing, beside the definition that already answers it (L16)")
    }
}
