import Testing
import Foundation

// #1773: whether a row is a voice-learning candidate is a fact about that ONE show, and it is the only
// reason the row factory ever held the whole prospect array. It answered by scanning all 724 prospects
// for the one matching this card, per card, on every render pass.
//
// It belongs on the snapshot instead, resolved once when the queue is built, which is the rule every
// other whole-store verdict on QueueItem already follows (inheritedReachability, presenterLine,
// producerStanding). These pin the resolution itself, so the card can be handed the
// answer rather than going looking for it.
@Suite("A queue item carries its own voice-learning standing (#1773)")
struct QueueItemVoiceLearningTests {
    private func prospect(sentAt: Date?, originalDraftBody: String?, excluded: Bool = false) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                         performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = sentAt
        p.originalDraftBody = originalDraftBody
        p.excludedFromVoiceLearning = excluded
        return p
    }

    // The case the right-click menu exists for: Dan hand-edited a draft and sent it, so the loop can
    // learn from what he changed.
    @Test func aSentShowWithAnAiDraftBehindItIsACandidate() {
        let item = QueueItem(prospect(sentAt: Date(timeIntervalSince1970: 100),
                                      originalDraftBody: "The AI's original wording."))
        #expect(item.voiceLearningCandidate)
    }

    // Nothing was sent, so there is nothing to learn from yet.
    @Test func anUnsentShowIsNotACandidate() {
        let item = QueueItem(prospect(sentAt: nil, originalDraftBody: "The AI's original wording."))
        #expect(!item.voiceLearningCandidate)
    }

    // Sent, but with no AI draft recorded behind it (Dan wrote it himself, or it predates the capture),
    // so there is no before-and-after to compare and nothing to learn.
    @Test func aSentShowWithNoOriginalDraftIsNotACandidate() {
        let item = QueueItem(prospect(sentAt: Date(timeIntervalSince1970: 100), originalDraftBody: nil))
        #expect(!item.voiceLearningCandidate)
    }

    // The menu's own label depends on the current opt-out state, so the snapshot has to carry it too,
    // or the card would still have to go looking for the model to know what to say.
    @Test func theOptOutStateRidesOnTheItem() {
        let optedOut = QueueItem(prospect(sentAt: Date(timeIntervalSince1970: 100),
                                          originalDraftBody: "o", excluded: true))
        let learning = QueueItem(prospect(sentAt: Date(timeIntervalSince1970: 100),
                                          originalDraftBody: "o", excluded: false))
        #expect(optedOut.excludedFromVoiceLearning)
        #expect(!learning.excludedFromVoiceLearning)
    }
}
