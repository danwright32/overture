import Foundation

// The reply-classification handoff (#112): the app hands the Prep-style classify workflow the kept
// replies to read, and ingests the intents it writes back. Two committed contracts under
// fixtures/reply-classify/ guard the shape (#157). naturalKey is an OPAQUE token the workflow must
// echo back verbatim, never rebuild (the silent-mismatch trap). Sibling in spirit to PrepQueue/PrepResults.

// The AI's read of a reply, mapped to the conversation state it should suggest.
enum ReplyIntent: String, CaseIterable, Sendable {
    case interested
    case wantsToBook = "wants_to_book"
    case hasQuestion = "has_question"
    case declined

    var conversationState: ConversationState {
        switch self {
        case .interested: return .interested
        case .wantsToBook: return .wantsToBook
        case .hasQuestion: return .hasQuestion
        case .declined: return .declined
        }
    }
}

// Written by the app (the work-list).
struct ReplyClassifyQueue: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var items: [ReplyClassifyItem]
}

struct ReplyClassifyItem: Codable, Equatable, Sendable {
    var naturalKey: String       // opaque show join key, echo verbatim
    var groupName: String        // research only
    var venue: String?
    var performanceDate: String? // v3 (#438): the show date Overture already knows, so a draft names it
                                 // instead of asking for it; absent only for a genuinely undated show
    var replyText: String
    var recipientId: String?     // v2 (#392): which recipient on the show this reply came from
}

enum ReplyClassifyQueueBuilder {
    static let version = 3

    static func build(from items: [ReplyClassifyItem], generatedAt: String) -> ReplyClassifyQueue {
        ReplyClassifyQueue(version: version, generatedAt: generatedAt, items: items)
    }

    static func encode(_ queue: ReplyClassifyQueue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(queue)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-reply-classify-queue.json")
    }
}

// Written by the classify workflow, read by the app.
struct ReplyClassifyResults: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var results: [ReplyClassifyResult]
    // #846: which model wrote these reply drafts. Stamped by the RUNNER SCRIPT after the run
    // (lib/models.sh record_model), never by the model itself: asking a model to write down which model
    // it is invites it to be confidently wrong about the one fact the record exists to establish.
    //
    // The script has written this since #804. This struct did not decode it, so it was read off disk and
    // dropped on the floor, and the reply half of that record silently never existed. Mirrors
    // PrepResults.model.
    //
    // Optional, so a results file from before the stamp still decodes and still lands Dan's draft. A gap
    // in the record is never a reason to drop his work.
    var model: String? = nil
}

struct ReplyClassifyResult: Codable, Equatable, Sendable {
    var naturalKey: String
    var intent: String         // raw ReplyIntent value; tolerated as a string so an unknown value decodes.
                               // v3 (#420 C4): consumed as a NON-BINDING intent hint (recipient.intentHint),
                               // never auto-sets a RecipientResolution.
    var recipientId: String?   // v2 (#392): echoed back so the intent attaches to the right recipient
    var draftSubject: String?  // v3 (#420): the AI-drafted reply subject for this recipient (optional)
    var draftBody: String?     // v3 (#420): the AI-drafted reply body for this recipient (optional)

    var replyIntent: ReplyIntent? { ReplyIntent(rawValue: intent) }
}

enum ReplyClassifyResultsError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum ReplyClassifyResultsDecoder {
    // Tolerant version gate (min...supported), mirroring the #157 decoders so a version bump leaves
    // older files still accepted. v2 (#392) added the optional recipient discriminator; v3 (#420)
    // added the optional per-recipient draftSubject/draftBody.
    static let supportedVersion = 3
    static let minimumVersion = 1

    static func decode(_ data: Data) throws -> ReplyClassifyResults {
        let results = try JSONDecoder().decode(ReplyClassifyResults.self, from: data)
        guard (minimumVersion...supportedVersion).contains(results.version) else {
            throw ReplyClassifyResultsError.unsupportedVersion(results.version)
        }
        return results
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-reply-classify-results.json")
    }
}
