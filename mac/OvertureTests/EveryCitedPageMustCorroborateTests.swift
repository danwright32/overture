import Testing
import Foundation

// #3376. A canonical-domain fetch cannot verify that the site it landed on belongs to THAT organisation
// rather than a stranger who shares the name.
//
// `docs/prep-runbook.md:288` tells the run to reach an organisation's own site by "its name plus a
// canonical domain guess", which is one lookup and no judgement. Names are not unique, and a site
// carries no field saying which of the several bearers of a name it belongs to. The failure is a route
// recorded against the wrong party and, downstream, an email under Dan's name to a stranger, which is
// worse than finding nothing because a blank reads as missing and a wrong address reads as an answer
// (L75, L161, L192).
//
// #2895 already built the refusal this needs. `ContactConfidenceGuard.holdDown` refuses a `high`
// citation whose page does not corroborate, `performanceCorroborated: false` is how a run says so, and
// the card already renders `pageDoesNotCorroborate` in its own words.
//
// IT WAS SCOPED TO ONE PROVENANCE. `provenance == "performer"`, which is the case #2895 was reported
// on, and the canonical-domain guess above emits `provenance: "presenter"`. So the one route that
// reaches a page by GUESSING its address was the one route exempt from the rule about whether the page
// is the right one. That is a rule scoped to the instance rather than the class (L30, L247), and the
// exemption is invisible because it reads as the rule working.
@Suite("Every cited page must corroborate, not only a performer's (#3376)")
struct EveryCitedPageMustCorroborateTests {

    // THE DEFECT, in the exact shape the runbook's canonical-domain guess produces.
    @Test func aPresentersCitedPageThatDoesNotCorroborateIsHeldDown() {
        let hold = ContactConfidenceGuard.holdDown(raw: "high",
                                                   sourceURL: "https://rowanhallarts.example/contact",
                                                   provenance: "presenter",
                                                   performanceCorroborated: false)

        #expect(hold == .pageDoesNotCorroborate)
    }

    // The whole class, not the two spellings anybody happened to think of. Derived from the vocabulary
    // the runbook actually emits rather than a list written beside it, so a provenance added later
    // cannot arrive exempt (L113, L96).
    @Test func noProvenanceIsExemptFromTheCorroborationRule() {
        for provenance in RecipientProvenance.allCases {
            let hold = ContactConfidenceGuard.holdDown(raw: "high",
                                                       sourceURL: "https://rowanhallarts.example/about",
                                                       provenance: provenance.rawValue,
                                                       performanceCorroborated: false)

            #expect(hold == .pageDoesNotCorroborate,
                    "\(provenance.rawValue) is exempt from the rule about whether the cited page is the right one")
        }
    }

    // A run that SAID the page corroborates is believed, exactly as before. Without this the rule above
    // could pass by holding every high contact down, which would fire on the common case and be switched
    // off within a day (L93, L159).
    @Test func aCorroboratedPageIsStillBelieved() {
        for provenance in RecipientProvenance.allCases {
            #expect(ContactConfidenceGuard.holdDown(raw: "high",
                                                    sourceURL: "https://rowanhallarts.example/about",
                                                    provenance: provenance.rawValue,
                                                    performanceCorroborated: true) == nil)
        }
    }

    // SILENCE IS NOT A DENIAL, and this is the boundary that keeps the widening safe. A run that has not
    // adopted the field at all sends nothing, and nil must go on meaning "nobody said" rather than "the
    // page does not corroborate". Reading absence as denial would hold down every high contact from
    // every older run at once, which is the same fail-loud-in-the-wrong-direction trap #3453 hit reading
    // a missing `webCalls` as a dead run (L98, L11).
    @Test func aRunThatSaysNothingAboutCorroborationIsNotTreatedAsDenyingIt() {
        for provenance in RecipientProvenance.allCases {
            #expect(ContactConfidenceGuard.holdDown(raw: "high",
                                                    sourceURL: "https://rowanhallarts.example/about",
                                                    provenance: provenance.rawValue,
                                                    performanceCorroborated: nil) == nil,
                    "\(provenance.rawValue): an absent field was read as a denial")
        }
    }

    // The rule the runbook states must actually be in the runbook, because the app reading a field the
    // prompt never writes is a guard that reads as active while refusing nobody (L27, L128, L506).
    @Test func theRunbookAsksForCorroborationOnEveryCitedPageNotOnlyAPerformers() throws {
        let runbook = try String(contentsOf: RepoRoot.url.appendingPathComponent("docs/prep-runbook.md"),
                                 encoding: .utf8)

        #expect(runbook.contains("canonical domain guess"),
                "the instruction this rule exists to make safe is no longer in the runbook")
        #expect(runbook.contains("performanceCorroborated"))
        // The old wording scoped the ask to a performer. If it comes back, the app's widened refusal is
        // reading a field nothing writes for the other provenances.
        #expect(!runbook.contains("For a `performer` contact you are emitting at `high`, add"),
                "the runbook still asks for corroboration only on a performer contact")
    }

    // THE ADOPTION HALF, and without it the widening above is a guard that reads as active while
    // refusing nobody. The app now reads `performanceCorroborated` on every provenance, and only the
    // runbook writes it, so a run that never adopts the instruction leaves the canonical domain guess
    // taken on trust exactly as before (L27, L128, L506).
    //
    // `RunInstructionCompliance` is where the other two prompt-only rules are already measured, per RUN,
    // which is the only honest unit: one contact saying nothing means nothing, every contact saying
    // nothing means the instruction did not reach the model.
    @Test func aRunThatNeverAnswersTheCorroborationQuestionIsReported() {
        let m = RunInstructionCompliance.measure(contacts: [
            PrepContact(name: "Rowan Hall Arts", role: "Producer", tier: "primary",
                        email: "office@rowanhallarts.example", method: "generic_inbox",
                        confidence: "high", sourceUrl: "https://rowanhallarts.example/contact")
        ])

        #expect(m.corroborationInstructionIgnored)
        #expect(m.notes.contains { $0.contains("anyone on this show") })
    }

    @Test func aRunThatAnswersItIsNotAccused() {
        let m = RunInstructionCompliance.measure(contacts: [
            PrepContact(name: "Rowan Hall Arts", role: "Producer", tier: "primary",
                        email: "office@rowanhallarts.example", method: "generic_inbox",
                        confidence: "high", sourceUrl: "https://rowanhallarts.example/contact",
                        performanceCorroborated: true)
        ])

        #expect(!m.corroborationInstructionIgnored)
    }

    // Zero examined is its own outcome and must never read as a finding (L98). A run with no confident
    // citations at all has not ignored anything, and this is the case that would otherwise accuse every
    // ordinary run that found only forms and generic inboxes.
    @Test func aRunWithNoConfidentCitationsIsNotAccused() {
        let m = RunInstructionCompliance.measure(contacts: [
            PrepContact(name: "Rowan Hall Arts", role: "Producer", tier: "primary", email: nil,
                        method: "form_or_dm", confidence: "low",
                        formUrl: "https://rowanhallarts.example/contact")
        ])

        #expect(m.citedAtHigh == 0)
        #expect(!m.corroborationInstructionIgnored)
    }

    // A high contact carrying NO page is already refused by `holdDown`'s `namedNoPage` arm and has no
    // page to corroborate against, so it must stay out of the denominator. Counting it would put the
    // ordinary case into the measurement and make adoption read worse than it is (L139).
    @Test func aConfidentContactWithNoPageIsNotInTheDenominator() {
        let m = RunInstructionCompliance.measure(contacts: [
            PrepContact(name: "Rowan Hall Arts", role: "Producer", tier: "primary",
                        email: "office@rowanhallarts.example", method: "generic_inbox",
                        confidence: "high")
        ])

        #expect(m.citedAtHigh == 0)
        #expect(!m.corroborationInstructionIgnored)
    }
}
