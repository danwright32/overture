import Testing
import Foundation
import SwiftData

// #730: cross-run anti-repetition. Within one Prep run the drafter sees its own earlier drafts and
// varies openers; across separate runs it has no memory, so day-to-day batches can independently
// land on the same handful of openers, the very thing #362 was meant to prevent. The app already
// holds every draft it produced, so it derives the recently-used opening SENTENCES here and hands
// them to the next run to steer away from. These fixtures pin that derivation: which drafts count,
// how an opener is extracted, dedup, recency order, and the cap.
@MainActor
@Suite("Recent openers export (#730)")
struct RecentOpenersBuilderTests {
    private func prospect(key: String, discipline: String = "music",
                          original: String? = nil, draft: String? = nil,
                          sentAt: Date? = nil, ingestedAt: Date = Date(timeIntervalSince1970: 0)) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: discipline, venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.originalDraftBody = original
        p.draftBody = draft
        p.sentAt = sentAt
        p.ingestedAt = ingestedAt
        return p
    }

    // MARK: opener extraction

    @Test func openerIsTheFirstSentenceOfTheBody() {
        let body = "I photograph performing arts in New York and saw Aurora Strings. My coverage is unobtrusive, no flash."
        #expect(RecentOpenersBuilder.opener(from: body) == "I photograph performing arts in New York and saw Aurora Strings.")
    }

    @Test func openerCollapsesWhitespaceAndWrapping() {
        let body = "I photograph performing arts\n  in New York and saw Aurora Strings.  My coverage is unobtrusive."
        #expect(RecentOpenersBuilder.opener(from: body) == "I photograph performing arts in New York and saw Aurora Strings.")
    }

    @Test func aBodyWithNoTerminatorIsTakenWhole() {
        #expect(RecentOpenersBuilder.opener(from: "A single clause with no period") == "A single clause with no period")
    }

    // MARK: build

    @Test func prefersTheAIOriginalOverTheCurrentDraftBody() {
        // The AI's own first opener is the shape we want variety on; Dan's later edit is a separate signal.
        let p = prospect(key: "k", original: "The AI original opener sentence. Rest.", draft: "Dan's edited opener. Rest.")
        let out = RecentOpenersBuilder.build(from: [p], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.map(\.opener) == ["The AI original opener sentence."])
    }

    @Test func fallsBackToDraftBodyWhenNoOriginal() {
        let p = prospect(key: "k", original: nil, draft: "Only a current draft opener. Rest.")
        let out = RecentOpenersBuilder.build(from: [p], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.map(\.opener) == ["Only a current draft opener."])
    }

    @Test func skipsProspectsWithNoDraftedBody() {
        let p = prospect(key: "undrafted", original: nil, draft: nil)
        let out = RecentOpenersBuilder.build(from: [p], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.isEmpty)
    }

    @Test func excludedProspectsAreNotExported() {
        // #244: a show Dan opted out of learning must not feed the drafter, here as elsewhere.
        let kept = prospect(key: "kept", original: "Kept opener sentence. Rest.")
        let excluded = prospect(key: "excluded", original: "Excluded opener sentence. Rest.")
        excluded.excludedFromVoiceLearning = true
        let out = RecentOpenersBuilder.build(from: [kept, excluded], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.map(\.naturalKey) == ["kept"])
    }

    // #2007 (carrying the half of #2013 that waited on the marker): this file exists to tell the AI
    // drafter which opening shapes to steer AWAY from. An email Dan wrote by hand is the shape he
    // wanted, so exporting it would teach the drafter to avoid his own sentences.
    @Test func handWrittenDraftsAreNotExportedAsShapesToAvoid() {
        let ai = prospect(key: "ai", original: "An AI opener sentence. Rest.")
        let byHand = prospect(key: "byHand", original: "Dan's own opener sentence. Rest.")
        byHand.draftWrittenByDan = true
        let out = RecentOpenersBuilder.build(from: [ai, byHand], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.map(\.naturalKey) == ["ai"])
    }

    @Test func dedupesIdenticalOpenersKeepingTheNewest() {
        // Two drafts that opened the same way count once; the survivor carries the more recent use.
        let older = prospect(key: "older", original: "I photograph performing arts. A.",
                             sentAt: Date(timeIntervalSince1970: 100))
        let newer = prospect(key: "newer", original: "I photograph performing arts.  B.",
                             sentAt: Date(timeIntervalSince1970: 200))
        let out = RecentOpenersBuilder.build(from: [older, newer], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.count == 1)
        #expect(out.openers.first?.naturalKey == "newer")
    }

    @Test func ordersNewestFirstByRecency() {
        let old = prospect(key: "old", original: "Old opener. x.", sentAt: Date(timeIntervalSince1970: 100))
        let mid = prospect(key: "mid", original: "Mid opener. x.", sentAt: Date(timeIntervalSince1970: 200))
        let new = prospect(key: "new", original: "New opener. x.", sentAt: Date(timeIntervalSince1970: 300))
        let out = RecentOpenersBuilder.build(from: [old, new, mid], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.map(\.naturalKey) == ["new", "mid", "old"])
    }

    @Test func fallsBackToIngestedAtWhenNeverSent() {
        // An unsent draft still has a recency: when it entered the queue, so it can still be ordered.
        let sent = prospect(key: "sent", original: "Sent opener. x.", sentAt: Date(timeIntervalSince1970: 100))
        let unsent = prospect(key: "unsent", original: "Unsent opener. x.", sentAt: nil,
                              ingestedAt: Date(timeIntervalSince1970: 500))
        let out = RecentOpenersBuilder.build(from: [sent, unsent], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.map(\.naturalKey) == ["unsent", "sent"])
    }

    @Test func capsAtMaxOpeners() {
        let many = (0..<(RecentOpenersBuilder.maxOpeners + 5)).map { i in
            prospect(key: "k\(i)", original: "Opener number \(i). Rest.",
                     sentAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let out = RecentOpenersBuilder.build(from: many, generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.openers.count == RecentOpenersBuilder.maxOpeners)
        // The cap keeps the newest, so the very newest opener survives and the oldest is dropped.
        #expect(out.openers.first?.opener == "Opener number \(RecentOpenersBuilder.maxOpeners + 4).")
        #expect(out.openers.contains { $0.opener == "Opener number 0." } == false)
    }

    @Test func carriesVersionAndGeneratedAt() {
        let out = RecentOpenersBuilder.build(from: [], generatedAt: "2026-07-01T00:00:00Z")
        #expect(out.version == RecentOpenersBuilder.version)
        #expect(out.generatedAt == "2026-07-01T00:00:00Z")
        #expect(out.openers.isEmpty)
    }
}
