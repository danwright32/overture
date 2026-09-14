import Foundation

// #2641 and #2925: telling a run that IGNORED a runbook instruction from a run that had nothing to
// report.
//
// Two rules live only in the prep runbook. #2622/#2612 asked every contact to carry a `tier`. #2893
// added `no_route_found`, the value a run uses to say it found a person and no way to reach them, and a
// boundary check that refuses a contact naming a route it does not supply. The app reads all of them
// faithfully and reads their ABSENCE as a legitimate answer, which is the whole trap: a rule that lives
// only in a prompt is a hope (L27), and a field whose only writer is that prompt cannot tell a model
// that ignored the instruction from one that judged it inapplicable (L128).
//
// WHAT EACH SILENCE COSTS, because that is what decides whether this is worth a sentence. If nothing
// ever carries a tier, the tier stays empty on every future show and the fit score keeps using the
// unknown weight, for ever, with nothing anywhere reporting a problem. If runs never adopt
// `no_route_found`, the refusal built to catch a misbehaving run fires on ordinary shows instead, the
// card tells Dan a check fell short when it did what it always did, and the line gets ignored and then
// removed: a guard that fires on the common case is switched off within a day (L93).
//
// JUDGED PER RUN, not per show or per contact, and that is the only honest unit. One contact with no
// tier means nothing at all. EVERY contact in a run having none means the instruction did not reach the
// model. A run that answered nothing is not accused of anything, because zero examined is its own
// outcome and must never read as a finding (L98).
enum RunInstructionCompliance {

    struct Measurement: Equatable, Sendable {
        var contacts: Int
        var withATier: Int
        var declaredNoRouteFound: Int
        var routeNamedButNotSupplied: Int
        // #3376: contacts emitted at `high` with a cited page. The denominator for the next field, and
        // its own field rather than a derived one, because "no high citations at all" is a legitimate
        // run and must not read as an ignored instruction (L98).
        var citedAtHigh: Int
        var citedAtHighSayingWhetherItCorroborates: Int
        // #3347/#2258: contacts the run ranked `primary` on a show whose own listing bills them only as
        // cast and credits them nowhere. Its own field rather than folded into the two above, because it
        // is a different fault with a different remedy: the tier instruction was FOLLOWED, and the answer
        // it produced is contradicted by the page the run was handed.
        var primaryContradictedByTheListing: Int
        // #2625: contacts the run gave a tier while naming nobody it could be about. Its own field for
        // the same reason as the one above: a different fault with a different remedy, and the tier
        // instruction was followed, it was just answered about an address with nobody behind it.
        var tieredWithNoName: Int
        // #3078: contacts carrying a role AND a cited page, which is the population the declaration is
        // about, and how many of those say whose words the role is. Its own pair for the same reason as
        // `citedAtHigh` above: "no role on a cited page at all" is a legitimate run and must not read as
        // an ignored instruction (L98).
        var roleOnACitedPage: Int
        var roleSayingWhoseWordsItIs: Int

        // Not "fewer than all", deliberately. A partial run is a different thing from an ignored
        // instruction, and accusing on a partial would fire on the ordinary case.
        var tierInstructionIgnored: Bool { contacts > 0 && withATier == 0 }

        // The pairing is the evidence, not either half. A run that names routes it never found while
        // never once using the value meant for exactly that case has not adopted it, which is precisely
        // when #2893's refusal cannot be trusted to mean what it says.
        var refusalFiringWithoutAdoption: Bool {
            routeNamedButNotSupplied > 0 && declaredNoRouteFound == 0
        }

        // #3376: the corroboration refusal now covers every provenance, and it reads a field only the
        // runbook writes. If runs never adopt it, `holdDown` refuses nobody while reading as an active
        // safeguard, and the canonical domain guess goes on recording a stranger's address as an answer
        // (L27, L128, L506).
        //
        // Not "fewer than all", for the same reason as `tierInstructionIgnored` directly above: a run
        // that answered the question on some of its citations has adopted the instruction, and accusing
        // on a partial would fire on the ordinary case.
        // #3078: not "fewer than all", for the reason every rule here follows: a run that answered on
        // some of its roles has adopted the instruction, and accusing on a partial fires on the ordinary
        // case.
        var roleClaimInstructionIgnored: Bool {
            roleOnACitedPage > 0 && roleSayingWhoseWordsItIs == 0
        }

        var corroborationInstructionIgnored: Bool {
            citedAtHigh > 0 && citedAtHighSayingWhetherItCorroborates == 0
        }

        // One sentence per instruction, never one covering both: they are different rules with different
        // remedies, and a sentence about both would name neither (L11).
        var notes: [String] {
            var out: [String] = []
            if tieredWithNoName > 0 {
                out.append(RunComplianceCopy.tieredWithNoName(tieredWithNoName))
            }
            if primaryContradictedByTheListing > 0 {
                out.append(RunComplianceCopy.primaryTheListingContradicts(primaryContradictedByTheListing))
            }
            if tierInstructionIgnored { out.append(RunComplianceCopy.noTierAtAll(contacts)) }
            if refusalFiringWithoutAdoption {
                out.append(RunComplianceCopy.routesNamedNeverFound(routeNamedButNotSupplied))
            }
            if roleClaimInstructionIgnored {
                out.append(RunComplianceCopy.noRoleClaimAtAll(roleOnACitedPage))
            }
            if corroborationInstructionIgnored {
                out.append(RunComplianceCopy.noCorroborationAtAll(citedAtHigh))
            }
            return out
        }
    }

    // #3347: measured for ONE SHOW at a time, and `listing` is the page the app handed the run for that
    // show, so the tier it declared can be judged against how that page bills the person. Per show rather
    // than over a run's whole pool of contacts, because a contact and a listing belong together only when
    // they came from the same item and pairing them after the fact is how a confident number about
    // nothing gets produced (L420). nil holds nothing down: a caller with no work-list must not report a
    // run as contradicted by a page nobody read (L98).
    // #3347: the identity for the per-show sum, and every field is zero, so summing an empty run's shows
    // gives the same answer as measuring an empty pool did before.
    static let empty = Measurement(contacts: 0, withATier: 0, declaredNoRouteFound: 0,
                                   routeNamedButNotSupplied: 0, citedAtHigh: 0,
                                   citedAtHighSayingWhetherItCorroborates: 0,
                                   primaryContradictedByTheListing: 0, tieredWithNoName: 0,
                                   roleOnACitedPage: 0, roleSayingWhoseWordsItIs: 0)

    static func measure(contacts: [PrepContact], listing: ShowListing? = nil) -> Measurement {
        var withATier = 0
        var noRouteFound = 0
        var routeMissing = 0
        var cited = 0
        var citedAndAnswered = 0
        var contradicted = 0
        var namelessTiers = 0
        var rolesOnAPage = 0
        var rolesClaimed = 0
        for c in contacts {
            // #3078: the population the declaration is about is a role RESTING ON A CITED PAGE. A role
            // with no page has nothing to be quoted from, so counting it would put the ordinary case in
            // the denominator and make adoption look worse than it is (L139).
            if !(c.role ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !(c.sourceUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rolesOnAPage += 1
                if c.roleQuoted != nil { rolesClaimed += 1 }
            }
            // #2625: a tier declared about an address with nobody behind it. Through the SAME predicate
            // the ingest refuses it with, so the count and the row cannot disagree (L16).
            if c.tier != nil, !BilledHierarchy.tierIsAnswerable(name: c.name) { namelessTiers += 1 }
            // #3347: through the SAME predicate the ingest holds the tier down with, never a second one
            // written beside it, so the count and the row can never disagree about one contact (L16).
            if c.tier == ContactTier.primary.rawValue,
               BilledHierarchy.billedAsCastOnly(name: c.name, inListingText: listing?.text,
                                                truncated: listing?.truncated == true) {
                contradicted += 1
            }
            // #3376: the population the corroboration rule is ABOUT, which is a high confidence claim
            // resting on a named page. A contact with no `sourceUrl` is already refused by
            // `holdDown`'s `namedNoPage` arm and has no page to corroborate against, so counting it
            // here would put the ordinary case into the denominator and make adoption look worse than
            // it is (L139).
            if c.confidence == "high",
               !(c.sourceUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cited += 1
                if c.performanceCorroborated != nil { citedAndAnswered += 1 }
            }
            if !(c.tier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { withATier += 1 }
            if c.method == ContactMethod.noRouteFound.rawValue { noRouteFound += 1 }
            // Through the ONE definition of "names a route it does not carry", never a second predicate
            // written beside it: two would let this count and the card's own reason disagree about the
            // same contact (L16).
            if Reachability.declaredRouteIsMissing(c) { routeMissing += 1 }
        }
        return Measurement(contacts: contacts.count, withATier: withATier,
                           declaredNoRouteFound: noRouteFound, routeNamedButNotSupplied: routeMissing,
                           citedAtHigh: cited,
                           citedAtHighSayingWhetherItCorroborates: citedAndAnswered,
                           primaryContradictedByTheListing: contradicted,
                           tieredWithNoName: namelessTiers,
                           roleOnACitedPage: rolesOnAPage,
                           roleSayingWhoseWordsItIs: rolesClaimed)
    }
}

extension RunInstructionCompliance.Measurement {
    // Field by field, and exhaustively: every count in this type is a per-show number summed over the
    // run, so a field added later has to be added here or its run total silently stays at the first
    // show's value.
    static func + (a: Self, b: Self) -> Self {
        Self(contacts: a.contacts + b.contacts,
             withATier: a.withATier + b.withATier,
             declaredNoRouteFound: a.declaredNoRouteFound + b.declaredNoRouteFound,
             routeNamedButNotSupplied: a.routeNamedButNotSupplied + b.routeNamedButNotSupplied,
             citedAtHigh: a.citedAtHigh + b.citedAtHigh,
             citedAtHighSayingWhetherItCorroborates:
                a.citedAtHighSayingWhetherItCorroborates + b.citedAtHighSayingWhetherItCorroborates,
             primaryContradictedByTheListing:
                a.primaryContradictedByTheListing + b.primaryContradictedByTheListing,
             tieredWithNoName: a.tieredWithNoName + b.tieredWithNoName,
             roleOnACitedPage: a.roleOnACitedPage + b.roleOnACitedPage,
             roleSayingWhoseWordsItIs: a.roleSayingWhoseWordsItIs + b.roleSayingWhoseWordsItIs)
    }
}

// The two sentences, beside the rule that produces them so they reach `docs/copy-inventory.md` and get
// read cold. Each says what the silence COSTS rather than that a field was absent, because the cost is
// the part Dan can do anything about.
enum RunComplianceCopy {
    static func noTierAtAll(_ contacts: Int) -> String {
        contacts == 1
            ? "the one contact it found carries no tier, so the fit score is guessing"
            : "not one of its \(contacts) contacts carries a tier, so the fit score is guessing"
    }

    static func routesNamedNeverFound(_ count: Int) -> String {
        count == 1
            ? "1 contact named a way in and gave none, and the run never once said it found no route"
            : "\(count) contacts named a way in and gave none, and the run never once said it found no route"
    }

    // #3078: what the silence COSTS. Not that a field is missing: that a word Overture wrote is being
    // read as a word the page said.
    static func noRoleClaimAtAll(_ count: Int) -> String {
        count == 1
            ? "its 1 contact with a role and a cited page never says whether the role is quoted, so a summary reads as a quote"
            : "not one of its \(count) contacts with a role and a cited page says whether the role is quoted, so a summary reads as a quote"
    }

    // #2625: what an unanswerable rank COSTS. Not that a field is missing: that a show moved up the queue
    // on the strength of an address with nobody behind it.
    static func tieredWithNoName(_ count: Int) -> String {
        count == 1
            ? "1 contact was ranked without naming anybody it could be about, so Overture is not using that rank"
            : "\(count) contacts were ranked without naming anybody they could be about, so Overture is not using those ranks"
    }

    // #3347/#2258: what the wrong rank COSTS, in the terms the sentences above use. The cost is not that
    // a field disagrees with a page, it is that a show moves up into what Dan looks at first on the
    // strength of somebody who cannot commission the work.
    static func primaryTheListingContradicts(_ count: Int) -> String {
        count == 1
            ? "1 contact was ranked as a decision maker while its own listing bills them only as cast, so Overture is not using that rank"
            : "\(count) contacts were ranked as decision makers while their own listings bill them only as cast, so Overture is not using those ranks"
    }

    // #3376: what the silence COSTS, in the terms the other two sentences use. The cost is not that a
    // field is missing, it is that a site found by guessing an address is being taken on trust.
    static func noCorroborationAtAll(_ cited: Int) -> String {
        cited == 1
            ? "its 1 confident contact never says the page it cites is anyone on this show, so a same named stranger would be kept as an answer"
            : "not one of its \(cited) confident contacts says the page it cites is anyone on this show, so a same named stranger would be kept as an answer"
    }
}
