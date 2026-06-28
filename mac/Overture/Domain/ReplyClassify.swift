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
    var naturalKey: String   // opaque, echo verbatim
    var groupName: String    // research only
    var venue: String?
    var replyText: String
}

enum ReplyClassifyQueueBuilder {
    static let version = 1

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
}

struct ReplyClassifyResult: Codable, Equatable, Sendable {
    var naturalKey: String
    var intent: String   // raw ReplyIntent value; tolerated as a string so an unknown value decodes

    var replyIntent: ReplyIntent? { ReplyIntent(rawValue: intent) }
}

enum ReplyClassifyResultsError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum ReplyClassifyResultsDecoder {
    // Tolerant version gate (min...supported), mirroring the #157 decoders so a version bump leaves
    // older files still accepted.
    static let supportedVersion = 1
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
