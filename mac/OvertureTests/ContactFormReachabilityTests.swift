import Testing
import Foundation
import SwiftData

// #1626: a show whose act publishes no email but does publish a contact form on its own site is
// REACHABLE, and Scout used to call it "No email found" while holding the link.
//
// Measured on the first real multi-date run (#1603, 2026-07-27): the check identified the act on 14 of
// 14 shows. 8 published an email; 6 published only a form or an Instagram, and every one of those six
// was stored with a real contactFormURL and rendered as a dead end. Three of them were forms on the
// act's own site (jakebergmagic.com/contact, shop.copeland.band, marcribler.com/contact), so on that
// one night Dan was being told to give up on three shows he could have written to.
//
// Dan's rule, 2026-07-27: a form on the act's OWN site counts and he will fill it in by hand. An
// Instagram or other social DM does not, consistent with the standing "a social page is a dead end"
// rule (#1004, and Reachability.assess's own social test).
@MainActor
@Suite("A contact form is a way through (#1626)")
struct ContactFormReachabilityTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, group: String = "Mind Games") -> Prospect {
        let p = Prospect(naturalKey: "k-\(group)", groupName: group, discipline: "theater",
                         venue: "SoHo Playhouse", performanceDate: "2026-09-18", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "neutral", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func formContact(_ url: String) -> Recipient {
        let r = Recipient(id: url, email: nil, name: "Jake Berg", provenance: .act)
        r.contactFormURL = url
        r.contactMethodRaw = "form_or_dm"
        return r
    }

    // The real row from the live store, verbatim.
    @Test func aFormOnTheActsOwnSiteIsReachable() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([formContact("https://jakebergmagic.com/contact")])

        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
        var item = QueueItem(p)
        item.reachabilityProbedAt = Date()
        item.reachabilityResult = .contactFormOnly
        #expect(item.reachabilityBadge() == .contactFormOnly)
        #expect(item.displayedContactForms.map(\.absoluteString) == ["https://jakebergmagic.com/contact"])
    }

    // The row labels the link with the site, because the pill above it already says "contact form" and
    // what this line owes Dan is who he would be writing to.
    @Test("the form link is labelled with the site, not with the words the pill already said",
          arguments: [("https://jakebergmagic.com/contact", "jakebergmagic.com"),
                      ("https://shop.copeland.band/pages/contact", "shop.copeland.band"),
                      ("https://www.marcribler.com/contact", "marcribler.com")])
    func theFormLinkIsLabelledWithTheSite(_ pair: (String, String)) {
        #expect(QueueModel.contactFormSiteLabel(URL(string: pair.0)!) == pair.1)
    }

    // Dan's line, REVERSED by #2612 on 2026-08-13: "I actually do want to know when it's instagram only
    // with no contact form... I'm going to DM them on instagram." An Instagram is where a check ends up
    // when the act publishes nothing of its own, and he works that route by hand, so the card offers it
    // and the verdict says which kind of route it is.
    @Test func aninstagramIsARouteWithItsOwnVerdict() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, group: "Gimme A Sign!")
        p.setRecipients([formContact("https://www.instagram.com/heybailay/")])

        #expect(p.reachabilityResultFromRecipients == .socialOnly)
        var item = QueueItem(p)
        item.reachabilityResult = .socialOnly
        #expect(item.displayedContactForms.map(\.absoluteString) == ["https://www.instagram.com/heybailay/"])
    }

    @Test func anEmailStillBeatsAForm() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let email = Recipient(id: "e", email: "hello@example.org", name: "Someone", provenance: .act)
        p.setRecipients([email, formContact("https://jakebergmagic.com/contact")])

        #expect(p.reachabilityResultFromRecipients == .emailFound)
    }

    @Test func aShowWithNothingAtAllIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
    }

    // A form-only answer is NOT a sendable contact: Dan writes to it by hand, so it must never be
    // crowned the "best reachable contact" the row highlights (#1338), which exists to mean "you can
    // send to this one right now".
    @Test func aFormIsNeverTheBestReachableContact() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([formContact("https://jakebergmagic.com/contact")])
        var item = QueueItem(p)
        item.reachabilityResult = .contactFormOnly
        item.reachabilityProbedAt = Date()

        #expect(item.reachabilityBadge() != .emailFound)
    }

    // Only a found EMAIL travels across an organisation (#1598). A form answer stays on its own show
    // until there is evidence for widening that, which this one night does not provide.
    @Test func aFormAnswerDoesNotFanOutAcrossAnOrganisation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let answer = OrgAnswerLedger.Answer(orgKey: OrgKey.stored(for: "Tenet Vocal Artists")!,
                                            result: .contactFormOnly, probedAt: now,
                                            presenterName: "Tenet Vocal Artists", emails: [])
        let shows = [
            OrgAnswerLedger.Show(key: "paid", presenter: "Tenet Vocal Artists",
                                 venue: "Church of the Ascension", hasOwnAnswer: true),
            OrgAnswerLedger.Show(key: "free", presenter: "Tenet Vocal Artists",
                                 venue: "House of the Redeemer", hasOwnAnswer: false),
        ]
        #expect(OrgAnswerLedger.inherited(from: [answer], shows: shows, now: now, heldKeys: [])["free"] == nil)
    }

    // LIVE-STORE-CLAIM verified=2026-07-27 measure="rows from the 2026-07-27 probe run stamped no_email_found before the #1626 upgrade pass"
    // The six rows from the 2026-07-27 run are already sitting in the live store stamped
    // `no_email_found`, and the stored verdict is what the badge reads (#1596). Without this pass they
    // would keep reading as dead ends until Dan paid to check them a second time.
    @Test func theMigrationUpgradesRowsAlreadyStampedNoEmailFound() throws {
        let ctx = ModelContext(try container())
        let ownSite = show(ctx, group: "Mind Games")
        ownSite.setRecipients([formContact("https://jakebergmagic.com/contact")])
        ownSite.reachabilityProbedAt = Date()
        ownSite.reachabilityResult = .noEmailFound

        let social = show(ctx, group: "Gimme A Sign!")
        social.setRecipients([formContact("https://www.instagram.com/heybailay/")])
        social.reachabilityProbedAt = Date()
        social.reachabilityResult = .noEmailFound

        #expect(ContactFormResultMigration.run(in: ctx) == 1)
        #expect(ownSite.reachabilityResult == .contactFormOnly)
        #expect(social.reachabilityResult == .noEmailFound)
        #expect(ContactFormResultMigration.run(in: ctx) == 0)
    }

    // Rehearsed against a COPY of the real Release store, never the live file. This pass edits rows Dan
    // has already been shown, so "it only moves the one verdict" is worth proving against his data
    // rather than only against fixtures. Skips cleanly on a machine with no live store.
    @Test func theMigrationRehearsesCleanlyAgainstACloneOfTheLiveStore() throws {
        let fm = FileManager.default
        let live = StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        guard fm.fileExists(atPath: live.path) else { return }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("form-dryrun-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }
        // #1672: through the ONE shared clone, which takes the copy via SQLite's online backup
        // rather than racing three file copies against a live writer. See LiveStoreClone.
        guard let copy = try LiveStoreClone.makeClone(in: tmpDir) else { return }

        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let before = try ctx.fetch(FetchDescriptor<Prospect>())
        // Every verdict this pass must NOT touch: found, weak, and never checked.
        let untouchable = before.filter { $0.reachabilityResult != .noEmailFound }
            .map { ($0.naturalKey, $0.reachabilityResultRaw) }
        // #2664: which rows were ALREADY form-only before this pass ran, so the assertion below can be
        // about the ones the migration MOVED rather than about every row in Dan's store.
        let alreadyFormOnly = Set(before.filter { $0.reachabilityResult == .contactFormOnly }
            .map(\.naturalKey))

        let changed = ContactFormResultMigration.run(in: ctx)
        try ctx.save()

        // copy-inventory:ignore-start  a test diagnostic, not a sentence Overture says on screen
        print("CONTACT FORM DRY RUN: upgraded \(changed) rows of \(before.count)")
        // copy-inventory:ignore-end
        let after = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(after.count == before.count)
        // Every row THIS PASS MOVED really does hold a usable form.
        //
        // #2664: scoped to the rows it moved, which is what this test is for. It used to assert the rule
        // over every form-only row in the store, which is a claim about Dan's DATA rather than about the
        // migration, and any hand edit he makes can break it. One did on 2026-08-13: he deleted a show's
        // only contact (wanting to add the producer instead, which #2629 is about), the show kept the
        // `contact_form_only` verdict the check had written, and this assertion went red and blocked every
        // merge from the repo until somebody repaired his store.
        //
        // Deliberately NOT a weakening, and the difference matters: the store-wide rule is real and still
        // holds, and it now has an owner in #2664, which will carry its own guard on the delete path where
        // the defect actually lives. What this test is left asserting is the thing it exists to prove, that
        // the pass only ever moves a row it can justify. Both halves are still watched; the difference is
        // that a defect in Dan's data no longer reports itself as a defect in this migration.
        let moved = after.filter {
            $0.reachabilityResult == .contactFormOnly && !alreadyFormOnly.contains($0.naturalKey)
        }
        // The count it REPORTS and the rows it actually moved come from one comparison, so a pass that
        // claims a number it did not move fails here (L16). This is also what keeps the assertion below
        // from being quietly vacuous: on a store where the migration has already run, `changed` is 0 and
        // `moved` is empty, and that agreement is asserted rather than read as a pass (L98).
        #expect(moved.count == changed,
                "the pass reported \(changed) upgrades and \(moved.count) rows are newly form-only")
        #expect(moved.allSatisfy { !$0.usableContactFormURLs.isEmpty })
        // And every verdict it was not allowed to touch is byte for byte what it was.
        let byKey = Dictionary(after.map { ($0.naturalKey, $0.reachabilityResultRaw) },
                               uniquingKeysWith: { a, _ in a })
        #expect(untouchable.allSatisfy { byKey[$0.0] == $0.1 })
        #expect(ContactFormResultMigration.run(in: ctx) == 0)
    }

    // It upgrades ONLY that one direction. A row Dan has decided about, or one stamped with any other
    // verdict, is left exactly as it is: #1596's rule that dismissing a venue warning does not move the
    // badge (his call, 2026-07-27) must survive this pass.
    @Test func theMigrationTouchesNothingElse() throws {
        let ctx = ModelContext(try container())
        let weak = show(ctx, group: "Weak")
        let venueContact = Recipient(id: "v", email: "desk@venue.example", name: "Desk", provenance: .act)
        venueContact.looksLikeVenue = true
        weak.setRecipients([venueContact])
        weak.reachabilityProbedAt = Date()
        weak.reachabilityResult = .weakContactOnly

        let neverChecked = show(ctx, group: "Never checked")
        neverChecked.setRecipients([formContact("https://jakebergmagic.com/contact")])

        #expect(ContactFormResultMigration.run(in: ctx) == 0)
        #expect(weak.reachabilityResult == .weakContactOnly)
        #expect(neverChecked.reachabilityResult == nil)
    }
}
