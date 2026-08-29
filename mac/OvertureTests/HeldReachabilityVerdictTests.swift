import Testing
import Foundation
import SwiftData

// #2664: a stored reachability verdict is what a check CONCLUDED, and it can outlive the contacts that
// justified it. Deleting a show's last contact by hand leaves the verdict behind, and the badge, which
// read the stored value as the last word, then promised Dan a route that exists nowhere in the app.
//
// Measured on the live Release store, 2026-08-13. Prospect 879, "54 Sings Shuffle Along, Or... A 10th
// Anniversary Celebration" (54 Below, 2026-08-17), four days out and sitting at `drafted`:
//
//   verdict   contact_form_only
//   contacts  0
//
// Dan deleted the contacts himself, wanting to add the producer instead (#2629). The check had done its
// job; what was missing was the other half, that a delete owes something to the row it empties. Splitting
// every verdict by whether the show still holds contacts showed the contradiction confined to exactly the
// rows a contact could have been deleted from: 1 of 5 `contact_form_only`, 0 of 29 `email_found`. The 16
// empty `no_email_found` rows are correct, since nothing was found and there was never a contact to
// delete.
//
// Dan's call, 2026-08-13, choosing between clearing the verdict on delete and this: the badge stops
// reading the stored verdict as the last word and reports what the show actually HOLDS. One rule, no paid
// re-check to recover something he chose to remove, and it settles every future disagreement rather than
// this one row. The stored verdict is kept untouched as history (L5: the record of what the check
// concluded is not destroyed to fix what the card says about it).
@MainActor
@Suite("A verdict may not outlive the contacts that justified it (#2664)")
struct HeldReachabilityVerdictTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, group: String = "54 Sings Shuffle Along") -> Prospect {
        let p = Prospect(naturalKey: "k-\(group)", groupName: group, discipline: "theater",
                         venue: "54 Below", performanceDate: "2026-08-17", sourceListingURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "neutral", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func formContact(_ url: String) -> Recipient {
        let r = Recipient(id: url, email: nil, name: "Corin Hale", provenance: .act)
        r.contactFormURL = url
        r.contactMethodRaw = "form_or_dm"
        return r
    }

    private func emailContact(_ address: String) -> Recipient {
        Recipient(id: address, email: address, name: "Corin Hale", provenance: .act)
    }

    // The live row, reconstructed: a check concludes form-only, then Dan deletes the contact carrying the
    // form. The badge must stop offering a form that is not there.
    @Test func aHandDeletedContactStopsTheBadgePromisingAForm() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.reachabilityProbedAt = Date()
        p.setRecipients([formContact("https://corinhale.example/contact")])
        p.reachabilityResult = .contactFormOnly
        #expect(QueueItem(p).reachabilityBadge() == .contactFormOnly)

        p.setRecipients([])

        #expect(p.reachabilityResultAsHeld == .noEmailFound)
        #expect(QueueItem(p).reachabilityBadge() == .noEmailFound)
    }

    // The same defect on the loudest badge in the app: an emptied show must not keep claiming an address.
    @Test func anEmptiedShowStopsClaimingAnAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, group: "Broadway Sessions")
        p.reachabilityProbedAt = Date()
        p.setRecipients([emailContact("hello@example.com")])
        p.reachabilityResult = .emailFound
        #expect(QueueItem(p).reachabilityBadge() == .emailFound)

        p.setRecipients([])

        #expect(QueueItem(p).reachabilityBadge() == .noEmailFound)
    }

    // What the check concluded is history and survives, because the delete is not allowed to destroy the
    // record of the paid work (L5). Only the badge's reading of it changes.
    @Test func theStoredVerdictIsKeptAsHistory() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.reachabilityProbedAt = Date()
        p.setRecipients([formContact("https://corinhale.example/contact")])
        p.reachabilityResult = .contactFormOnly

        p.setRecipients([])

        #expect(p.reachabilityResultRaw == "contact_form_only")
    }

    // The regression this fix could most easily cause, and the reason the rule is not simply "always read
    // the recipients": a show NO CHECK HAS TOUCHED holds no contacts either, and deriving from that alone
    // would stamp "No email found" on every unchecked show in the queue. Never checked and checked-and-
    // empty are different screens (L10), and only the check can tell them apart.
    @Test func aShowNoCheckHasTouchedIsStillUnchecked() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, group: "Nobody Has Looked At This One")

        #expect(p.reachabilityResultAsHeld == nil)
        #expect(QueueItem(p).reachabilityBadge() != .noEmailFound)
    }

    // A show whose pitch has gone out has no PENDING contacts left, so what it "holds" can no longer be
    // read off them: every sent show would read as empty. The verdict it was sent under is what stands.
    // The badge is already silent on a sent show, so this guards the property for any later reader rather
    // than the card, which is the point of settling it inside the rule instead of at the call site (L62).
    @Test func aSentShowKeepsTheVerdictItWasSentUnder() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, group: "Already Pitched")
        p.reachabilityProbedAt = Date()
        let contact = emailContact("hello@example.com")
        p.setRecipients([contact])
        p.reachabilityResult = .emailFound
        contact.sendState = .sent
        p.sentAt = Date()

        #expect(p.reachabilityResultAsHeld == .emailFound)
    }

    // A show that still holds what the check found is untouched: the rule only ever speaks where the two
    // disagree, so an ordinary row reads exactly as it did.
    @Test func aShowThatStillHoldsWhatWasFoundIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, group: "Nothing Was Deleted Here")
        p.reachabilityProbedAt = Date()
        p.setRecipients([formContact("https://corinhale.example/contact")])
        p.reachabilityResult = .contactFormOnly

        #expect(p.reachabilityResultAsHeld == .contactFormOnly)
        #expect(QueueItem(p).reachabilityBadge() == .contactFormOnly)
    }

    // The SCORE deliberately does NOT follow the badge here. Dan's call, 2026-08-13, on being shown that
    // #2664 had extended his decision further than he made it: he chose what the BADGE says, and ranking
    // stays tied to what the paid check concluded rather than to what is left on the row.
    //
    // So the two do say different things about an emptied show, and that is the intended reading rather
    // than an oversight: the badge answers "can I reach this show right now", which a hand delete really
    // does change, and the score answers "what did the research find", which a hand delete does not. The
    // score moves when a re-check moves it.
    //
    // Measured before reverting: one show on the live store is in this state, the row that prompted #2664,
    // so the practical difference between the two readings is a single card's ranking.
    @Test func anEmptiedShowStillScoresOnWhatTheCheckConcluded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, group: "Scored On A Contact That Is Gone")
        let now = Date()
        p.reachabilityProbedAt = now
        p.setRecipients([emailContact("hello@example.com")])
        p.reachabilityResult = .emailFound
        #expect(p.contactRouteForScoring(now: now) == .emailFound)

        p.setRecipients([])

        // The badge moves...
        #expect(QueueItem(p).reachabilityBadge(now: now) == .noEmailFound)
        // ...and the score does not.
        #expect(p.contactRouteForScoring(now: now) == .emailFound)
    }

    // And the same two boundaries hold for the score, so a show nobody has checked is not scored as one a
    // check came back empty on.
    @Test func anUncheckedShowStillScoresAsUnchecked() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, group: "Unchecked And Unscored")

        #expect(p.contactRouteForScoring(now: Date()) == .unchecked)
    }

    // The invariant on Dan's real data, which is where the defect was found. Deliberately scoped to the
    // shows whose badge is actually SHOWN (a sent or booked show renders none), and phrased as the thing
    // the fix makes structurally true: a badge naming a route is backed by a contact carrying one.
    //
    // Worth stating plainly, because the last live-store assertion in this area had to be narrowed after a
    // hand edit of Dan's turned it red and blocked every merge: this one cannot be broken by a hand edit,
    // and that is exactly what the fix buys. Deleting a contact moves the badge instead of contradicting
    // it. Its value as a guard is against a later change reintroducing a stored-verdict read on any of the
    // badge's other paths (inherited, org fallback), which are not derived and are not covered above.
    @Test func noShowOnTheLiveStoreShowsARouteItCannotBack() throws {
        let fm = FileManager.default
        let live = StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        guard fm.fileExists(atPath: live.path) else { return }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("held-verdict-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }
        guard let copy = try LiveStoreClone.makeClone(in: tmpDir) else { return }

        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let onTheCard = prospects.filter { $0.sentAt == nil && !$0.isBooked }

        for p in onTheCard {
            let badge = QueueItem(p).reachabilityBadge()
            if badge == .contactFormOnly {
                #expect(!QueueItem(p).displayedContactForms.isEmpty,
                        "\(p.groupName) shows a contact-form badge with no form to open")
            }
            if badge == .emailFound {
                #expect(!QueueItem(p).displayedContactEmails.isEmpty,
                        "\(p.groupName) shows an email badge with no address to write to")
            }
        }
    }
}
