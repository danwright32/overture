import Testing
import Foundation

private let bounceAfterReplyGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")

// #2829: a hard bounce on a conversation that has already replied.
//
// `detectBounces` skipped any replied recipient outright, and since #2815 the fetcher hands it the
// threads of OPEN conversations, so the bounce notice is in hand and was dropped. An address can stop
// working mid conversation (a person leaves, a forwarding address is retired) and the only symptom was
// silence: Dan writes back, nothing arrives, and nothing on screen says the send failed (L12).
//
// The skip itself is right and stays. `bounced` closes the show through PerformanceStatus and drops the
// contact out of follow-ups, so marking would write off a conversation that is demonstrably live, which
// is worse than the silence. So this REPORTS, exactly as #2032 and #2717 already do for the two other
// bounces that cannot be attributed, through the same channel and the same once-only `lastBounceId`.
@Suite("A bounce after a reply is reported, never marked (#2829)")
struct BounceAfterAReplyTests {
    @MainActor
    private static func repliedProspect(threadId: String = "thread-1") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                         performanceDate: "2026-11-14", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        let r = Recipient(id: "a@org.example", email: "a@org.example", provenance: .act)
        r.sendState = .sent
        r.gmailThreadId = threadId
        r.replied = true
        r.repliedAt = Date()
        p.setRecipients([r])
        return p
    }

    private static func hardBounceJSON(id: String = "bounce-1") -> Data {
        bounceAfterReplyGmail.thread([
            .init(from: "mailer-daemon@googlemail.com",
                  subject: "Delivery Status Notification (Failure)", id: id),
        ])
    }

    private static let me = "dan@danwrightphotography.com"

    // The protection that must not be lost, restated here rather than left to the older suite: this is
    // the half that makes the reporting safe to add.
    @Test @MainActor func therepliedContactIsStillNeverMarkedBounced() {
        let p = Self.repliedProspect()
        var problems: [String] = []

        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                    fetchThread: { _ in Self.hardBounceJSON() },
                                    reportProblem: { problems.append($0) })

        #expect(p.recipients[0].bounced == false)
        #expect(p.outcome != .booked)
    }

    // THE gap: it was silent.
    @Test @MainActor func thebounceIsReported() {
        let p = Self.repliedProspect()
        var problems: [String] = []

        let marked = BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                                 fetchThread: { _ in Self.hardBounceJSON() },
                                                 reportProblem: { problems.append($0) })

        #expect(problems.count == 1, "a bounce arriving after a reply was recorded nowhere")
        #expect(problems.first?.contains("Aurora Strings") == true, "so Dan knows which conversation")
        // Reported, not counted: the return value is how many were MARKED, and nobody was.
        #expect(marked == 0)
    }

    // A message may claim only what its check measured (L11). Nothing here establishes that the bounce
    // came AFTER the reply: the classification reads From and Subject headers, not an ordering.
    @Test @MainActor func thereportDoesNotClaimAnOrderItDidNotMeasure() {
        let p = Self.repliedProspect()
        var problems: [String] = []
        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                    fetchThread: { _ in Self.hardBounceJSON() },
                                    reportProblem: { problems.append($0) })

        let text = problems.first ?? ""
        #expect(text.contains("later") == false)
        #expect(text.contains("since") == false)
        // And it says what Overture did NOT do, so the row still reading as live is explained rather
        // than left looking like the bounce was missed.
        #expect(text.lowercased().contains("still open") || text.lowercased().contains("has not"))
    }

    // Once per notice, like both existing report paths. A reconcile tick runs every 30 minutes and this
    // thread is fetched on every one of them.
    @Test @MainActor func thesameNoticeIsReportedOnlyOnce() {
        let p = Self.repliedProspect()
        var problems: [String] = []
        for _ in 0..<3 {
            BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                        fetchThread: { _ in Self.hardBounceJSON() },
                                        reportProblem: { problems.append($0) })
        }

        #expect(problems.count == 1)
    }

    // A DIFFERENT notice on the same thread is a new fact and reports again, which is what keying on the
    // id rather than on a bool buys.
    @Test @MainActor func alaterNoticeWithADifferentIdReportsAgain() {
        let p = Self.repliedProspect()
        var problems: [String] = []
        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                    fetchThread: { _ in Self.hardBounceJSON(id: "bounce-1") },
                                    reportProblem: { problems.append($0) })
        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                    fetchThread: { _ in Self.hardBounceJSON(id: "bounce-2") },
                                    reportProblem: { problems.append($0) })

        #expect(problems.count == 2)
    }

    // A bounce Dan has already dismissed stays dismissed. The dismissal is a judgement about the notice,
    // and it does not become undone by the contact having replied.
    @Test @MainActor func adismissedBounceIsNotReported() {
        let p = Self.repliedProspect()
        p.recipients[0].dismissedBounceId = "bounce-1"
        var problems: [String] = []

        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                    fetchThread: { _ in Self.hardBounceJSON(id: "bounce-1") },
                                    reportProblem: { problems.append($0) })

        #expect(problems.isEmpty)
    }

    // A thread with no bounce on it says nothing, which is the case that makes the four above mean
    // anything: a report on every replied conversation would be noise nobody reads (L36, L159).
    @Test @MainActor func aquietThreadIsStillQuiet() {
        let p = Self.repliedProspect()
        var problems: [String] = []

        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                    fetchThread: { _ in bounceAfterReplyGmail.thread([
                                        .init(from: "a@org.example", subject: "Re: your email", id: "m1"),
                                    ]) },
                                    reportProblem: { problems.append($0) })

        #expect(problems.isEmpty)
        #expect(p.recipients[0].bounced == false)
    }

    // The delay notice is untouched by this. `hasRecentDeliveryDelay` already refuses to show one on a
    // replied contact, so recording it here would be a written value with no reader (L46).
    @Test @MainActor func adelayNoticeIsStillNotRecordedOnARepliedContact() {
        let p = Self.repliedProspect()
        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: .now,
                                    fetchThread: { _ in bounceAfterReplyGmail.thread([
                                        .init(from: "mailer-daemon@googlemail.com",
                                              subject: "Delayed Delivery Notification", id: "d1"),
                                    ]) },
                                    reportProblem: { _ in })

        #expect(p.recipients[0].delayNoticeAt == nil)
    }
}
