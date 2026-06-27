import Foundation
import SwiftData

// Writes the voice-learning handoff (#241 / #119) from the local store: the high-signal edit pairs
// the Prep drafter workflow learns from (#242). Called when a Prep run launches so the file is fresh
// for that run. Best-effort: a failure to write it must never block the Prep run itself.

@MainActor
enum VoiceFeedbackService {
    @discardableResult
    static func export(from context: ModelContext, generatedAt: String,
                       url: URL = VoiceFeedbackBuilder.defaultURL) throws -> Int {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let feedback = VoiceFeedbackBuilder.build(from: all, generatedAt: generatedAt)
        let data = try VoiceFeedbackBuilder.encode(feedback)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return feedback.pairs.count
    }
}
