import Testing
import Foundation
import SwiftData
@testable import Overture

// #1628: the reachability badge said WHAT was found and never HOW SURE the check was, so a guess and a
// verified find wore the same card. Two rows from the 2026-07-27 run, both stored `low`: "Mind Games"
// (SoHo Playhouse, an off Broadway show) returned a booking form for a San Francisco Bay Area magician,
// and "Copeland" (Jalopy Theatre, a Red Hook folk room) returned the merch site of the Florida rock band.
//
// FIRST ATTEMPT, RETIRED. A per-address "not verified" caveat printed beside every unverified contact.
// It went through three layouts (trailing the address, leading it, then its own grid column) and each one
// broke the address column differently, the last by making long addresses wrap. Dan's call, 2026-07-28:
// drop the per-address caveat entirely, he can already tell a generic inbox by looking at it, and say it
// ONCE in the badge instead.
//
// THE RULE NOW. When a check found an address but NOTHING it found was verified, the badge itself says
// so. If even one contact was verified, the badge stays plain, because he has something solid to write
// to and the weaker sibling beside it is not worth a warning.
//
// LIVE-STORE-CLAIM verified=2026-07-27 measure="stored recipients by contactConfidence"
// Measured on the live store 2026-07-27: 10 of 29 stored contacts are `low` and 8 are `medium`, so only
// 11 are an address read off a page naming the act. None carries a nil confidence.
@MainActor
@Suite("Unverified contacts are named once, in the badge (#1628)")
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

    @Test func aGuessedAddressIsStillIdentified() throws {
        let i = item(ModelContext(try container()), [contact(email: "jake@jakebergmagic.example", .low)])
        #expect(i.unverifiedContactEmails == ["jake@jakebergmagic.example"])
    }

    @Test func anAddressReadOffARealPageIsNotFlagged() throws {
        let i = item(ModelContext(try container()), [contact(email: "mark@groovmarketing.example", .high)])
        #expect(i.unverifiedContactEmails.isEmpty)
    }

    // A generic inbox counts as unverified: nothing established it belongs to this act. Dan's call,
    // 2026-07-28, taken with the measurement in front of him showing confidence largely restates the
    // contact type.
    @Test func aGenericInboxCountsAsUnverified() throws {
        let i = item(ModelContext(try container()), [contact(email: "info@sohoplayhouse.example", .medium)])
        #expect(i.unverifiedContactEmails == ["info@sohoplayhouse.example"])
    }

    // Fails closed: no confidence recorded means nothing established the address.
    @Test func anAddressWithNoConfidenceRecordedCountsAsUnverified() throws {
        let i = item(ModelContext(try container()), [contact(email: "mystery@example.com", nil)])
        #expect(i.unverifiedContactEmails == ["mystery@example.com"])
    }

    // THE RULE DAN ASKED FOR. Everything found is a guess, so the badge says so.
    @Test func theBadgeSaysUnverifiedWhenNothingFoundWasVerified() throws {
        let i = item(ModelContext(try container()), [contact(email: "a@example.com", .low),
                                                     contact(email: "b@example.com", .medium)])
        #expect(i.onlyUnverifiedEmailsFound)
    }

    // AND THE OTHER HALF, which is what stops it crying wolf: one solid address is enough, so a weaker
    // sibling beside it earns no warning. His words: "it wouldn't say that if we found one unverified
    // and one verified."
    @Test func theBadgeStaysPlainWhenEvenOneContactWasVerified() throws {
        let i = item(ModelContext(try container()), [contact(email: "anna@annapierre.example", .high),
                                                     contact(email: "j.reed@gmail.example", .low)])
        #expect(!i.onlyUnverifiedEmailsFound)
    }

    @Test func theBadgeStaysPlainWhenEverythingWasVerified() throws {
        let i = item(ModelContext(try container()), [contact(email: "mark@groovmarketing.example", .high)])
        #expect(!i.onlyUnverifiedEmailsFound)
    }

    // A show with no address at all must not claim an unverified one was found; its badge is a different
    // state entirely ("No email found" or "Contact form only").
    @Test func aShowWithNoAddressMakesNoClaim() throws {
        let i = item(ModelContext(try container()), [])
        #expect(!i.onlyUnverifiedEmailsFound)
    }

    // An address inherited from another show by the same organisation (#1598 Phase 5) carries no
    // confidence, because the org ledger stores the addresses and not how sure each one was. Claiming it
    // is unverified would assert something no check measured, so an inherited answer stays plain.
    @Test func anInheritedAddressIsNeverCalledUnverified() throws {
        var i = item(ModelContext(try container()), [])
        i.inheritedReachability = OrgAnswerLedger.Inherited(result: .emailFound,
                                                           probedAt: Date(timeIntervalSince1970: 1_000),
                                                           organisation: "TENET Vocal Artists",
                                                           emails: ["hello@tenet.example"])
        #expect(i.displayedContactEmails == ["hello@tenet.example"])
        #expect(!i.onlyUnverifiedEmailsFound)
    }

    @Test func theBadgeWordingSaysWhatWasActuallyEstablished() {
        #expect(ReachabilityCopy.unverifiedEmailFoundBadge == "Unverified email found")
    }

    // The explanation has to actually be REACHABLE from the badge. When the per-address caveat was
    // retired its help text was orphaned: the sentence stayed in the code, nothing referenced it, and
    // hovering the new badge explained the wrong thing entirely. Caught only by re-reading the copy in
    // the place that now produces it, which is the step this project requires and I skipped.
    @Test func theExplanationIsWiredToTheBadgeThatNeedsIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Overture/UI/ProspectRowView.swift"), encoding: .utf8)
        #expect(source.contains("unverifiedEmailFoundHelp"),
                "hovering an unverified find must explain what unverified means")
    }

    // Reworded for its new job: it now speaks for EVERY address on the row, not one caveat beside a
    // single line, and it must read for a single address as well as several. It also no longer mentions
    // contact forms, which never reach this badge.
    @Test func theExplanationSpeaksForTheWholeRowNotOneAddress() {
        let help = ReachabilityCopy.unverifiedEmailFoundHelp
        #expect(!help.contains("this one"), "written for a per-address caveat that no longer exists")
        #expect(!help.contains("contact form"), "a form never reaches this badge")
        #expect(help.contains("worth a look before you write"))
    }

    // The per-address caveat is GONE from the row, which is the point of this change: it is what made
    // long addresses wrap. The row must not reintroduce it.
    @Test func theRowNoLongerPrintsAPerAddressCaveat() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Overture/UI/ProspectRowView.swift"), encoding: .utf8)
        #expect(!source.contains("unverifiedContactMark"),
                "the per-address caveat was retired; it belongs in the badge now")
        #expect(source.contains("unverifiedEmailFoundBadge"),
                "the badge must carry the wording instead")
    }
}
