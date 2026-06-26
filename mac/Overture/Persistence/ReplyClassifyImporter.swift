import Foundation
import SwiftData

// Ingests the classify workflow's results (#112): matches each result to a kept prospect by natural
// key and SUGGESTS the conversation state (auto source), which surfaces immediately in Due for Dan
// to confirm or correct. Never overwrites a state Dan set by hand (#60). Results that match no
// prospect, or carry an unknown intent, are surfaced (never silently swallowed). Mirrors PrepImporter.
enum ReplyClassifyImporter {
    struct Outcome: Equatable, Sendable {
        var matched = 0
        var suggested = 0
        var skippedManual = 0          // matched but Dan had set the state by hand
        var unmatchedKeys: [String] = []
    }

    @MainActor
    @discardableResult
    static func ingest(_ results: ReplyClassifyResults, into context: ModelContext) -> Outcome {
        var outcome = Outcome()
        for r in results.results {
            let key = r.naturalKey
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            guard let p = (try? context.fetch(descriptor))?.first else {
                outcome.unmatchedKeys.append(key)
                continue
            }
            outcome.matched += 1
            if p.conversationStateSource == .manual {
                outcome.skippedManual += 1
                continue
            }
            guard let state = r.replyIntent?.conversationState else { continue }   // unknown intent: skip
            p.suggestConversationState(state, now: Date())
            outcome.suggested += 1
        }
        try? context.save()
        return outcome
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext) throws -> Outcome {
        let data = try Data(contentsOf: url)
        return ingest(try ReplyClassifyResultsDecoder.decode(data), into: context)
    }

    static var defaultURL: URL { ReplyClassifyResultsDecoder.defaultURL }
}
