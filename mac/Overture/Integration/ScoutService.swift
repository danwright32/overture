import Foundation
import SwiftData

// The in-app scout: extract the live calendar (hidden WebKit) -> classify (rules) ->
// match repeat clients -> assemble/rank -> upsert into the local store. Fully native
// and silent; no separate runner, no cloud. Upsert preserves Dan's keep/dismiss.

@MainActor
enum ScoutService {
    struct Outcome: Equatable, Sendable {
        var found: Int
        var inserted: Int
        var updated: Int
        var skipped: Int
        var uncertain: Int
        // Set when the Downbeat past-client export was missing, unreadable, or stale, so
        // warm/repeat matching ran degraded and Dan should be told (#22/#23).
        var clientListWarning: String? = nil

        // The single warning to show after a run, if any. Zero extracted events almost
        // always means the venue page changed or was unreachable, so it takes precedence
        // over a client-list warning (with no events there is nothing to match) (#27).
        var warning: String? {
            if found == 0 {
                return "The scout found no events. The venue calendar may have changed or be temporarily unavailable — try running the scout again shortly."
            }
            return clientListWarning
        }
    }

    static func runScout(into context: ModelContext) async throws -> Outcome {
        let events = try await CarnegieExtractor().extract()
        let loaded = DownbeatBridge.loadWithHealth(now: Date())
        var outcome = apply(events: events, clients: loaded.clients, history: loadLocalHistory(),
                            blocked: loadBlockedDates(), into: context)
        outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.health)
        return outcome
    }

    // Application of already-extracted events with injected data, so the full
    // classify -> match -> assemble -> upsert chain is testable without network/WebKit.
    @discardableResult
    static func apply(
        events: [ExtractedEvent],
        clients: [DownbeatClient],
        history: [HistoryRecord],
        blocked: Set<String>,
        into context: ModelContext
    ) -> Outcome {
        var inserted = 0, updated = 0, skipped = 0, uncertain = 0
        for e in events {
            let c = EventClassifier.classify(e)
            if c.confidence == .uncertain { uncertain += 1 }
            let verdict = HistoryMatch.matchRelationship(name: e.title, clients: clients, history: history)
            switch ProspectAssembler.decide(event: e, classification: c, verdict: verdict, blocked: blocked) {
            case .skip:
                skipped += 1
            case .prospect(let p):
                let key = Prospect.makeNaturalKey(groupName: p.groupName, performanceDate: p.performanceDate, venue: p.venue)
                let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
                if let existing = (try? context.fetch(descriptor))?.first {
                    apply(p, to: existing)
                    updated += 1
                } else {
                    context.insert(make(p, key: key))
                    inserted += 1
                }
            }
        }
        try? context.save()
        return Outcome(found: events.count, inserted: inserted, updated: updated, skipped: skipped, uncertain: uncertain)
    }

    private static func make(_ p: AssembledProspect, key: String) -> Prospect {
        Prospect(
            naturalKey: key, groupName: p.groupName, discipline: p.discipline, venue: p.venue,
            performanceDate: p.performanceDate, sourceListingURL: p.sourceListingURL, websiteURL: p.websiteURL,
            priorRelationship: p.priorRelationship, production: p.production, profile: p.profile,
            coverage: p.coverage, fitScore: p.fitScore, tier: p.tier, fitReason: p.fitReason,
            matchedClientName: p.matchedClientName, possibleMatchSource: p.possibleMatchSource,
            possibleMatchName: p.possibleMatchName)
    }

    // Refresh scout-owned fields; never touch status/dismissReason (Dan owns those).
    private static func apply(_ p: AssembledProspect, to existing: Prospect) {
        existing.groupName = p.groupName
        existing.discipline = p.discipline
        existing.venue = p.venue
        existing.performanceDate = p.performanceDate
        existing.sourceListingURL = p.sourceListingURL
        existing.priorRelationship = p.priorRelationship
        existing.production = p.production
        existing.profile = p.profile
        existing.coverage = p.coverage
        existing.fitScore = p.fitScore
        existing.tier = p.tier
        existing.fitReason = p.fitReason
        existing.matchedClientName = p.matchedClientName
        existing.possibleMatchSource = p.possibleMatchSource
        existing.possibleMatchName = p.possibleMatchName
        existing.ingestedAt = Date()
    }

    // Local booking history the matcher reads (group name + status), produced from
    // Downbeat/Supabase by scripts/export-history.ts. Absent file = no history yet.
    private static func loadLocalHistory() -> [HistoryRecord] {
        let url = appSupport("overture-history.json")
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return [] }
        return history
    }

    private static func loadBlockedDates() -> Set<String> {
        let url = appSupport("overture-blocked-dates.json")
        guard let data = try? Data(contentsOf: url),
              let dates = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(dates)
    }

    private static func appSupport(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent(name)
    }
}
