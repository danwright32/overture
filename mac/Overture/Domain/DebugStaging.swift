import Foundation
import SwiftData

// #196: a DEBUG-only test affordance. Booking detection, follow-ups, conversation reminders,
// and reply handling all key off a prospect being contacted (sentAt set), but the only
// production path to that is a live Gmail send. This stages a prospect as if its email had
// already gone out, so those post-send flows can be exercised without sending real mail or
// hand-editing the SwiftData store. Wrapped in #if DEBUG so it is compiled out of release
// builds entirely and can never fake data in normal use.
#if DEBUG
enum DebugStaging {
    // Mark a prospect as an approved-and-sent lead. sentAt + the .approved status are exactly
    // what wasContacted reads, and priorRelationshipAtSend is snapshotted just as SendService
    // does (#66) so booking detection sees a genuine pre-send relationship. A real prospect
    // already carries its own recipients (from PrepImporter, #654); any still-pending one is
    // marked sent too, mirroring SendService.deliver, so per-recipient downstream flows
    // (follow-ups, reminders, reply handling) have something to act on.
    //
    // #378: ReachedOutQueue now requires a Gmail message id as proof of a real send, so each
    // staged recipient gets a synthetic one (a "debug-" id no real Gmail response could produce)
    // to keep showing up in the Reached-out queue for testing, without it being mistakable for
    // a genuine send.
    //
    // #963: the same proof requirement now applies at the PROSPECT level too (outreach stats,
    // booking auto-detection), mirroring SendService.deliver's lead-level rollup, so a staged
    // prospect still counts as contacted for those flows in a Debug build.
    static func stageAsSent(_ prospect: Prospect, now: Date) {
        prospect.sentAt = now
        prospect.status = .approved
        prospect.priorRelationshipAtSend = prospect.priorRelationship
        prospect.freezeFeaturesAtSend()
        prospect.sendError = nil
        prospect.gmailMessageId = "debug-\(prospect.naturalKey)-\(Int(now.timeIntervalSince1970))"
        for r in prospect.recipients where r.sendState == .pending {
            r.sendState = .sent
            r.sentAt = now
            r.gmailMessageId = "debug-\(r.id)-\(Int(now.timeIntervalSince1970))"
        }
    }

    // Insert a fresh lead already eligible for the OmniFocus sync (#231): contacted, replied, with a
    // confirmed (manual) "verbal yes" set now, so its next reminder is ~7 days out (inside the
    // horizon). Used to verify a task actually gets created end to end, regardless of live data.
    @discardableResult
    static func stageReminderDueLead(in context: ModelContext, now: Date) -> Prospect {
        let key = "debug-of-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Test Choir (debug)", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.sentAt = now.addingTimeInterval(-86_400)
        // #963: mirrors stageAsSent's prospect-level synthetic id, so this staged lead also counts
        // as contacted for outreach stats/booking auto-detection, not just the reminder flow it targets.
        p.gmailMessageId = "debug-\(key)-\(Int(now.timeIntervalSince1970))"
        p.outcome = .replied
        // #654: the conversation state Dan confirms lives on the recipient now, not the lead.
        let recipient = Recipient(id: "reminder@debug.example", email: "reminder@debug.example",
                                  name: "Test Contact (debug)", provenance: .act)
        recipient.sendState = .sent
        recipient.sentAt = p.sentAt
        recipient.gmailMessageId = "debug-\(recipient.id)-\(Int(now.timeIntervalSince1970))"
        recipient.replied = true
        p.setRecipients([recipient])
        context.insert(p)
        return p
    }

    // #325: stage a self-addressed lead so the real approve -> send -> success path can be verified
    // end to end without risking a real email to a prospect. It goes to `address` (Dan's own inbox by
    // default). Left `.drafted` (not pre-approved) so Dan exercises the real approve + send clicks; its
    // performance date is inside the bookable window so it shows in the queue; keyed under the
    // "debug-of-" prefix so clearDebugLeads removes it.
    static let defaultSelfSendAddress = SendIdentity.danWright.email

    // #432: resolve the self-send test address from an optional override (the `selfSendTestAddress`
    // user default), falling back to Dan's primary inbox when it is absent or blank. Pure so the
    // precedence is unit-tested without driving the Debug menu.
    static func resolvedSelfSendAddress(override: String?) -> String {
        guard let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return defaultSelfSendAddress }
        return trimmed
    }

    @discardableResult
    static func stageSelfSendLead(in context: ModelContext, now: Date,
                                  address: String = defaultSelfSendAddress) -> Prospect {
        let key = "debug-of-selfsend-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Self-send Test (debug)", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug self-send", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        p.draftSubject = "Overture self-send test"
        p.draftBody = "This is a self-send test from Overture. If you received it, the send path works."
        let recipient = Recipient(id: Recipient.makeId(email: address, formURL: nil) ?? address,
                                  email: address, name: "Dan (test)", provenance: .act)
        p.setRecipients([recipient])
        context.insert(p)
        return p
    }

    // #425: like stageSelfSendLead but with TWO recipients (an act and a presenter) instead of one, so
    // a real approve -> send -> send sequence can prove the per-recipient fan-out (#415) sends two
    // separate emails, each to its own address and greeting its own name, on their own Gmail threads.
    // Both addresses derive from Dan's own inbox via a +tag so a live send still reaches him, but the
    // two recipients keep distinct ids (Recipient.id is the canonicalized email) within this one lead.
    @discardableResult
    static func stageMultiRecipientSelfSendLead(in context: ModelContext, now: Date,
                                                address: String = defaultSelfSendAddress) -> Prospect {
        let key = "debug-of-selfsend-multi-\(Int(now.timeIntervalSince1970))"
        let actEmail = plusTaggedAddress(address, tag: "act")
        let presenterEmail = plusTaggedAddress(address, tag: "presenter")

        let p = Prospect(naturalKey: key, groupName: "Self-send Multi Test (debug)", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug multi-recipient self-send",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftSubject = "Overture self-send test"
        p.draftBody = "This is a self-send test from Overture. If you received it, the send path works."

        let act = Recipient(id: Recipient.makeId(email: actEmail, formURL: nil) ?? actEmail, email: actEmail,
                            name: "Dan (test act)", role: "Act", provenance: .act)
        let presenter = Recipient(id: Recipient.makeId(email: presenterEmail, formURL: nil) ?? presenterEmail,
                                  email: presenterEmail, name: "Dan (test presenter)", role: "Presenter",
                                  provenance: .presenter)
        p.setRecipients([act, presenter])
        context.insert(p)
        return p
    }

    // Inserts a +tag before the @ so the same inbox receives a distinguishable address per recipient
    // (e.g. dan+act@x.com), keeping Recipient.id (the canonicalized email) unique per role even though
    // both ultimately land in Dan's one inbox.
    private static func plusTaggedAddress(_ address: String, tag: String) -> String {
        guard let atIndex = address.firstIndex(of: "@") else { return address }
        let local = address[address.startIndex..<atIndex]
        let domain = address[atIndex...]
        return "\(local)+\(tag)\(domain)"
    }

    // #1245: seed the exact states two shipped-but-hard-to-see features need, so Dan can actually LOOK at
    // them in a near-empty Debug store. #1203's styled signature preview needs a draft in Review with a
    // stored Gmail signature; #1219's self double-booking surfaces need two DIFFERENT shows on one date with
    // one already emailed. One action stages all of it and returns the drafted show Dan reviews.
    //
    // The signature is stored into the Debug build's own defaults domain (never Release), and is left in
    // place by clearDebugLeads (harmless in a dev build, and a real Gmail connect overwrites it). Both
    // prospects are keyed under the shared "debug-of-" prefix so clearDebugLeads removes them.
    @discardableResult
    static func stageVisualQAScenario(in context: ModelContext, now: Date,
                                      defaults: UserDefaults = .standard) -> Prospect {
        // A clean HTML signature so #1203's styled preview renders (not the plain-text fallback). Plain
        // ASCII, so it passes GmailSignatureHealth and is actually cached.
        GmailSignatureStore.store(demoSignatureHTML, defaults: defaults)

        let stamp = Int(now.timeIntervalSince1970)
        let date = EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400))

        // The show Dan reviews: a real draft + a reachable recipient, left .drafted so it sits in Review
        // where the signature preview is shown.
        let draftKey = "debug-of-qa-draft-\(stamp)"
        let drafted = Prospect(naturalKey: draftKey, groupName: "Meridian Chorale (debug)",
                               discipline: "choral", venue: "Weill Recital Hall", performanceDate: date,
                               sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                               production: "self", profile: "strong", coverage: "likely_uncovered",
                               fitScore: 7, tier: "high", fitReason: "debug visual-QA draft",
                               matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                               status: .drafted)
        drafted.draftSubject = "Photographs of your Weill Recital Hall concert"
        drafted.draftBody = "Hi Jordan,\n\nI photograph performances around New York and would love to "
            + "document your upcoming concert. If a few sample frames from similar performances would be "
            + "useful, I'm glad to send some over.\n\nNo problem if the timing isn't right."
        let draftEmail = defaultSelfSendAddress
        let recipient = Recipient(id: Recipient.makeId(email: draftEmail, formURL: nil) ?? draftEmail,
                                  email: draftEmail, name: "Jordan Ellis (debug)", provenance: .presenter)
        drafted.setRecipients([recipient])
        context.insert(drafted)

        // A DIFFERENT show at a DIFFERENT venue on the SAME date, already emailed, so the drafted one reads
        // as a self double-booking (#1219). Distinct groupName so it is a genuinely different production.
        let collisionKey = "debug-of-qa-collision-\(stamp)"
        let collision = Prospect(naturalKey: collisionKey, groupName: "Aurora Winds (debug)",
                                 discipline: "music", venue: "Merkin Concert Hall", performanceDate: date,
                                 sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                                 production: "self", profile: "strong", coverage: "likely_uncovered",
                                 fitScore: 7, tier: "high", fitReason: "debug visual-QA collision",
                                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                 status: .drafted)
        let collisionEmail = plusTaggedAddress(defaultSelfSendAddress, tag: "collision")
        let collisionRecipient = Recipient(
            id: Recipient.makeId(email: collisionEmail, formURL: nil) ?? collisionEmail,
            email: collisionEmail, name: "Aurora Winds (debug)", provenance: .act)
        collision.setRecipients([collisionRecipient])
        context.insert(collision)
        stageAsSent(collision, now: now)   // mark it emailed, so its date now holds a committed pitch

        return drafted
    }

    // #1292: a returning-client "warm register" draft sitting in Review, so the #1215 warm tone keyed off a
    // prior relationship can be SEEN in the near-empty dev store. priorRelationship = warm with a named prior
    // client is what unlocks the warm drafting tone (priorRelationshipForDrafting), and a hand-written warm
    // body stands in for the AI draft this seeder cannot run.
    static func stageWarmRegisterDraft(in context: ModelContext, now: Date) -> Prospect {
        let key = "debug-of-warmregister-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings (debug)", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: PriorRelationship.warm.rawValue,
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "debug warm-register returning client",
                         matchedClientName: "Aurora Strings", possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        // copy-inventory:ignore-start  a debug-only stand-in draft body (contact-facing email copy, not app voice)
        p.draftSubject = "Lovely to work together again"
        p.draftBody = "Hi Jordan,\n\nIt was such a pleasure photographing your ensemble last season. I would "
            + "love to be there again for your upcoming concert if the timing works.\n\nHappy to answer any questions."
        // copy-inventory:ignore-end
        let email = "warm@debug.example"
        let recipient = Recipient(id: Recipient.makeId(email: email, formURL: nil) ?? email, email: email,
                                  name: "Jordan Ellis (debug)", provenance: .presenter)
        p.setRecipients([recipient])
        context.insert(p)
        return p
    }

    // #1292: a re-prep-queued draft, so the gold "Re-prep queued" badge (#1143) on the review card can be
    // seen. reprepDraftRequested is the flag isReprepQueued reads. #1940: the show keeps its draft and its
    // status of .drafted, but the queued re-prep now files it under PREP rather than Review, so that is
    // the stage to open to find this row.
    static func stageReprepQueuedDraft(in context: ModelContext, now: Date) -> Prospect {
        let key = "debug-of-reprep-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Meridian Chorale (debug)", discipline: "choral",
                         venue: "Merkin Concert Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug re-prep queued", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        // copy-inventory:ignore-start  a debug-only stand-in draft body (contact-facing email copy, not app voice)
        p.draftSubject = "Photographs of your Merkin Concert Hall performance"
        p.draftBody = "Hi Alex,\n\nI photograph performances around New York and would love to document your "
            + "upcoming concert.\n\nHappy to answer any questions."
        // copy-inventory:ignore-end
        p.reprepDraftRequested = true   // -> isReprepQueued, the "Re-prep queued" badge
        let email = "reprep@debug.example"
        let recipient = Recipient(id: Recipient.makeId(email: email, formURL: nil) ?? email, email: email,
                                  name: "Alex Rivera (debug)", provenance: .presenter)
        p.setRecipients([recipient])
        context.insert(p)
        return p
    }

    // #1292: two still-open shows on ONE date after a reachability probe, so the #1338 "best contact"
    // highlight can be seen picking out the emailable one. Show A has a sendable contact (emailFound ->
    // highlighted); show B has only a venue front-desk address (weakContactOnly -> not highlighted). Both are
    // probed at `now`, so their firm badges show rather than the pre-probe heuristic.
    static func stageReachabilityCompetition(in context: ModelContext, now: Date) -> [Prospect] {
        let stamp = Int(now.timeIntervalSince1970)
        let date = EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400))

        func makeShow(keyTag: String, group: String, venue: String) -> Prospect {
            let p = Prospect(naturalKey: "debug-of-reach-\(keyTag)-\(stamp)", groupName: group,
                             discipline: "music", venue: venue, performanceDate: date,
                             sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong", coverage: "likely_uncovered",
                             fitScore: 7, tier: "high", fitReason: "debug reachability competition",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .new)
            p.reachabilityProbedAt = now
            context.insert(p)
            return p
        }

        // A: a sendable presenter contact -> emailFound -> the #1338 highlight.
        let a = makeShow(keyTag: "a", group: "Aurora Strings (debug)", venue: "Weill Recital Hall")
        let aEmail = "reach-a@debug.example"
        a.setRecipients([Recipient(id: Recipient.makeId(email: aEmail, formURL: nil) ?? aEmail, email: aEmail,
                                   name: "Jordan Ellis (debug)", provenance: .presenter)])

        // B: only a venue front-desk address -> weakContactOnly -> NOT highlighted.
        let b = makeShow(keyTag: "b", group: "Merkin Winds (debug)", venue: "Merkin Concert Hall")
        let bEmail = "frontdesk@debug.example"
        let venueContact = Recipient(id: Recipient.makeId(email: bEmail, formURL: nil) ?? bEmail, email: bEmail,
                                     name: "Box office (debug)", provenance: .act)
        venueContact.looksLikeVenue = true
        b.setRecipients([venueContact])

        // #1596 Phase 3: stage the stored RESULT too, not just the timestamp. The badge reads the stored
        // answer now, so a staged row carrying a probe date and no result would render as never checked,
        // and Debug is the only build anyone walks the UI in. Derived the same way the real writers derive
        // it, so the staged rows cannot show a state the guards would never produce.
        a.reachabilityResult = a.reachabilityResultFromRecipients
        b.reachabilityResult = b.reachabilityResultFromRecipients

        // #1598 Phase 5: a third show, by an organisation that has ALREADY been checked on another show,
        // so the inherited state can be walked without a real check and without spending anything. C is
        // never probed itself; it must come up wearing "Email found" with the organisation's address
        // under it, and the Check control must not offer to research it.
        //
        // Two shows at two different venues, because one show at one venue is a single-room presenter and
        // the producer gate would refuse it, exactly as it refuses The Green Room 42.
        let orgName = "Meridian Vocal Consort (debug)"
        let c = makeShow(keyTag: "c", group: "Vespers (debug)", venue: "Church of the Ascension")
        let d = makeShow(keyTag: "d", group: "Compline (debug)", venue: "House of the Redeemer")
        for show in [c, d] {
            show.presenter = orgName
            // Never checked itself: the whole point is that the answer arrives from the organisation.
            show.reachabilityProbedAt = nil
            show.reachabilityResult = nil
        }
        let orgEmail = "hello@meridian.example"
        if let orgKey = OrgKey.stored(for: orgName) {
            context.insert(OrgReachabilityAnswer(orgKey: orgKey, result: .emailFound,
                                                 probedAt: now.addingTimeInterval(-10 * 86_400),
                                                 sourceNaturalKey: "debug-of-reach-paid-\(stamp)",
                                                 sourceGroupName: "Matins (debug)",
                                                 presenterName: orgName, foundEmails: [orgEmail]))
        }

        return [a, b, c, d]
    }

    // #1630: the two ends of the form-pitch control, so both can be walked without submitting anything to
    // a real act's contact form. One show sits in Review offering "Copy pitch and open form"; the other is
    // already recorded and past its decide gap, so it appears in Reached out saying what it says.
    @discardableResult
    static func stageFormPitchScenario(in context: ModelContext, now: Date) -> [Prospect] {
        let stamp = Int(now.timeIntervalSince1970)
        let date = EasternDate.dayString(from: now.addingTimeInterval(25 * 86_400))

        func formOnlyShow(keyTag: String, group: String, venue: String, formURL: String) -> Prospect {
            let p = Prospect(naturalKey: "debug-of-formpitch-\(keyTag)-\(stamp)", groupName: group,
                             discipline: "music", venue: venue, performanceDate: date,
                             sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong", coverage: "likely_uncovered",
                             fitScore: 7, tier: "high", fitReason: "debug form pitch",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .drafted)
            p.draftSubject = "Photographs of your \(venue) show"
            p.draftBody = "I photograph performances around New York and would love to document this one. "
                + "If a few sample frames from similar performances would be useful, I'm glad to send some."
            p.reachabilityProbedAt = now
            context.insert(p)
            let r = Recipient(id: Recipient.makeId(email: nil, formURL: formURL) ?? formURL, email: nil,
                              name: "Jamie Rowe (debug)", provenance: .act,
                              contactMethodRaw: ContactMethod.formOrDM.rawValue, contactFormURL: formURL)
            p.setRecipients([r])
            p.reachabilityResult = p.reachabilityResultFromRecipients
            return p
        }

        // A: untouched, sitting in Review with the control on offer. The form is a real page that is safe
        // to open and belongs to nobody Dan would ever pitch.
        let a = formOnlyShow(keyTag: "a", group: "Kestrel Quartet (debug)", venue: "Jalopy Theatre",
                             formURL: "https://example.com/contact")

        // B: recorded a fortnight ago, so it is in Reached out and already past its decide gap.
        let b = formOnlyShow(keyTag: "b", group: "Foxglove Trio (debug)", venue: "Barbes",
                             formURL: "https://example.org/contact")
        let recordedAt = now.addingTimeInterval(-14 * 86_400)
        b.recordFormOutreach(b.recipients[0], now: recordedAt, formURL: "https://example.org/contact")

        return [a, b]
    }

    // A plain-ASCII HTML signature in Dan's brand colors, clean enough to pass GmailSignatureHealth so it
    // is actually cached and the #1203 styled preview has something to render.
    static let demoSignatureHTML =
        "<div style=\"font-family:Georgia,serif;color:#2f4f2f\">"
        + "<strong>Dan Wright</strong><br>Documentary Performing Arts Photography<br>"
        + "<a href=\"https://danwrightphotography.com\">danwrightphotography.com</a></div>"

    // Remove every debug-staged lead (naturalKey prefix "debug-of-"). After this, a sync completes
    // their now-orphaned OmniFocus tasks (they leave the desired set). Cleans up after testing.
    static func clearDebugLeads(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all where p.naturalKey.hasPrefix("debug-of-") { context.delete(p) }
        // #1598: and the organisation answer staged alongside them. Clearing the shows but leaving the
        // ledger row would leave a debug organisation quietly answering for real shows forever.
        let answers = (try? context.fetch(FetchDescriptor<OrgReachabilityAnswer>())) ?? []
        for a in answers where a.sourceNaturalKey.hasPrefix("debug-of-") { context.delete(a) }
    }
}
#endif
