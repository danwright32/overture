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
        // History the matcher sees = any one-time legacy import + Overture's own activity,
        // so repeat-client recognition stays current as Dan sends and books (#19).
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let history = loadLocalHistory() + LocalHistory.records(from: existing)
        var outcome = apply(events: events, clients: loaded.clients, history: history,
                            blocked: loadBlockedDates(), into: context)
        outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.health)
        // Reconcile bookings from Downbeat: a contacted prospect that's now a Downbeat
        // client gets outcome booked automatically (#41).
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        if DownbeatBooking.reconcileBooked(prospects: all, clients: loaded.clients, now: Date()) > 0 {
            try? context.save()
        }
        // Record that a scout completed, so the masthead can show freshness (#35).
        recordScout(at: Date())
        return outcome
    }

    static let lastScoutKey = "scoutLastRunAt"
    // Store/read injectable so the persistence is testable without polluting the global
    // defaults (test side effects stay in a transient suite).
    static func recordScout(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastScoutKey)
    }
    static func lastScoutedAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastScoutKey) as? Date
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
                } else if let drifted = matchByStableSource(url: p.sourceListingURL, date: p.performanceDate, in: context) {
                    // No exact key match, but the same source listing + date already exists:
                    // the venue tweaked the title between runs. Re-key to the new title and
                    // update in place so Dan's keep/dismiss decision survives (#29).
                    drifted.naturalKey = key
                    apply(p, to: drifted)
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

    // A prospect identified by its stable source listing (URL + date), used to recognize
    // the same event when its display title has drifted (#29). Fetch-all + filter is fine
    // for the local store's size and avoids optional-predicate gymnastics.
    private static func matchByStableSource(url: String?, date: String?, in context: ModelContext) -> Prospect? {
        guard let url, !url.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.first { $0.sourceListingURL == url && $0.performanceDate == date }
    }

    private static func make(_ p: AssembledProspect, key: String) -> Prospect {
        let prospect = Prospect(
            naturalKey: key, groupName: p.groupName, discipline: p.discipline, venue: p.venue,
            performanceDate: p.performanceDate, sourceListingURL: p.sourceListingURL, websiteURL: p.websiteURL,
            priorRelationship: p.priorRelationship, production: p.production, profile: p.profile,
            coverage: p.coverage, fitScore: p.fitScore, tier: p.tier, fitReason: p.fitReason,
            matchedClientName: p.matchedClientName, possibleMatchSource: p.possibleMatchSource,
            possibleMatchName: p.possibleMatchName)
        prospect.classificationConfidence = p.confidence
        return prospect
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
        existing.classificationConfidence = p.confidence  // scout-owned; refreshed each run
        // NOTE: never touch confidenceReviewedByDan here — Dan owns that acknowledgement.
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
