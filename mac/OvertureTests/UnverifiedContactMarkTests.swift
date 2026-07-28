import Testing
import Foundation
import SwiftData
@testable import Overture

// #1628: the reachability badge says WHAT was found and never HOW SURE the check was, so a guess and a
// verified find wear the same card. The runbook's own rule makes `low` precise: `high` is allowed ONLY
// for an address actually READ from a real page (and carries the citation URL the badge links to),
// `medium` is a generic inbox, and `low` is inferred, pattern-guessed, or a bare name match with no page
// tying that person to THIS performance. So `low` means "this may be the wrong act entirely".
//
// Two real rows from the 2026-07-27 run, both stored `low`, both presented exactly like a contact taken
// off the act's own site: "Mind Games" (SoHo Playhouse, an off Broadway show with no listing page at all)
// returned a booking form for a San Francisco Bay Area magician, and "Copeland" (Jalopy Theatre, a
// roughly 100 seat Red Hook folk room) returned the merch site of the Florida rock band.
//
// LIVE-STORE-CLAIM verified=2026-07-27 measure="stored recipients by contactConfidence"
// Measured on the live store 2026-07-27: 10 of 29 stored contacts are `low`, so a third of what the card
// presents as a find is a guess. None carries a nil confidence.
@MainActor
@Suite("Unverified contact mark (#1628)")
struct UnverifiedContactMarkTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Mind Games", discipline: "theater",
                         venue: "SoHo Playhouse", performanceDate: "2026-09-18", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "neutral", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func contact(email: String? = nil, form: String? = nil,
                         _ confidence: ContactConfidence?) -> Recipient {
        let r = Recipient(id: email ?? form ?? "r", email: email, name: "Someone", provenance: .act)
        r.contactFormURL = form
        r.contactConfidence = confidence
        return r
    }

    private func item(_ ctx: ModelContext, _ recipients: [Recipient]) -> QueueItem {
        let p = show(ctx)
        p.setRecipients(recipients)
        return QueueItem(p)
    }

    @Test func aGuessedAddressIsMarkedUnverified() throws {
        let i = item(ModelContext(try container()), [contact(email: "jake@jakebergmagic.example", .low)])
        #expect(i.unverifiedContactEmails == ["jake@jakebergmagic.example"])
    }

    // The other side of the same claim: an address READ off a real page must NOT be marked, or the mark
    // is noise on every row and Dan stops seeing it.
    @Test func anAddressReadOffARealPageIsNotMarked() throws {
        let i = item(ModelContext(try container()), [contact(email: "mark@groovmarketing.example", .high)])
        #expect(i.unverifiedContactEmails.isEmpty)
    }

    // DAN'S CALL, 2026-07-27, made with the measurement in front of him. The stored confidence turns out
    // to be a near-mechanical restatement of the contact METHOD: across all 29 stored contacts, every
    // form or DM is `low` (9 of 9), every generic inbox is `medium` (8 of 8), and a named person is
    // `high` except once. So it cannot separate a form on the right act's site (marcribler.com, which
    // #1626 confirmed) from one on the wrong act's (shop.copeland.band), and a mark driven by it flags
    // both the same. Told that, Dan chose to mark everything that is not a verified address anyway: a
    // generic inbox and a contact form ARE weaker than an address read off the act's own page, and he
    // would rather see that on every one of them than have the distinction go unsaid.
    //
    // So "verified" means exactly what the runbook allows `high` for: an address actually READ from a
    // real page, corroborated against this performance for a named performer. Everything else is marked.
    @Test func aGenericInboxIsMarkedToo() throws {
        let i = item(ModelContext(try container()), [contact(email: "info@sohoplayhouse.example", .medium)])
        #expect(i.unverifiedContactEmails == ["info@sohoplayhouse.example"])
    }

    // Fails closed. No confidence recorded means nothing established this address, so it reads as not
    // verified rather than silently as a find. Cannot happen from the live path today (all 29 stored
    // contacts carry one), which is exactly why it costs nothing to be safe here.
    @Test func anAddressWithNoConfidenceRecordedIsMarked() throws {
        let i = item(ModelContext(try container()), [contact(email: "mystery@example.com", nil)])
        #expect(i.unverifiedContactEmails == ["mystery@example.com"])
    }

    // One show, two performers found, one verified and one not. The mark is per contact, which is the
    // whole reason it lives on the address line rather than on the row's badge.
    @Test func onlyTheUnverifiedOneOfTwoContactsIsMarked() throws {
        let i = item(ModelContext(try container()), [contact(email: "anna@annapierre.example", .high),
                                                     contact(email: "j.reed@gmail.example", .low)])
        #expect(i.unverifiedContactEmails == ["j.reed@gmail.example"])
    }

    // The Copeland and Jake Berg shape: no address at all, a form on a site that may belong to a
    // completely different act. The "Contact form only" badge says there is a way through; it says
    // nothing about whether it reaches the right people.
    @Test func aGuessedContactFormIsMarkedUnverified() throws {
        let i = item(ModelContext(try container()), [contact(form: "https://shop.copeland.example", .low)])
        #expect(i.unverifiedContactForms.map(\.absoluteString) == ["https://shop.copeland.example"])
    }

    @Test func aVerifiedContactFormIsNotMarked() throws {
        let i = item(ModelContext(try container()),
                     [contact(form: "https://marcribler.example/contact", .high)])
        #expect(i.unverifiedContactForms.isEmpty)
    }

    // An address inherited from another show by the same organisation (#1598 Phase 5) carries no
    // confidence: the org ledger stores the addresses and not how sure each one was. Marking it would
    // assert something no check ever measured, which is the opposite of the honesty this adds, so an
    // inherited address is left unmarked and the gap is filed rather than guessed at.
    @Test func anInheritedAddressIsNeverMarkedBecauseTheLedgerStoresNoConfidence() throws {
        var i = item(ModelContext(try container()), [])
        i.inheritedReachability = OrgAnswerLedger.Inherited(result: .emailFound,
                                                           probedAt: Date(timeIntervalSince1970: 1_000),
                                                           organisation: "TENET Vocal Artists",
                                                           emails: ["hello@tenet.example"])
        #expect(i.displayedContactEmails == ["hello@tenet.example"])
        #expect(i.unverifiedContactEmails.isEmpty)
    }

    @Test func theMarkSaysWhatTheCheckActuallyMeasured() {
        #expect(ReachabilityCopy.unverifiedContactMark == "not verified")
    }

    // The mark being CORRECT and the mark being DRAWN are two separate claims, and only the second one
    // reaches Dan. A SwiftUI body cannot be asserted on directly, so this pins the wiring at the source,
    // the same guard shape InheritedReachabilityWiringGuardTests uses for #1598.
    @Test func theRowActuallyDrawsTheMark() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // OvertureTests
            .deletingLastPathComponent()          // mac
            .appendingPathComponent("Overture/UI/ProspectRowView.swift"), encoding: .utf8)
        #expect(source.contains("unverifiedContactEmails"),
                "the address line must ask the model which addresses are unverified")
        #expect(source.contains("unverifiedContactForms"),
                "the form link must ask the same question")
        #expect(source.contains("ReachabilityCopy.unverifiedContactMark"),
                "the words come from the copy inventory, not from the view")
    }
}
