import Foundation

// #3884: the scout's per event classify and match pass, as a pure function that can run OFF the main
// actor.
//
// WHY IT IS ITS OWN TYPE. It was the first half of `ScoutService.apply`, which is `@MainActor` and
// synchronous, so one source's whole match pass was one uninterrupted block of main thread work with the
// window unable to draw. Measured on the installed Release build over the 127 second scout window of
// 2026-09-13 22:25:05 EDT: the freeze log recorded 97.4 seconds of main thread stall inside it, 77% of
// the window, and only 12.5% of that was inside a counted render pass. A macOS CPU resource report over
// the same window independently put 16 of its 22 microstackshot samples under `ScoutService.apply`, 15 of
// those inside `HistoryMatch.matchRelationship`. Two instruments, one from elapsed time and one from
// sampling, landing within 8% of each other.
//
// NOTHING HERE TOUCHES THE STORE, and that is the whole property that lets it move. Every input is a
// value and every one was already `Sendable` before this existed (`ExtractedEvent`, `DownbeatClient`,
// `HistoryRecord`, `ProducerGate.VenueBrands`, and the `AssembledProspect` it produces), which #3884
// listed as the thing to confirm before relying on it. The `ModelContext` reads that FEED it, the whole
// table fetch that builds `VenueBrands` and the producer overrides beside it, stay on the main actor in
// `apply`, above the call to this.
//
// ONE IMPLEMENTATION, TWO CALLERS. `apply` calls it inline when nobody has classified for it, so every
// existing caller is unchanged and still correct; the scout awaits it off the actor and hands the result
// in. A second copy of this loop is how the two would come to disagree about what a skip means (L263).
enum ScoutClassify {

    // What one pass produced. A value, so it can cross back.
    //
    // The two counts are kept APART rather than summed, because they are already kept apart downstream:
    // `skipped` is every decision not to pursue, and `suppressedOrgs` is only the ones where somebody
    // asked Dan to stop, which is the single line he is shown. A report whose lines do not all mean the
    // same thing is one that has to be read carefully, which means it will not be read at all.
    struct Result: Equatable, Sendable {
        var prospects: [AssembledProspect]
        var skipped: Int
        var suppressedOrgs: [String]
    }

    // The loop, moved rather than rewritten: the order of the calls, the stamping of `sourceIds` and the
    // rule about which skip is reported are exactly what `ScoutService.apply` did.
    static func run(events: [ExtractedEvent],
                    clients: [DownbeatClient],
                    history: [HistoryRecord],
                    venueBrands: ProducerGate.VenueBrands,
                    sourceIds: [String]) -> Result {
        var prospects: [AssembledProspect] = []
        var skipped = 0
        var suppressedOrgs: [String] = []
        for e in events {
            let c = EventClassifier.classify(e)
            // #384: the venue is what aims a "don't want to shoot this" pass at ONE show rather than
            // at the whole org.
            let verdict = HistoryMatch.matchRelationship(name: e.title, presenter: e.presenter,
                                                         venue: e.venue,
                                                         clients: clients, history: history,
                                                         venueBrands: venueBrands)
            switch ProspectAssembler.decide(event: e, classification: c, verdict: verdict) {
            case .skip(let reason):
                skipped += 1
                // Only a REFUSAL is reported. The other skip (unreachable) means something entirely
                // different; a report where the lines do not all mean "somebody asked you to stop" is a
                // report that has to be read carefully, which means it will not be read at all.
                //
                // #901: a blocked date is no longer a skip of any kind. It is imported and flagged, so it
                // cannot reach this report by any route.
                if reason == .suppressed {
                    suppressedOrgs.append(Prospect.decodeHTMLEntities(e.title))
                }
            case .prospect(var p):
                p.sourceIds = sourceIds        // #771: stamped here; `decide` stays pure and clockless
                prospects.append(p)
            }
        }
        return Result(prospects: prospects, skipped: skipped, suppressedOrgs: suppressedOrgs)
    }

    // The same pass, run OFF whatever actor called it.
    //
    // `Task.detached` rather than a plain `Task`, and that is the point of the whole change: a plain
    // `Task` started from a `@MainActor` function INHERITS the main actor and would run this exactly
    // where it runs today, while reading as though it had moved (L3). Detached inherits nothing.
    static func offTheCallersActor(events: [ExtractedEvent],
                                   clients: [DownbeatClient],
                                   history: [HistoryRecord],
                                   venueBrands: ProducerGate.VenueBrands,
                                   sourceIds: [String]) async -> Result {
        await Task.detached(priority: .userInitiated) {
            run(events: events, clients: clients, history: history,
                venueBrands: venueBrands, sourceIds: sourceIds)
        }.value
    }
}
