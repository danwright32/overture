import Testing
import Foundation
import SwiftData

// #2612: an Instagram-only act is a route Dan will use, not a dead end.
//
// His words, 2026-08-13, looking at the Song & Word card (Vivace Arts Collective, The Green Room 42):
// "I changed my mind and I actually do want to know when it's instagram only with no contact form. This
// actually feels like a perfect fit for me but they don't have a website so I'm going to DM them on
// instagram. It feels perfect because it's a new company with less than 50 followers and only a few
// instagram posts so they likely really need promotional materials."
//
// That reverses two of his own decisions, #1626 ("an Instagram is a dead end") and #2421 (delete the ones
// already stored). Before it, the handle was found by the run, discarded at ingest, and the card was told
// to give up: the exact show he calls a perfect fit was the one the app was most confident he should drop,
// at minus 5 and LONG SHOT.
//
// LIVE-STORE-CLAIM verified=2026-08-13 measure="ZRECIPIENT rows carrying a contactFormURL, by host"
// 30 stored contacts hold a form on the act's own site and 4 hold a social profile, so both routes exist
// on the live store today. The 45 contacts #2421 deleted are gone and only a fresh check recovers them.
@MainActor
@Suite("A social DM is a route (#2612)")
struct SocialDMIsARouteTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, venue: String = "Under St Marks") -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "A Spanglish Affair Open Mic",
                                          performanceDate: "2026-08-17", venue: venue)
        let p = Prospect(naturalKey: key, groupName: "A Spanglish Affair Open Mic", discipline: "theater",
                         venue: venue, performanceDate: "2026-08-17", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 2, tier: "longshot",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func results(_ key: String, formUrl: String, name: String = "Something From Abroad") -> PrepResults {
        PrepResults(version: 9, generatedAt: "2026-08-13T00:00:00Z",
                    results: [PrepResult(naturalKey: key,
                                         contacts: [PrepContact(name: name, role: nil, email: nil,
                                                                method: "form_or_dm", confidence: "low",
                                                                formUrl: formUrl, provenance: "act")],
                                         draft: nil)])
    }

    // THE test, and it is the live payload: the exact contact the 10:46 run emitted on 2026-08-13, which
    // under the old rule was dropped at ingest with the handle left in a run artifact the next run
    // overwrote.
    @Test func aninstagramOnlyActIsKeptAndReadsAsARoute() throws {
        let ctx = try context()
        let p = show(ctx)

        _ = PrepImporter.ingest(results(p.naturalKey,
                                        formUrl: "https://www.instagram.com/somethingfromabroad/"), into: ctx)

        #expect(p.recipients.count == 1)
        #expect(p.socialRouteURLs == ["https://www.instagram.com/somethingfromabroad/"])
        #expect(p.reachabilityResultFromRecipients == .socialOnly)
        #expect(p.reachabilityResultFromRecipients != .noEmailFound)
    }

    // The score. It used to cost the same as a dead end, so an Instagram-only show ranked below shows Dan
    // has no more chance with, purely because the one route it had was thrown away.
    // Dan's call, 2026-08-13, asked directly: "social dm is worth less than a contact form. I probably
    // won't use it unless it's a really good fit in other ways." So it sits between the two: no longer the
    // dead end's -5, and below the form on its own site.
    @Test func aDMIsWorthLessThanAFormAndMoreThanADeadEnd() {
        #expect(Ranker.contactRoutePoints(.socialOnly) == 0)
        #expect(Ranker.contactRoutePoints(.socialOnly) < Ranker.contactRoutePoints(.contactFormOnly))
        #expect(Ranker.contactRoutePoints(.socialOnly) > Ranker.contactRoutePoints(.noEmailFound))
        #expect(Ranker.contactRoutePoints(.noEmailFound) == -5)
        // And the verdict maps to it, so the stored answer and the score cannot disagree.
        #expect(ContactRoute(probeResult: .socialOnly) == .socialOnly)
    }

    // The badge, which is the half Dan asked for by name: he wants to KNOW when it is Instagram only, and
    // it has to be distinguishable from a form on the act's own site because what he does differs.
    @Test func thebadgeSaysWhichKindOfRouteItIs() {
        let social = Reachability.badge(result: .socialOnly, presenter: "Vivace Arts Collective",
                                        sourceListingURL: nil, websiteURL: nil)
        let form = Reachability.badge(result: .contactFormOnly, presenter: "Vivace Arts Collective",
                                      sourceListingURL: nil, websiteURL: nil)

        #expect(social == .socialOnly)
        #expect(social != form)
        #expect(ReachabilityCopy.socialOnlyBadge != ReachabilityCopy.contactFormOnlyBadge)
        // Not a failure sentence: the row has a way through, and the badge must not read as giving up.
        #expect(ReachabilityCopy.socialOnlyBadge != ReachabilityCopy.noEmailFoundBadge)
    }

    // The card prints the link, labelled with the HANDLE. The host alone is the same string for every act
    // on Instagram, so it would answer none of what this label exists to answer (#1626: who am I writing
    // to?).
    @Test func thecardOffersTheProfileLabelledByHandle() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(results(p.naturalKey,
                                        formUrl: "https://www.instagram.com/somethingfromabroad/"), into: ctx)

        let item = QueueItem(p)
        let forms = item.displayedContactForms

        #expect(forms.map(\.absoluteString) == ["https://www.instagram.com/somethingfromabroad/"])
        #expect(QueueModel.contactFormSiteLabel(try #require(forms.first))
                == "instagram.com/somethingfromabroad")
    }

    // A form on the act's own site is still the stronger of the two hand routes, so a show holding both
    // says the one Dan reaches for first.
    @Test func aformOnTheirOwnSiteStillOutranksADM() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(PrepResults(version: 9, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey, contacts: [
                PrepContact(name: "A", role: nil, email: nil, method: "form_or_dm", confidence: "low",
                            formUrl: "https://www.instagram.com/somethingfromabroad/", provenance: "act"),
                PrepContact(name: "B", role: nil, email: nil, method: "form_or_dm", confidence: "low",
                            formUrl: "https://somethingfromabroad.example/contact", provenance: "act"),
            ], draft: nil),
        ]), into: ctx)

        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
    }

    // Failure path: the ROOM's own Instagram is no more a route than the room's own booking form, judged
    // through the same guard (#1629). Without this, re-opening the social route would quietly re-open the
    // oldest standing rule in the product (#368).
    @Test func theroomsOwnProfileIsNotARoute() throws {
        let ctx = try context()
        let p = show(ctx, venue: "Jalopy Theatre")
        _ = PrepImporter.ingest(results(p.naturalKey,
                                        formUrl: "https://www.instagram.com/jalopytheatre/"), into: ctx)

        #expect(p.socialRouteURLs.isEmpty)
        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
    }

    // MARK: the hand-sent outreach, reusing the path the contact form already has

    @Test func theexistingCopyAndConfirmPathServesADM() throws {
        let ctx = try context()
        let p = show(ctx)
        _ = PrepImporter.ingest(results(p.naturalKey,
                                        formUrl: "https://www.instagram.com/somethingfromabroad/"), into: ctx)

        guard case let .ready(recipientId, routeURL) = FormPitch.state(of: p) else {
            Issue.record("a social-only show offers no way to pitch it by hand")
            return
        }
        #expect(routeURL == "https://www.instagram.com/somethingfromabroad/")

        let r = try #require(p.recipients.first { $0.id == recipientId })
        p.beginFormPitch(r, now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(p.recordFormOutreach(r, now: Date(timeIntervalSince1970: 1_780_000_100),
                                     formURL: r.contactFormURL))
        #expect(r.outreachChannel == .contactForm)
        #expect(r.sendState == .sent)
    }

    // The wording follows the app Dan actually opens. "You opened their form" about an Instagram profile
    // asks him about something that did not happen (L11).
    @Test func thewordingNamesWhatHeOpened() {
        let started = Date(timeIntervalSince1970: 1_780_000_000)
        let later = started.addingTimeInterval(FormOutreachCopy.elapsedWorthSaying + 60)

        #expect(FormOutreachCopy.copyAndOpen(isSocial: true) != FormOutreachCopy.copyAndOpen(isSocial: false))
        #expect(FormOutreachCopy.awaitingQuestion(startedAt: started, now: later, isSocial: true)
                != FormOutreachCopy.awaitingQuestion(startedAt: started, now: later, isSocial: false))
        #expect(FormOutreachCopy.sentLine(formURL: "https://www.instagram.com/x/")
                == FormOutreachCopy.sentLineSocial)
        #expect(FormOutreachCopy.sentLine(formURL: "https://act.example/contact") == FormOutreachCopy.sentLine)
        // A record written before this existed has no stored URL, and must not be re-described as a DM.
        #expect(FormOutreachCopy.sentLine(formURL: nil) == FormOutreachCopy.sentLine)
    }

    // The subject line, which the issue flagged as needing handling: it needed none, and this pins why.
    // The clipboard has only ever carried the BODY, so a DM (which has no subject) was already served by
    // the path this change reuses.
    @Test func whatIsCopiedCarriesNoSubjectLine() throws {
        let ctx = try context()
        let p = show(ctx)
        p.draftSubject = "Photographing A Spanglish Affair Open Mic"
        p.draftBody = "Hi there,\n\nI photograph performing arts in New York."
        _ = PrepImporter.ingest(results(p.naturalKey,
                                        formUrl: "https://www.instagram.com/somethingfromabroad/"), into: ctx)
        let r = try #require(p.recipients.first)

        let copied = try #require(OutgoingPitch.text(for: r, of: p))

        #expect(copied == p.draftBody)
        #expect(!copied.contains("Photographing A Spanglish Affair Open Mic"))
    }
}

// #2612 item 5: the sweep that deleted these contacts is removed rather than left standing. With the
// ingest deliberately keeping a social route, a launch pass that deleted them would undo the fix every
// time the app started (L116: a rule that encodes a preference must never be enforced by deletion).
@Suite("The dead-end sweep is gone (#2612)")
struct DeadEndSweepIsGoneTests {
    @Test func nothingAtLaunchSweepsASocialContactAway() {
        let launch = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        #expect(!launch.isEmpty)
        // Comments are stripped, so the paragraph explaining why the sweep was removed cannot satisfy a
        // guard about the sweep being gone (L103: a check green on prose is indistinguishable from one
        // that works).
        let code = SwiftSource.scannableLines(in: launch).map(\.code).joined(separator: "\n")
        #expect(!code.contains("DeadEndContactSweep"))
        #expect(code.contains("DuplicateContactMerge"), "the file was not read as code at all")
    }
}
