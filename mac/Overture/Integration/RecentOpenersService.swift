import Foundation
import SwiftData

// Writes the cross-run anti-repetition handoff (#730) from the local store: the opening sentences
// recent drafts already used, so the next Prep run can steer away from them (docs/prep-runbook.md
// §2). Called when a Prep run launches so the file is fresh for that run. Best-effort: a failure to
// write it must never block the Prep run itself (mirrors VoiceFeedbackService).

@MainActor
enum RecentOpenersService {
    @discardableResult
    static func export(from context: ModelContext, generatedAt: String,
                       url: URL = RecentOpenersBuilder.defaultURL) throws -> Int {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let recent = RecentOpenersBuilder.build(from: all, generatedAt: generatedAt)
        let data = try RecentOpenersBuilder.encode(recent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return recent.openers.count
    }
}
