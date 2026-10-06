import Foundation
import SwiftData

// #4338 (A10, the L371 decision on #4332 and #4334): "Discard these unsaved edits", the way out of an entry
// flush that keeps being refused.
//
// Every landing saves whatever is pending before it applies anything, and refuses when that save fails, so an
// edit the store will not take holds every scout result back. Saving again is one way out; giving the edit up
// is the other. Giving it up is A5's revert (`LandingRevert`), which restores each row's COMMITTED values and
// takes back rows never saved, never `rollback()` (banned: it leaves instances already fetched holding the
// discarded values, L443). Then it saves, which is what tells the store is taking saves again.
//
// The confirmation names exactly what that changes (L180), derived from the pending edits at the moment Dan
// asks, through the revert's own comparison (`LandingRevert.differences`): each row and the fields that go
// back, each never saved row that goes, and each removed row the revert cannot bring back, which therefore
// stays removed.
@MainActor
enum UnsavedEditsDiscard {
    struct Row: Equatable, Sendable {
        var name: String
        // The fields that go back to their saved values. Empty when they could not be told apart.
        var fields: [String]
    }

    struct Preview: Equatable, Sendable {
        var changed: [Row] = []
        // Rows never saved, which are taken out.
        var removed: [String] = []
        // Saved rows the edits removed, which cannot be brought back, so they stay removed.
        var staysRemoved: [String] = []

        var isEmpty: Bool { changed.isEmpty && removed.isEmpty && staysRemoved.isEmpty }
    }

    static func preview(in context: ModelContext) -> Preview {
        var preview = Preview()
        for difference in LandingRevert.differences(.pending(in: context), in: context) {
            let name = ScoutService.rowName(of: difference.model)
            switch difference.kind {
            case .changed(let fields): preview.changed.append(Row(name: name, fields: fields))
            case .inserted: preview.removed.append(name)
            case .deleted: preview.staysRemoved.append(name)
            }
        }
        return preview
    }

    // How many changed rows are named one by one before the rest are counted, so a long list of edits still
    // fits a confirmation Dan can read.
    static let namedRows = 6

    // What discarding changes, in Dan's words, from what is pending now.
    static func consequence(_ preview: Preview) -> String {
        guard !preview.isEmpty else { return "Nothing is waiting to be saved, so nothing changes." }
        var parts: [String] = []
        for row in preview.changed.prefix(namedRows) {
            parts.append(row.fields.isEmpty
                ? "\(row.name) goes back to how it was last saved."
                : "\(row.name) goes back to its saved \(Plural.list(row.fields)).")
        }
        let more = preview.changed.count - namedRows
        if more > 0 {
            parts.append(more == 1 ? "One more record goes back to how it was last saved."
                                   : "\(more) more records go back to how they were last saved.")
        }
        if !preview.removed.isEmpty {
            parts.append(preview.removed.count == 1
                ? "\(preview.removed[0]), which was never saved, is removed."
                : "\(Plural.list(preview.removed)), which were never saved, are removed.")
        }
        if !preview.staysRemoved.isEmpty {
            parts.append(preview.staysRemoved.count == 1
                ? "Overture can't bring back \(preview.staysRemoved[0]), which you removed, so it stays removed."
                : "Overture can't bring back \(Plural.list(preview.staysRemoved)), which you removed, so they stay removed.")
        }
        parts.append("Nothing else changes.")
        return parts.joined(separator: " ")
    }

    // Puts every pending edit back to its saved value, then saves. A save that still fails says the store
    // itself is refusing saves, since nothing of Dan's is pending any more; the standing state stays, because
    // nothing can land until a save goes through.
    static func perform(in context: ModelContext, save: (ModelContext) throws -> Void = { try $0.save() },
                        record: EntryFlushRecord = .shared) -> LandingOutcome {
        _ = LandingRevert.revert(.pending(in: context), in: context)
        do {
            try save(context)
        } catch {
            return .editsDiscardedButStillNotSaving(why: HandoffDecodeFailure.describe(error))
        }
        record.saveSucceeded()
        return .editsDiscarded
    }

    // "Try saving again": the same save, said either way. A failure is recorded beside the standing state, so the
    // line says it was tried and failed rather than reading as if nothing happened (L44).
    static func trySavingAgain(in context: ModelContext, now: Date,
                               save: (ModelContext) throws -> Void = { try $0.save() },
                               record: EntryFlushRecord = .shared) -> LandingOutcome? {
        do {
            try save(context)
        } catch {
            record.tryFailed(at: now, rows: ScoutService.pendingRowNames(in: context))
            return nil
        }
        record.saveSucceeded()
        return .editsSaved
    }
}
