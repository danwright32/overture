import Testing
import Foundation
import SwiftData

// #2912: a social profile carrying the target's NAME and nothing tying it to this show is surfaced as a
// guess rather than withheld.
//
// Dan's call, 2026-08-17, reading back what #2892 shipped: "the handle appears on the card marked
// uncertain, and he decides whether it is the right person before sending. He is the one who looks at it,
// and looking costs him seconds."
//
// The refusal it replaces was not arbitrary (#2147, L75): a target that cannot be identified is refused
// rather than replaced with a near candidate, because Dan sends the DM by hand believing it is the act.
// So the refusal survives in a different form. The app never CLAIMS the profile is a route: the stored
// verdict, the score and the ledger see exactly what they saw before this shipped, and the one thing that
// changes is that the handle reaches the card, wearing a sentence saying what could not be confirmed.
//
// The three states this suite keeps apart, because collapsing any two of them is the defect:
//
//   a confirmed profile   the bio or a recent post ties the account to this show: a route (`social_only`)
//   a name match only     the account carries the right name and nothing else: a lead, not a route
//   nothing at all        no profile was found, and the card says so in its own words
@MainActor
@Suite("An unconfirmed profile is a guess, not a route (#2912)")
struct UnconfirmedProfileIsAGuessTests {

    private let confirmedHandle = "https://www.instagram.com/paperlanternsshow/"
    private let guessedHandle = "https://www.instagram.com/rowanashfieldmusic/"
    private let secondGuessedHandle = "https://www.instagram.com/mirasandovalmusic/"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // Invented act, invented people, invented handles: this repo is public and a fixture is exactly the
    // route a real person's handle travels out on (L155).
    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Paper Lanterns",
                                          performanceDate: "2026-09-14", venue: "The Lantern Room")
        let p = Prospect(naturalKey: key, groupName: "Paper Lanterns", discipline: "theater",
                         venue: "The Lantern Room", performanceDate: "2026-09-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 2, tier: "longshot",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func profile(_ name: String, _ url: String, nameMatchOnly: Bool?,
                         confidence: String = "low", sourceUrl: String? = nil) -> PrepContact {
        PrepContact(name: name, role: nil, tier: nil, email: nil, method: "form_or_dm",
                    confidence: confidence, formUrl: url, provenance: "performer",
                    overrideBody: nil, sourceUrl: sourceUrl, nameMatchOnly: nameMatchOnly)
    }

    private func ingest(_ contacts: [PrepContact], into p: Prospect, _ ctx: ModelContext) {
        _ = PrepImporter.ingest(PrepResults(version: 10, generatedAt: "2026-08-17T00:00:00Z",
                                            results: [PrepResult(naturalKey: p.naturalKey,
                                                                 contacts: contacts, draft: nil)]),
                                into: ctx)
    }

    // MARK: - The wire

    // The run's own declaration, and the only writer of it. Absence is what every contact written before
    // this carried, and it reads as "nobody has said", never as "confirmed": that is why the flag's TRUE
    // is the alarming value rather than its false.
    @Test func aRunCanSayTheOnlyThingMatchingIsTheName() throws {
        let json = #"""
        {"version":10,"generatedAt":"now","results":[{"naturalKey":"k","contacts":[
          {"name":"Rowan Ashfield","method":"form_or_dm","confidence":"low",
           "formUrl":"https://www.instagram.com/rowanashfieldmusic/","provenance":"performer",
           "nameMatchOnly":true}]}]}
        """#
        let decoded = try PrepResultsDecoder.decode(Data(json.utf8))
        #expect(decoded.results.first?.contacts?.first?.nameMatchOnly == true)
    }

    @Test func acontactThatSaysNothingIsNotAGuess() throws {
        let json = #"""
        {"version":9,"generatedAt":"now","results":[{"naturalKey":"k","contacts":[
          {"name":"Paper Lanterns","method":"form_or_dm","confidence":"low",
           "formUrl":"https://www.instagram.com/paperlanternsshow/","provenance":"act"}]}]}
        """#
        let decoded = try PrepResultsDecoder.decode(Data(json.utf8))
        #expect(decoded.results.first?.contacts?.first?.nameMatchOnly == nil)
    }

    // MARK: - What the app stores

    @Test func theGuessIsKeptAndRecordedAsOne() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)], into: p, ctx)

        let r = try #require(p.recipients.first)
        #expect(p.recipients.count == 1)
        #expect(r.contactFormURL == guessedHandle)
        #expect(r.nameMatchOnly)
    }

    // #2912 point 2, and the whole reason a second field exists. `confidence` cannot carry this: the
    // runbook maps every form or DM to `low`, so a CONFIRMED profile is already `low` and the two states
    // Dan must tell apart would share one value. The field says which, and the app makes the two agree
    // rather than leaving the card to choose between them (L16): a name match may never be `high`.
    @Test func aGuessCanNeverBeStoredAsVerified() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true, confidence: "high",
                        sourceUrl: "https://www.instagram.com/rowanashfieldmusic/")], into: p, ctx)

        let r = try #require(p.recipients.first)
        #expect(r.contactConfidence == .low)
        #expect(r.contactConfidence != .high)
        // And the citation guard is not what did it, so the card's held-down sentence (#1866, about a
        // check that claimed high and named no page) is not borrowed for a different situation.
        #expect(r.isHeldDownToUnverified == false)
    }

    // A later run that emits the same profile and says nothing is claiming the verification the runbook
    // requires for a bare `form_or_dm`, so the mark clears. Re-derived every ingest rather than latched,
    // exactly like the citation guard beside it, so an answer that got better is allowed to say so.
    @Test func aLaterRunThatConfirmsItClearsTheMark() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)], into: p, ctx)
        #expect(try #require(p.recipients.first).nameMatchOnly)

        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: nil)], into: p, ctx)
        #expect(p.recipients.count == 1)
        #expect(try #require(p.recipients.first).nameMatchOnly == false)
    }

    // MARK: - The app never claims it is a route

    // The refusal #2147 asked for, kept where it belongs: in what Overture ASSERTS. The verdict, the
    // score and the ledger see precisely what they saw when the run emitted nothing at all, so nothing
    // about this show ranks as reachable on the strength of a name.
    @Test func aGuessIsNotASocialRoute() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)], into: p, ctx)

        #expect(p.socialRouteURLs.isEmpty)
        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
        #expect(p.reachabilityResultFromRecipients != .socialOnly)
        #expect(Ranker.contactRoutePoints(ContactRoute(probeResult: .noEmailFound)) == -5)
    }

    // The confirmed one is untouched by all of this: it is still the route #2612 made it.
    @Test func aconfirmedProfileIsStillARoute() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Paper Lanterns", confirmedHandle, nameMatchOnly: nil)], into: p, ctx)

        #expect(p.socialRouteURLs == [confirmedHandle])
        #expect(p.reachabilityResultFromRecipients == .socialOnly)
    }

    // MARK: - The empty reason, which must stay honest (#2912 point 3)

    // The show is no longer `named_but_no_route`: names with no route is a finished search that found no
    // way in, and here a possible way in is on the card. It is not `only_social_profile` either, whose
    // sentence calls the account "this act's" and is the exact overclaim #2147 forbids.
    @Test func aguessOnlyShowGetsItsOwnReason() {
        let contacts = [profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)]
        let reason = Reachability.emptyReason(afterIngesting: contacts, usableRecipients: 0)
        #expect(reason == .unconfirmedSocialProfile)
        #expect(reason != .onlySocialProfile)
        #expect(reason != .namedButNoRoute)
    }

    // A person found with no route at all beside the guess does not swallow it: the card is showing a
    // handle, so the sentence above it has to be about the handle.
    @Test func aguessBesideSomebodyUnreachableStillReportsTheGuess() {
        let contacts = [profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true),
                        PrepContact(name: "Mira Sandoval", role: nil, email: nil,
                                    method: ContactMethod.noRouteFound.rawValue, confidence: "low",
                                    formUrl: nil, provenance: "performer")]
        #expect(Reachability.emptyReason(afterIngesting: contacts, usableRecipients: 0)
                == .unconfirmedSocialProfile)
    }

    // One confirmed profile among them and the show really does have a social route, so #2265's own
    // reason is the true one. The guess is marked on its own line instead (see the card tests below).
    @Test func aconfirmedProfileBesideAGuessKeepsTheSocialReason() {
        let contacts = [profile("Paper Lanterns", confirmedHandle, nameMatchOnly: nil),
                        profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)]
        #expect(Reachability.emptyReason(afterIngesting: contacts, usableRecipients: 0)
                == .onlySocialProfile)
    }

    // MARK: - What Dan reads (#2912 point 1)

    @Test func thebadgeSaysAProfileWasFoundAndNotConfirmed() {
        let badge = ReachabilityCopy.emptyAnswerBadge(.unconfirmedSocialProfile)
        #expect(badge == "Possible profile, not confirmed")
        // Distinct from every other sentence the same pill can carry, or it is one of them with a
        // quieter label, which is the substitution #2147 forbids.
        for other in Reachability.EmptyReason.allCases where other != .unconfirmedSocialProfile {
            #expect(badge != ReachabilityCopy.emptyAnswerBadge(other))
        }
        #expect(badge != ReachabilityCopy.noEmailFoundBadge)
        #expect(badge != ReachabilityCopy.socialOnlyBadge)
    }

    // It has to say WHAT could not be confirmed, in the words of the check that could not confirm it.
    // A row that only says "not confirmed" leaves Dan to guess whether the doubt is about the person,
    // the address or the show.
    @Test func thehelpNamesWhatCouldNotBeConfirmed() {
        let help = ReachabilityCopy.emptyAnswerHelp(.unconfirmedSocialProfile)
        #expect(help.contains("name"))
        #expect(help.contains("this show"))
        #expect(help != ReachabilityCopy.emptyAnswerHelp(.onlySocialProfile))
        #expect(help != ReachabilityCopy.emptyAnswerHelp(.namedButNoRoute))
        #expect(help != ReachabilityCopy.noEmailFoundHelp)
    }

    // The pill is not the rust of a finding of nothing, because something WAS found and Dan can act on
    // it in seconds, and not the gold of an address he can write to either. `tentative` is the tone whose
    // own definition is "found something, but cannot stand behind it".
    @Test func thepillIsNeitherAFindingNorAFailure() {
        #expect(Reachability.emptyAnswerTone(.unconfirmedSocialProfile) == .tentative)
        #expect(Reachability.emptyAnswerTone(.unconfirmedSocialProfile)
                != Reachability.tone(for: .noEmailFound))
        // Every other empty answer keeps exactly the tone it had.
        for other in Reachability.EmptyReason.allCases where other != .unconfirmedSocialProfile {
            #expect(Reachability.emptyAnswerTone(other) == Reachability.tone(for: .noEmailFound))
        }
        #expect(Reachability.emptyAnswerTone(nil) == Reachability.tone(for: .noEmailFound))
    }

    // MARK: - The card

    // The handle reaches the card. That is the whole ask: he looks at it and decides.
    @Test func thehandleIsOnTheCard() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)], into: p, ctx)

        let item = QueueItem(p)
        #expect(item.displayedContactForms.map(\.absoluteString) == [guessedHandle])
    }

    // Said ONCE. On a row showing one link the badge directly above it is already saying it, and a second
    // line under it that tells Dan nothing the first did not is the #843 shape (Dan's own call in #1628,
    // about the caveat that used to sit beside every address).
    @Test func aloneGuessIsMarkedByTheBadgeAndNotTwice() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)], into: p, ctx)
        p.reachabilityResult = p.reachabilityResultFromRecipients
        p.reachabilityEmptyReason = .unconfirmedSocialProfile
        p.reachabilityProbedAt = Date()

        let item = QueueItem(p)
        #expect(item.reachabilityBadge() == .noEmailFound)
        #expect(item.reachabilityEmptyReason == .unconfirmedSocialProfile)
        #expect(item.displayedContactRoutes().map(\.marksUnconfirmed) == [false])
    }

    // Two links and the badge can no longer say WHICH, so each guess carries its own mark. This is the
    // dangerous shape: a confirmed handle and a stranger's, side by side, reading identically.
    @Test func aguessBesideAConfirmedHandleIsMarkedOnItsOwnLine() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Paper Lanterns", confirmedHandle, nameMatchOnly: nil),
                profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)], into: p, ctx)
        p.reachabilityResult = p.reachabilityResultFromRecipients
        p.reachabilityEmptyReason = .onlySocialProfile
        p.reachabilityProbedAt = Date()

        let item = QueueItem(p)
        let routes = item.displayedContactRoutes()
        #expect(routes.count == 2)
        #expect(routes.first(where: { $0.url.absoluteString == guessedHandle })?.marksUnconfirmed == true)
        #expect(routes.first(where: { $0.url.absoluteString == confirmedHandle })?.marksUnconfirmed == false)
        // The link list the card draws is derived from this one, so the marks and the links can never
        // come from two different readings of the same row (L16).
        #expect(item.displayedContactForms.count == 2)
    }

    // Two guesses and no confirmed one: the badge speaks for both, so neither line repeats it.
    @Test func twoguessesAreStillCoveredByOneBadge() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true),
                profile("Mira Sandoval", secondGuessedHandle, nameMatchOnly: true)], into: p, ctx)
        p.reachabilityResult = p.reachabilityResultFromRecipients
        p.reachabilityEmptyReason = .unconfirmedSocialProfile
        p.reachabilityProbedAt = Date()

        let item = QueueItem(p)
        #expect(item.displayedContactRoutes().count == 2)
        #expect(item.displayedContactRoutes().allSatisfy { $0.marksUnconfirmed == false })
    }

    // A row whose badge is NOT carrying the sentence (an older stored answer that predates this, so its
    // reason says something else) marks the line itself rather than leaving a bare handle reading as a
    // found contact. The mark fails closed (L42).
    @Test func aguessUnderAnOlderBadgeIsMarkedOnItsLine() throws {
        let ctx = try context()
        let p = show(ctx)
        ingest([profile("Rowan Ashfield", guessedHandle, nameMatchOnly: true)], into: p, ctx)
        p.reachabilityResult = .noEmailFound
        p.reachabilityEmptyReason = .nothingPublished
        p.reachabilityProbedAt = Date()

        let item = QueueItem(p)
        #expect(item.displayedContactRoutes().map(\.marksUnconfirmed) == [true])
    }

    // And the line's own words say the same thing the badge does, in the length a right-justified meta
    // column can carry.
    @Test func themarkOnTheLineSaysWhatIsMissing() {
        #expect(ReachabilityCopy.unconfirmedProfileNote == "Name matches, nothing ties it to this show")
        #expect(ReachabilityCopy.unconfirmedProfileNote != ReachabilityCopy.socialOnlyBadge)
    }
}
