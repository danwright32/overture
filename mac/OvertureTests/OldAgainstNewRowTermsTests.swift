import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The slice G1 terms as they stood at 867c3fd9
// (QueueScopeRow.init(_:facts:inheritedReachability:), RecipientFacts.of(_:contacts:), and the reachability
// members on Prospect and Recipient they read), copied verbatim bar names and comments, run against the
// generic terms through their model entry points over ONE frozen snapshot of the live clone and its
// fourfold copy. Its output is pasted into the PR, and then this file is deleted in the same PR (L613).
@MainActor
@Suite("Oracle part one for slice G1: the model only row terms against the generic ones (#4357, temporary)")
final class OldAgainstNewRowTermsTests {
    private let sandboxes = TemporarySandboxes()

    enum Old {
        static func isUnconfirmedNameMatch(_ r: Recipient) -> Bool { r.nameMatchOnly && !r.nameMatchOnlyDismissed }

        static func isHeldByAGuard(_ r: Recipient) -> Bool {
            r.email?.isEmpty == false
                && ((r.looksLikeVenue && !r.looksLikeVenueDismissed)
                    || (r.looksLikePressContact && !r.looksLikePressContactDismissed)
                    || (r.looksLikeDuplicateContact && !r.looksLikeDuplicateContactDismissed)
                    || r.isLooksLikeAnotherPersons)
        }

        static func hasUnguardedAddress(_ r: Recipient) -> Bool { r.email?.isEmpty == false && !isHeldByAGuard(r) }

        static func socialRouteURLs(_ p: Prospect) -> [String] {
            p.recipients.compactMap { r -> String? in
                guard !isUnconfirmedNameMatch(r),
                      let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty, Reachability.isSocialOnly(raw),
                      !VenueContactGuard.looksLikeVenue(formURL: raw, venue: p.venue),
                      !PressContactGuard.looksLikePressContact(formURL: raw) else { return nil }
                return raw
            }
        }

        static func usableContactFormURLs(_ p: Prospect) -> [String] {
            p.recipients.compactMap { r -> String? in
                guard let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty, !Reachability.isSocialOnly(raw),
                      !VenueContactGuard.looksLikeVenue(formURL: raw, venue: p.venue),
                      !PressContactGuard.looksLikePressContact(formURL: raw),
                      let url = URL(string: raw), url.scheme != nil else { return nil }
                return raw
            }
        }

        static func reachabilityResultFromRecipients(_ p: Prospect) -> Reachability.ProbeResult {
            var unguarded = false
            var guarded = false
            for r in p.recipients {
                if hasUnguardedAddress(r) { unguarded = true; break }
                if isHeldByAGuard(r) { guarded = true }
            }
            if unguarded { return Reachability.result(from: .init(hasUnguardedAddress: true)) }
            if guarded { return Reachability.result(from: .init(hasGuardedAddress: true)) }
            return Reachability.result(from: .init(hasUsableContactForm: !usableContactFormURLs(p).isEmpty,
                                                   hasSocialRoute: !socialRouteURLs(p).isEmpty))
        }

        static func reachabilityResult(_ p: Prospect) -> Reachability.ProbeResult? {
            p.reachabilityResultRaw.flatMap(Reachability.ProbeResult.init(rawValue:))
        }

        static func reachabilityResultAsHeld(_ p: Prospect) -> Reachability.ProbeResult? {
            guard let stored = reachabilityResult(p) else { return nil }
            guard p.sentAt == nil, !p.isBooked else { return stored }
            return reachabilityResultFromRecipients(p)
        }

        static func facts(_ p: Prospect, contacts: [Recipient]) -> RecipientFacts {
            RecipientFacts(standings: contacts.map(\.standing),
                           reachabilityAsHeld: reachabilityResultAsHeld(p),
                           searchableContacts: contacts.map { SearchableContact(name: $0.name, email: $0.email) })
        }

        static func row(_ p: Prospect, facts: RecipientFacts,
                        inheritedReachability: OrgAnswerLedger.Inherited? = nil) -> QueueScopeRow {
            QueueScopeRow(id: p.naturalKey,
                          groupName: p.groupName,
                          discipline: p.discipline,
                          venue: p.venue,
                          presenter: p.presenter,
                          location: p.location,
                          performanceDate: p.performanceDate,
                          runNights: p.runNights,
                          performanceStartTimes: p.performanceStartTimes,
                          nightStartTimes: p.nightStartTimes,
                          startTimesVary: p.startTimesVary,
                          fitScore: p.fitScore,
                          tier: p.tier,
                          status: p.status,
                          sentAt: p.sentAt,
                          outcome: p.outcome,
                          showOutcome: p.showOutcome,
                          bookingSuggested: p.bookingSuggested,
                          hasDraft: p.draftBody != nil,
                          reachabilityProbedAt: p.reachabilityProbedAt,
                          reachabilityUnansweredAt: p.reachabilityUnansweredAt,
                          reachabilityRecheckRequestedAt: p.reachabilityRecheckRequestedAt,
                          reachabilityResult: facts.reachabilityAsHeld,
                          inheritedReachability: inheritedReachability,
                          conflictBlockedDate: p.conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.date,
                          runEndDate: p.runEndDate,
                          performanceStatus: p.showOutcome?.asPerformanceStatus
                              ?? PerformanceStatus.derive(facts.standings, leadBooked: p.outcome == .booked),
                          facts: facts)
        }
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericRowTermsAnswerAsTheModelOnlyOnesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-row-terms")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            for (label, url) in corpora {
                let rows = try ModelContext(try Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                var diff: [String] = []
                var verdicts: [Reachability.ProbeResult: Int] = [:]
                var held = 0, contactsSeen = 0
                for p in rows {
                    let pid = String(describing: p.persistentModelID)
                    let contacts = p.countedRecipients
                    if Old.facts(p, contacts: contacts) != RecipientFacts.of(p, contacts: contacts) {
                        diff.append("RecipientFacts.of(_:contacts:) differs for row \(pid)")
                    }
                    if Old.facts(p, contacts: p.countedRecipients) != RecipientFacts.of(p) {
                        diff.append("RecipientFacts.of(_:) differs for row \(pid)")
                    }
                    let facts = RecipientFacts.of(p, contacts: contacts)
                    if Old.row(p, facts: facts) != QueueScopeRow(p, facts: facts) {
                        diff.append("QueueScopeRow differs for row \(pid)")
                    }
                    let from = Old.reachabilityResultFromRecipients(p)
                    verdicts[from, default: 0] += 1
                    if from != p.reachabilityResultFromRecipients { diff.append("reachabilityResultFromRecipients differs for row \(pid)") }
                    if Old.reachabilityResultAsHeld(p) != p.reachabilityResultAsHeld { diff.append("reachabilityResultAsHeld differs for row \(pid)") }
                    if Old.reachabilityResultAsHeld(p) != nil { held += 1 }
                    if Old.reachabilityResult(p) != p.reachabilityResult { diff.append("reachabilityResult differs for row \(pid)") }
                    if Old.socialRouteURLs(p) != p.socialRouteURLs { diff.append("socialRouteURLs differs for row \(pid)") }
                    if Old.usableContactFormURLs(p) != p.usableContactFormURLs { diff.append("usableContactFormURLs differs for row \(pid)") }
                    for r in p.recipients {
                        contactsSeen += 1
                        if Old.isUnconfirmedNameMatch(r) != r.isUnconfirmedNameMatch
                            || Old.isHeldByAGuard(r) != r.isHeldByAGuard
                            || Old.hasUnguardedAddress(r) != r.hasUnguardedAddress {
                            diff.append("the address members differ for contact \(r.persistentModelID)")
                        }
                    }
                }
                let oldT = Phase0.median5 {
                    for p in rows { let c = p.recipients; _ = Old.row(p, facts: Old.facts(p, contacts: c)) }
                }
                let newT = Phase0.median5 {
                    for p in rows { let c = p.recipients; _ = QueueScopeRow(p, facts: RecipientFacts.of(p, contacts: c)) }
                }
                let spread = Reachability.ProbeResult.allCases.map { "\($0.rawValue) \(verdicts[$0] ?? 0)" }.joined(separator: ", ")
                print("old against new, \(label): \(rows.count) row(s), \(contactsSeen) contact(s), \(held) held verdict(s), "
                      + "derived: \(spread), \(diff.count) difference(s)")
                print("old against new, \(label): rows and their contact facts old \(oldT.text), new \(newT.text); load \(Phase0.load())")
                for line in diff.prefix(20) { print("old against new, \(label): " + line) }
                #expect(diff.isEmpty, Comment(rawValue: diff.prefix(20).joined(separator: "\n")))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
