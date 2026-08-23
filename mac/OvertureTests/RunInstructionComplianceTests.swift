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
    @Test func theimporterMeasuresTheResultsRatherThanTheSurvivors() {
        let source = SourceGuardHelper.source("Overture/Persistence/PrepImporter.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode(
            "RunInstructionCompliance.measure(contacts: results.results.flatMap { $0.contacts ?? [] })",
            in: source),
                "the compliance count is taken from something other than the run's own results (#2925)")
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
