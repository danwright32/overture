import Foundation
import SwiftData

// #1417: the watchlist actions that SAY something to Dan, moved out of SourcesView and
// SourceFixConfirmActions so each one is a plain function a test can call (#863), and so the rule
// they all now share lives in one place instead of being re-remembered at each button.
//
// The rule: a success banner is posted only after the change is confirmed on disk. WatchlistEditing
// persists with a bare `try? context.save()` that swallows the error, so before this every one of
// these actions congratulated Dan for a write that may never have happened, and the change sat in
// memory looking right until quit. Confirming with saveOrWarn works because a failed save leaves the
// change PENDING (pinned in ModelContextSaveOrWarnTests), so the retry fails the same way and warns;
// on the normal path there is nothing left to write and it costs nothing.
//
// The domain helper still owns WHAT changes. This layer owns only what Dan is told about it.
@MainActor
enum WatchlistMutations {
    // #845: stopping says what it did AND offers the way back, in the same breath. The Undo is the
    // immediate correction (a mis-click Dan sees at once); the "Watch again" button on the row is the one
    // that never expires, because a banner he looked away from is a banner he did not read.
    static func stopWatching(_ source: WatchedSource, context: ModelContext, feedback: ActionFeedback) {
        WatchlistEditing.stopWatching(source, in: context)
        guard context.saveOrWarn(org: source.orgName, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.stoppedWatching(org: source.orgName),
                             action: .init(label: "Undo") {
                                 resumeWatching(source, context: context, feedback: feedback)
                             })
    }

    static func resumeWatching(_ source: WatchedSource, context: ModelContext, feedback: ActionFeedback) {
        // The result is not ignored: a refusal must never pass silently as though it worked. The sheet
        // only draws these controls on a source Dan stopped himself, so this should be unreachable, and
        // "should be unreachable" is exactly the kind of claim that turns into a source quietly back on
        // the watchlist that asked not to be.
        switch WatchlistEditing.resumeWatching(source, in: context) {
        case .resumed, .alreadyWatching:
            guard context.saveOrWarn(org: source.orgName, feedback: feedback) else { return }
            feedback.acknowledge(ActionAck.resumedWatching(org: source.orgName))
        case .refused(let orgName):
            feedback.acknowledge(WatchlistEditing.resumeRefusedMessage(orgName: orgName), tone: .warning)
        case .added, .invalidURL, .needsName:
            break
        }
    }

    static func saveVenueLocation(_ source: WatchedSource, to draft: String,
                                  context: ModelContext, feedback: ActionFeedback) {
        let placed = WatchlistEditing.setVenueLocation(source, to: draft, in: context)
        guard context.saveOrWarn(org: source.orgName, feedback: feedback) else { return }
        feedback.acknowledge(VenueLocationCopy.savedAck(org: source.orgName, placed: placed))
    }

    // #1752: Dan says where a ROOM is, when no table knows. Distinct from saveVenueLocation above, which
    // answers where a SOURCE's shows are: this one reaches every show in that room whichever source
    // published it, and it outlives the shows it was given for.
    static func saveRoomPlace(room: UnplacedRooms.Room, to draft: String,
                              context: ModelContext, feedback: ActionFeedback) {
        let placed = VenuePlaceAnswering.record(venue: room.name, location: draft,
                                                in: context, now: Date())
        guard context.saveOrWarn(org: room.name, feedback: feedback) else { return }
        feedback.acknowledge(UnplacedRoomCopy.savedAck(room: room.name, placed: placed))
    }

    // #1529: Dan names the room a ticketing-feed source's shows play in, which is the one thing standing
    // between those shows and the queue.
    static func saveVenueName(_ source: WatchedSource, to draft: String,
                              context: ModelContext, feedback: ActionFeedback) {
        WatchlistEditing.setVenueName(source, to: draft, in: context)
        guard context.saveOrWarn(org: source.orgName, feedback: feedback) else { return }
        feedback.acknowledge(VenueNameCopy.savedAck(org: source.orgName))
    }

    // What the editor should do next. `.notSaved` is its own case rather than an error message: the
    // save warning is already on the banner, and the editor stays OPEN holding Dan's typed address, so a
    // failure costs him nothing to retry. Closing it on a write that did not land is the exact defect.
    enum FixOutcome: Equatable {
        case saved(sourceId: String)
        case message(String)
        case notSaved
    }

    static func fixURL(_ source: WatchedSource, to draft: String,
                       context: ModelContext, feedback: ActionFeedback) -> FixOutcome {
        switch WatchlistEditing.editURL(source, to: draft, in: context) {
        case .saved(let id):
            guard context.saveOrWarn(org: source.orgName, feedback: feedback) else { return .notSaved }
            feedback.acknowledge(SourceFixConfirmCopy.fixedAck(org: source.orgName))
            return .saved(sourceId: id)
        case .invalidURL:
            return .message(WatchlistEditing.invalidURLMessage)
        case .conflict(let org):
            return .message(SourceFixConfirmCopy.conflictMessage(org: org))
        case .refused(let org):
            return .message(WatchlistEditing.resumeRefusedMessage(orgName: org))
        }
    }

    // Adding says nothing in a banner: the form closing and the row appearing IS the confirmation. That
    // makes it the same defect in a quieter form, because both of those happen off a context that never
    // reached disk. `.notSaved` leaves the form open holding what Dan typed, with the save warning on the
    // banner, rather than closing over a source that will not be there next launch.
    enum AddOutcome: Equatable {
        case added
        case message(String)
        case notSaved
    }

    static func addSource(orgName: String, listingsURL: String,
                          context: ModelContext, feedback: ActionFeedback) -> AddOutcome {
        let named = orgName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch WatchlistEditing.add(orgName: orgName, listingsURL: listingsURL, into: context) {
        case .added, .resumed:
            return context.saveOrWarn(org: named.isEmpty ? listingsURL : named, feedback: feedback)
                ? .added : .notSaved
        case .alreadyWatching(let org):
            return .message(WatchlistEditing.alreadyWatchingMessage(orgName: org))
        case .refused(let org):
            // He must SEE this. Silently declining would look exactly like a bug, and this is the one
            // thing in the whole feature that must not be got wrong quietly. #885: the sentence itself
            // lives with the rule that produces it, and is now written once rather than three times.
            return .message(WatchlistEditing.refusedMessage(orgName: org))
        case .invalidURL:
            return .message(WatchlistEditing.invalidURLMessage)
        case .needsName:
            return .message(WatchlistEditing.needsNameMessage)
        }
    }

    static func confirmEmpty(_ source: WatchedSource, context: ModelContext, feedback: ActionFeedback) {
        let result = WatchlistEditing.confirmEmpty(source, in: context)
        guard context.saveOrWarn(org: source.orgName, feedback: feedback) else { return }
        switch result {
        case .confirmed:
            feedback.acknowledge(SourceFixConfirmCopy.confirmedAck(org: source.orgName))
        case .noHash:
            feedback.acknowledge(SourceFixConfirmCopy.confirmedNoHashAck(org: source.orgName), tone: .warning)
        // #2530: the same sentence the other refusal routes speak, so a row that asked not to be
        // contacted reads identically whichever control was pressed on it.
        case .refused(let orgName):
            feedback.acknowledge(WatchlistEditing.refusedMessage(orgName: orgName), tone: .warning)
        }
    }
}
