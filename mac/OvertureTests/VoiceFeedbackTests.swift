import Testing
import Foundation
import SwiftData

// #241 (milestone 6 / #119): export the high-signal edit pairs the capture step (#240) recorded.
// Only prospects Dan SUBSTANTIVELY edited AND sent, where the AI draft and the sent copy genuinely
// differ, newest first, capped, so a few trivial or stale edits can't dominate the drafter's context.

@MainActor
@Suite("Voice feedback export (#241)")
struct VoiceFeedbackTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(key: String, discipline: String = "music",
                          original: String?, sent: String?, sentAt: Date?,
                          originalSubject: String? = "AI subject",
                          sentSubject: String? = "Sent subject") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: discipline, venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.originalDraftSubject = original == nil ? nil : originalSubject
        p.originalDraftBody = original
        p.sentSubject = sent == nil ? nil : sentSubject
        p.sentBody = sent
        p.sentAt = sentAt
        return p
    }

    @Test func includesOnlyEditedAndSentPairs() {
        let edited = prospect(key: "edited-sent",
                              original: "Hi, I'd be glad to cover this.",
                              sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                              sentAt: Date(timeIntervalSince1970: 100))
        let sentNotEdited = prospect(key: "sent-only", original: nil,
                                     sent: "An unedited AI draft that went out as-is.",
                                     sentAt: Date(timeIntervalSince1970: 200))
        let editedNotSent = prospect(key: "edited-only",
                                     original: "Hi, I'd be glad to cover this.",
                                     sent: nil, sentAt: nil)

        let fb = VoiceFeedbackBuilder.build(from: [edited, sentNotEdited, editedNotSent],
                                            generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.map(\.naturalKey) == ["edited-sent"])
    }

    @Test func excludedProspectsAreNotExported() {
        // #244: Dan marked a send as "don't learn from this" — it must never reach the drafter.
        let kept = prospect(key: "kept",
                            original: "Hi, I'd be glad to cover this.",
                            sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                            sentAt: Date(timeIntervalSince1970: 100))
        let excluded = prospect(key: "excluded",
                                original: "Hi, I'd be glad to cover this.",
                                sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                                sentAt: Date(timeIntervalSince1970: 200))
        excluded.excludedFromVoiceLearning = true

        let fb = VoiceFeedbackBuilder.build(from: [kept, excluded], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.map(\.naturalKey) == ["kept"])
    }

    @Test func pairsAreTaggedWithTheirOutcome() {
        // #245: each pair carries the prospect's outcome so the distiller can lean on winners.
        let p = prospect(key: "booked",
                         original: "Hi, I'd be glad to cover this.",
                         sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                         sentAt: Date(timeIntervalSince1970: 100))
        p.outcome = .booked
        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.first?.outcome == "booked")
    }

    @Test func winnersAreKeptAndOrderedAheadOfRecentNonResponders() {
        // #245: a booked email survives the cap and leads, even when it's older than 20 no-response
        // edits, so the loop learns from what actually landed.
        let recent = (0..<20).map { i in
            prospect(key: "nr-\(i)",
                     original: "AI draft \(i) offering coverage.",
                     sent: "Reworked \(i): I photograph performing arts unobtrusively in New York.",
                     sentAt: Date(timeIntervalSince1970: TimeInterval(100 + i)))
        }
        let booked = prospect(key: "booked",
                              original: "AI draft offering coverage.",
                              sent: "Reworked: I photograph performing arts unobtrusively in New York City.",
                              sentAt: Date(timeIntervalSince1970: 1))   // oldest of all
        booked.outcome = .booked

        let fb = VoiceFeedbackBuilder.build(from: recent + [booked], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.count == 20)
        #expect(fb.pairs.first?.naturalKey == "booked")                       // winner leads
        #expect(fb.pairs.contains { $0.naturalKey == "booked" })              // survived the cap
        #expect(!fb.pairs.contains { $0.naturalKey == "nr-0" })               // oldest loser dropped instead
    }

    @Test func dropsNearIdenticalPairs() {
        // Dan edited substantively earlier, then the final sent copy ended up ~identical to the AI
        // draft (a near-revert / one-typo). No voice lesson, so it must be dropped.
        let p = prospect(key: "near-identical",
                         original: "Hi there, I would be glad to cover this.",
                         sent: "Hi there, I would be glad to cover this!",   // one char differs
                         sentAt: Date(timeIntervalSince1970: 100))
        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.isEmpty)
    }

    @Test func newestFirstAndCappedAtTwenty() {
        let many = (0..<22).map { i in
            prospect(key: "p-\(i)",
                     original: "AI draft number \(i) offering to cover the show.",
                     sent: "Reworked send \(i): I photograph performing arts unobtrusively in New York.",
                     sentAt: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let fb = VoiceFeedbackBuilder.build(from: many, generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.count == 20)
        #expect(fb.pairs.first?.naturalKey == "p-21")   // newest (largest sentAt) first
        #expect(fb.pairs.last?.naturalKey == "p-2")     // oldest two (p-0, p-1) dropped by the cap
    }

    @Test func mapsAllPairFields() {
        let p = prospect(key: "k1", discipline: "dance",
                         original: "Hi, I'd be glad to cover this.",
                         sent: "Hi Maria, I document dance unobtrusively and would love to cover this run.",
                         sentAt: Date(timeIntervalSince1970: 0),
                         originalSubject: "Photographing the spring run",
                         sentSubject: "Photographing your spring run")
        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")
        let pair = fb.pairs.first
        #expect(pair?.naturalKey == "k1")
        #expect(pair?.discipline == "dance")
        #expect(pair?.originalSubject == "Photographing the spring run")
        #expect(pair?.originalBody == "Hi, I'd be glad to cover this.")
        #expect(pair?.sentSubject == "Photographing your spring run")
        #expect(pair?.sentBody == "Hi Maria, I document dance unobtrusively and would love to cover this run.")
        #expect(pair?.sentAt == "1970-01-01T00:00:00Z")
        #expect(pair?.kind == nil)            // a cold opener carries no kind tag (defaults to cold)
        #expect(fb.version == 3)
    }

    @Test func exportWritesADecodableFile() throws {
        let ctx = ModelContext(try container())
        ctx.insert(prospect(key: "k1",
                            original: "Hi, I'd be glad to cover this.",
                            sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                            sentAt: Date(timeIntervalSince1970: 100)))
        try ctx.save()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try VoiceFeedbackService.export(from: ctx, generatedAt: "2026-06-26T00:00:00Z", url: url)
        #expect(count == 1)
        let decoded = try JSONDecoder().decode(VoiceFeedback.self, from: Data(contentsOf: url))
        #expect(decoded.version == 3)
        #expect(decoded.pairs.first?.naturalKey == "k1")
    }

    @Test func startPrepWritesVoiceFeedbackAlongsideTheQueue() async throws {
        let ctx = ModelContext(try container())
        // One kept-undrafted prospect so the queue is non-empty (otherwise startPrep throws).
        let toPrep = Prospect(naturalKey: "to-prep", groupName: "G2", discipline: "music", venue: "V",
                              performanceDate: "2026-08-01", sourceListingURL: nil,
                              priorRelationship: "none", production: "self", profile: "strong",
                              coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                              status: .queued)
        ctx.insert(toPrep)
        // One edited+sent prospect that should land in the feedback file.
        ctx.insert(prospect(key: "edited-sent",
                            original: "Hi, I'd be glad to cover this.",
                            sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                            sentAt: Date(timeIntervalSince1970: 100)))
        try ctx.save()

        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        let feedbackURL = FileManager.default.temporaryDirectory.appendingPathComponent("vf-\(UUID().uuidString).json")
        defer { [queueURL, marker, feedbackURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        try await PrepQueueService.startPrep(from: ctx, now: Date(timeIntervalSince1970: 0),
                                             queueURL: queueURL, markerURL: marker,
                                             voiceFeedbackURL: feedbackURL, launch: {})

        let decoded = try JSONDecoder().decode(VoiceFeedback.self, from: Data(contentsOf: feedbackURL))
        #expect(decoded.pairs.map(\.naturalKey) == ["edited-sent"])
    }

    // #392 (Dan's call, Option A): keep exactly ONE voice pair per performance (the shared body edit),
    // but attribute the outcome to the recipient who earned it, so the distiller knows which contact
    // the lesson landed through without duplicating the body N times.
    private func sentRecipient(_ id: String, provenance: RecipientProvenance,
                               replied: Bool = false, resolution: RecipientResolution? = nil) -> Recipient {
        var r = Recipient(id: id, email: id, provenance: provenance)
        r.sendState = .sent
        r.replied = replied
        r.resolution = resolution
        return r
    }

    @Test func attributesTheOutcomeToTheRepliedRecipientAsOnePair() {
        let p = prospect(key: "k",
                         original: "Hi, I'd be glad to cover this.",
                         sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                         sentAt: Date(timeIntervalSince1970: 100))
        p.outcome = .replied
        p.setRecipients([sentRecipient("act@x.example", provenance: .act),
                         sentRecipient("pres@y.example", provenance: .presenter, replied: true)])

        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")

        #expect(fb.pairs.count == 1)
        #expect(fb.pairs.first?.outcomeRecipientId == "pres@y.example")
    }

    @Test func aBookedRecipientWinsTheOutcomeAttributionOverAReplier() {
        let p = prospect(key: "k",
                         original: "Hi, I'd be glad to cover this.",
                         sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                         sentAt: Date(timeIntervalSince1970: 100))
        p.outcome = .booked
        p.setRecipients([sentRecipient("pres@y.example", provenance: .presenter, replied: true),
                         sentRecipient("act@x.example", provenance: .act, resolution: .booked)])

        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")

        #expect(fb.pairs.first?.outcomeRecipientId == "act@x.example")
    }

    @Test func noOutcomeRecipientWhenNoOneRepliedOrBooked() {
        let p = prospect(key: "k",
                         original: "Hi, I'd be glad to cover this.",
                         sent: "Hi Maria, I photograph performing arts and would document this run unobtrusively.",
                         sentAt: Date(timeIntervalSince1970: 100))
        p.setRecipients([sentRecipient("act@x.example", provenance: .act)])

        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")

        #expect(fb.pairs.first?.outcomeRecipientId == nil)
    }

    // #463: a reply Dan substantively edited AND committed is its own voice lesson, per recipient,
    // tagged kind "reply" so the distiller learns the reply register separately from cold openers.
    private func replyRecipient(_ id: String, original: String?, sent: String?, sentAt: Date?,
                                replied: Bool = true, resolution: RecipientResolution? = nil) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sendState = .sent
        r.replied = replied
        r.resolution = resolution
        r.originalReplyDraftBody = original
        r.sentReplyBody = sent
        r.replySentAt = sentAt
        return r
    }

    @Test func includesEditedAndSentReplyPairs() {
        let p = prospect(key: "show", original: nil, sent: nil, sentAt: nil)   // no cold pair on this show
        p.setRecipients([replyRecipient("act@x.example",
            original: "Sure, send me the details.",
            sent: "Hi Maria — yes, I'd be glad to cover the run. I shoot unobtrusively, no flash.",
            sentAt: Date(timeIntervalSince1970: 100))])

        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")

        #expect(fb.pairs.count == 1)
        let pair = fb.pairs.first
        #expect(pair?.kind == "reply")
        #expect(pair?.naturalKey == "show")
        #expect(pair?.originalBody == "Sure, send me the details.")
        #expect(pair?.sentBody == "Hi Maria — yes, I'd be glad to cover the run. I shoot unobtrusively, no flash.")
        #expect(pair?.outcomeRecipientId == "act@x.example")
        #expect(pair?.outcome == "replied")
    }

    @Test func anUnsentReplyEditIsNotExported() {
        let p = prospect(key: "show", original: nil, sent: nil, sentAt: nil)
        p.setRecipients([replyRecipient("act@x.example",
            original: "Sure, send me the details.",
            sent: nil, sentAt: nil)])   // edited but never committed
        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.isEmpty)
    }

    @Test func anUneditedSentReplyIsNotExported() {
        let p = prospect(key: "show", original: nil, sent: nil, sentAt: nil)
        p.setRecipients([replyRecipient("act@x.example",
            original: nil,   // no AI baseline captured -> nothing to learn from
            sent: "Yes, glad to cover this run.", sentAt: Date(timeIntervalSince1970: 100))])
        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.isEmpty)
    }

    @Test func excludedShowDropsItsReplyPairs() {
        let p = prospect(key: "show", original: nil, sent: nil, sentAt: nil)
        p.excludedFromVoiceLearning = true
        p.setRecipients([replyRecipient("act@x.example",
            original: "Sure, send details.",
            sent: "Hi Maria — yes, glad to cover the run unobtrusively, no flash.",
            sentAt: Date(timeIntervalSince1970: 100))])
        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.isEmpty)
    }

    @Test func aBookedReplyRecipientOutranksItsOutcome() {
        let p = prospect(key: "show", original: nil, sent: nil, sentAt: nil)
        p.setRecipients([replyRecipient("act@x.example",
            original: "Sure, details?",
            sent: "Hi — yes, I'd be glad to cover the run unobtrusively, no flash at all.",
            sentAt: Date(timeIntervalSince1970: 100), resolution: .booked)])
        let fb = VoiceFeedbackBuilder.build(from: [p], generatedAt: "2026-06-26T00:00:00Z")
        #expect(fb.pairs.first?.outcome == "booked")
    }
}
