import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The model only T2 and T3 terms as they stood on
// origin/main 47fc6114, copied verbatim, run against the new generic terms over ONE frozen snapshot of the
// live clone and its fourfold copy, both arms over the same fetched rows. Its output is pasted into the PR,
// and then this file is deleted in the same PR (L613): nothing old is retained, so nothing drifts.
@MainActor
@Suite("Oracle part one for T2 and T3: the model only terms against the generic ones (#4357, temporary)")
final class OldAgainstNewContradictionTermsTests {
    private let sandboxes = TemporarySandboxes()

    // MARK: the old terms, verbatim from 47fc6114 bar three things: their names, the tally call, and
    // `disappearedFromFeed` written out as its own one line definition (Prospect.swift:1157 on 47fc6114),
    // because this PR moves that member onto the protocol both arms would otherwise share.

    enum ModelOnlyContradictedCancellation {
        static func liveTwin(of flagged: Prospect, among rows: [Prospect]) -> Prospect? {
            guard flagged.missedScoutCount >= FeedReconcile.goneThreshold else { return nil }
            return rows.first { candidate in
                guard candidate.persistentModelID != flagged.persistentModelID else { return false }
                guard candidate.missedScoutCount == 0 else { return false }
                guard sameVenue(candidate.venue, flagged.venue) else { return false }
                guard ScoutService.runsOverlap(storedStart: candidate.performanceDate,
                                               storedEnd: candidate.runEndDate,
                                               incomingStart: flagged.performanceDate,
                                               incomingEnd: flagged.runEndDate) else { return false }
                return GroupNameMatch.isSameShowTitle(candidate.groupName, flagged.groupName)
            }
        }

        static func contradictedKeys(among rows: [Prospect]) -> Set<String> {
            var liveByVenue: [String: [Prospect]] = [:]
            for row in rows where row.missedScoutCount == 0 {
                liveByVenue[canonicalVenue(row.venue), default: []].append(row)
            }
            guard !liveByVenue.isEmpty else { return [] }
            var contradicted: Set<String> = []
            for flagged in rows where flagged.missedScoutCount >= FeedReconcile.goneThreshold {
                let room = liveByVenue[canonicalVenue(flagged.venue)] ?? []
                let twin = room.first { candidate in
                    guard candidate.persistentModelID != flagged.persistentModelID else { return false }
                    guard ScoutService.runsOverlap(storedStart: candidate.performanceDate,
                                                   storedEnd: candidate.runEndDate,
                                                   incomingStart: flagged.performanceDate,
                                                   incomingEnd: flagged.runEndDate) else { return false }
                    return GroupNameMatch.isSameShowTitle(candidate.groupName, flagged.groupName)
                }
                if twin != nil { contradicted.insert(flagged.naturalKey) }
            }
            return contradicted
        }

        private static func sameVenue(_ a: String?, _ b: String?) -> Bool {
            canonicalVenue(a) == canonicalVenue(b)
        }

        static func canonicalVenue(_ raw: String?) -> String {
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
            return VenueNormalization.normalizeForKey(raw)
        }
    }

    enum ModelOnlyFeedBreakEvent {
        static func events(among rows: [Prospect], asOf: String,
                           contradicted: Set<String>? = nil) -> [FeedBreakEvent.Event] {
            let covered = contradicted ?? ModelOnlyContradictedCancellation.contradictedKeys(among: rows)
            let flagged = rows.filter {
                $0.missedScoutCount >= FeedReconcile.goneThreshold
                    && max($0.performanceDate ?? "", $0.runEndDate ?? "") >= asOf
            }
            var buckets: [String: [Prospect]] = [:]
            for row in flagged {
                buckets["\(canonicalVenue(row.venue))|\(row.missedScoutCount)", default: []].append(row)
            }
            return buckets.values
                .filter { $0.count >= FeedBreakEvent.minimumMembers }
                .map { members in
                    FeedBreakEvent.Event(venue: label(of: members),
                                         missedScoutCount: members[0].missedScoutCount,
                                         memberKeys: members.map(\.naturalKey).sorted(),
                                         coveredByAnotherCard: members.filter { covered.contains($0.naturalKey) }.count)
                }
                .sorted { left, right in
                    if left.memberKeys.count != right.memberKeys.count {
                        return left.memberKeys.count > right.memberKeys.count
                    }
                    if left.venue != right.venue { return left.venue < right.venue }
                    return (left.memberKeys.first ?? "") < (right.memberKeys.first ?? "")
                }
        }

        private static func label(of members: [Prospect]) -> String {
            var counts: [String: Int] = [:]
            for member in members { counts[member.venue ?? "", default: 0] += 1 }
            let top = counts.values.max() ?? 0
            return members.sorted { $0.naturalKey < $1.naturalKey }
                .first { counts[$0.venue ?? ""] == top }?.venue ?? ""
        }

        static func canonicalVenue(_ raw: String?) -> String {
            VenueNormalization.normalizeForKey(raw ?? "").lowercased()
        }
    }

    // MARK: the comparison

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericTermsAnswerAsTheModelOnlyOnesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-t2-t3")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let asOf = EasternDate.today(Date())
            for (label, url) in corpora {
                let rows = try ModelContext(try Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                let pidByKey = Dictionary(rows.map { ($0.naturalKey, String(describing: $0.persistentModelID)) },
                                          uniquingKeysWith: { first, _ in first })
                var diff: [String] = []

                let oldSet = ModelOnlyContradictedCancellation.contradictedKeys(among: rows)
                let newSet = ContradictedCancellation.contradictedKeys(among: rows)
                for key in oldSet.symmetricDifference(newSet).sorted() {
                    diff.append("contradictedKeys differs for row \(pidByKey[key] ?? "?")")
                }
                var flagged = 0
                for row in rows where row.missedScoutCount >= FeedReconcile.goneThreshold {
                    flagged += 1
                    if ModelOnlyContradictedCancellation.liveTwin(of: row, among: rows)?.persistentModelID
                        != ContradictedCancellation.liveTwin(of: row, among: rows)?.persistentModelID {
                        diff.append("liveTwin differs for row \(pidByKey[row.naturalKey] ?? "?")")
                    }
                }
                let oldEvents = ModelOnlyFeedBreakEvent.events(among: rows, asOf: asOf, contradicted: oldSet)
                let newEvents = FeedBreakEvent.events(among: rows, asOf: asOf, contradicted: newSet)
                diff += TermsOverFacts.eventFindings(oldEvents, newEvents, term: "events, shared set",
                                                     pid: { pidByKey[$0] ?? "?" })
                diff += TermsOverFacts.eventFindings(ModelOnlyFeedBreakEvent.events(among: rows, asOf: asOf),
                                                     FeedBreakEvent.events(among: rows, asOf: asOf),
                                                     term: "events, own set", pid: { pidByKey[$0] ?? "?" })

                // Decision 5 (generic over models): the generic term over models costs no more than the old.
                let oldT2 = Phase0.median5 { _ = ModelOnlyContradictedCancellation.contradictedKeys(among: rows) }
                let newT2 = Phase0.median5 { _ = ContradictedCancellation.contradictedKeys(among: rows) }
                let oldT3 = Phase0.median5 { _ = ModelOnlyFeedBreakEvent.events(among: rows, asOf: asOf, contradicted: oldSet) }
                let newT3 = Phase0.median5 { _ = FeedBreakEvent.events(among: rows, asOf: asOf, contradicted: newSet) }

                print("old against new, \(label): \(rows.count) row(s), \(flagged) flagged, "
                      + "\(oldSet.count) contradicted, \(oldEvents.count) event(s), \(diff.count) difference(s)")
                print("old against new, \(label): contradictedKeys old \(oldT2.text), new \(newT2.text); "
                      + "events old \(oldT3.text), new \(newT3.text); load \(Phase0.load())")
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
