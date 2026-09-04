import Testing
import Foundation
import SwiftData

// #3474: the due-work count on the Dock tile and beside the menu bar glyph was written in exactly one
// place, the periodic reconcile, so both surfaces stated a number up to half an hour out of date.
//
// Measured on the live store 2026-09-02: the 11:22 reconcile published 1, for the post-event prompt on
// a show performed Sep 1. Dan recorded an ending on it at 11:31:15 and the menu bar still read 1 at
// 11:31:41, while the Follow-ups pill beside it read zero the whole time, because that pill derives
// from `DueWork` live at render. The pill and the badge are meant to be one number on three surfaces
// (`DueBadge`'s own header) and they were two.
//
// It failed the other way too, which is the worse half: work comes due on the clock, and newly due
// work was invisible on exactly the two surfaces #2115 added for when the window is closed.
@MainActor
@Suite("The due badge is republished when the work changes (#3474)")
struct DueBadgeRepublishTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func eastern(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return EasternDate.calendar.date(from: c)!
    }

    @discardableResult
    private func sentLead(_ ctx: ModelContext, key: String, showOn: String?, sentAt: Date) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: showOn, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        let r = Recipient(id: key + "@e.invalid", email: key + "@e.invalid", name: "Them", provenance: .act)
        r.sendState = .sent
        r.sentAt = sentAt
        r.gmailMessageId = "m-" + key
        ctx.insert(r)
        p.setRecipients([r])
        return p
    }

    // The half a render cannot fix. With the window closed nothing re-renders, so the only thing that
    // can republish is a clock, and a 30 minute clock is what made newly due work invisible for up to
    // half an hour on the two surfaces that exist for exactly that state.
    @Test func aShowWhosePromptComesDueTonightNamesTheInstantItDoesSo() throws {
        let ctx = ModelContext(try container())
        // Performed today, so the prompt is owed from Eastern midnight tonight.
        sentLead(ctx, key: "tonight", showOn: "2026-09-04", sentAt: eastern(2026, 8, 20, 10, 0))
        let now = eastern(2026, 9, 4, 14, 0)
        let next = try #require(DueWork.nextChange(prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, replyRunAlive: false))
        #expect(next == eastern(2026, 9, 5, 0, 0))
    }

    // Strictly AFTER now. An instant already passed is work that is already counted, so returning it
    // would arm a republish that fires immediately and then arms itself again, for ever.
    @Test func anInstantAlreadyPassedIsNotTheNextChange() throws {
        let ctx = ModelContext(try container())
        sentLead(ctx, key: "past", showOn: "2026-08-01", sentAt: eastern(2026, 7, 20, 10, 0))
        let now = eastern(2026, 9, 4, 14, 0)
        let next = DueWork.nextChange(prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                      now: now, replyRunAlive: false)
        #expect(next == nil || next! > now)
    }

    // The SOONEST of them, across rules and across shows: a badge armed for the second of two changes
    // states a stale number for everything up to the first.
    @Test func theSoonestOfSeveralIsTheOneItNames() throws {
        let ctx = ModelContext(try container())
        sentLead(ctx, key: "later", showOn: "2026-09-20", sentAt: eastern(2026, 8, 20, 10, 0))
        sentLead(ctx, key: "sooner", showOn: "2026-09-06", sentAt: eastern(2026, 8, 20, 10, 0))
        let now = eastern(2026, 9, 4, 14, 0)
        let next = try #require(DueWork.nextChange(prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, replyRunAlive: false))
        #expect(next == eastern(2026, 9, 7, 0, 0))
    }

    // Nothing time-driven left is its own answer, not an arbitrary far future instant: a republish
    // armed for a change that cannot happen is a timer that never fires, and one armed for "an hour
    // from now" forever is the polling this replaces (L98, L11).
    @Test func aStoreWithNothingComingDueNamesNoInstantAtAll() throws {
        let ctx = ModelContext(try container())
        #expect(DueWork.nextChange(prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                   now: eastern(2026, 9, 4, 14, 0), replyRunAlive: false) == nil)
    }

    // A stalled reply draft is the third time-driven rule, and it is the one that stops being a
    // candidate while the run is alive: a draft still being written is not stalled, however long it
    // has taken.
    @Test func aLiveReplyRunMeansItsDraftIsNotAPendingChange() throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx, key: "drafting", showOn: nil, sentAt: eastern(2026, 9, 4, 13, 0))
        // Requested two minutes ago against a five minute timeout, so it becomes stalled three minutes
        // from now: sooner than this lead's first nudge, which is what makes the two answers differ.
        let requested = eastern(2026, 9, 4, 13, 58)
        p.recipients.first?.replyDraftRequestedAt = requested
        let now = eastern(2026, 9, 4, 14, 0)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let dead = DueWork.nextChange(prospects: all, now: now, replyRunAlive: false)
        #expect(dead == requested.addingTimeInterval(Recipient.replyDraftStallTimeout))
        let alive = DueWork.nextChange(prospects: all, now: now, replyRunAlive: true)
        #expect(alive != dead, "a draft still being written is not on its way to being stalled")
    }

    // The republish itself, driven directly rather than through the timer that normally calls it: it
    // recomputes from the STORE, so a change Dan made a moment ago is in the number.
    @Test func republishingTakesTheCountFromTheStoreAsItIsNow() throws {
        let ctx = ModelContext(try container())
        let defaults = try #require(UserDefaults(suiteName: "due-badge-\(UUID().uuidString)"))
        let p = sentLead(ctx, key: "ended", showOn: "2026-09-01", sentAt: eastern(2026, 8, 20, 10, 0))
        let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })
        let now = eastern(2026, 9, 4, 14, 0)

        #expect(scheduler.republishDueBadge(now: now, defaults: defaults) == 1)
        #expect(DueBadge.current(from: defaults) == 1)

        // Dan records how it ended, which is what he did at 11:31:15 on 2026-09-02 while the menu bar
        // went on reading 1.
        p.showOutcome = .neverHeardBack
        #expect(scheduler.republishDueBadge(now: now, defaults: defaults) == 0)
        #expect(DueBadge.current(from: defaults) == 0)
    }

    // Nothing coming due arms NO timer, rather than one set far out: a timer for a change that cannot
    // happen is a promise nothing keeps, and it would sit in the process for ever.
    @Test func aStoreWithNothingComingDueArmsNothing() throws {
        let ctx = ModelContext(try container())
        let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })
        scheduler.armBadgeRepublish(prospects: [], now: eastern(2026, 9, 4, 14, 0))
        #expect(SourceGuardHelper.source("Overture/App/ReconcileScheduler.swift")
            .contains("guard let next = DueWork.nextChange"),
                "the timer must be armed from the derivation, not from a fixed cadence")
    }

    // The other half of #3474, and the reason the badge and the pill drifted at all: the badge was a
    // snapshot taken on a timer while the pill was derived live from the store (L16). This asserts the
    // queue publishes the pill's OWN number rather than computing a second one beside it, which is the
    // only thing a test can reach: the publish happens in a SwiftUI body no test can evaluate.
    @Test func theQueuePublishesTheVeryNumberThePillShows() {
        let source = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(source.contains("DueBadge.publish(data.agentInputs.followUpsDue"),
                "the badge must be published from the pill's own derivation, not a second sweep")
        // And nothing else in that file may take its own DueWork count for this, which is how the two
        // came to be separate derivations in the first place.
        #expect(!source.contains("DueWork.counts"))
    }
}
