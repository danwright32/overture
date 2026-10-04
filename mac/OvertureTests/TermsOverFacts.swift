import Foundation
import SwiftData

// #4357 (plan v7 Phase 3, oracle part two): every ported queue term, run once over the live `Prospect`
// models and once over the very same rows as `RowFacts.extract` hands them back, compared output by output.
//
// WHAT THIS CAN AND CANNOT SEE (plan Phase 3 step 3, quoted in spirit rather than restated). Both arms run
// the SAME generic term code, so a wrong term passes here: that is oracle part one's job, old against new on
// a frozen snapshot before the old is deleted. What this sees is everything between a model and its value:
// a field `extract` copies wrongly, a field it does not carry, a computed member that answers differently
// on the two conformers. Those are exactly the faults a retained value would hide for ever, because a row
// that never goes stale looks like a row that has not changed (L40).
//
// THE FINDINGS NAME A TERM, A FIELD AND A ROW'S PERSISTENT IDENTIFIER, NEVER A TITLE OR A VENUE. The live
// store arm runs over Dan's real shows, and a failing assertion's text is what reaches a pull request
// (L222, the `CardDivergenceRecord` privacy rule). The identifier says which row without saying what it is.
//
// ONE PLACE, GROWN BY EACH SLICE. Slice A carries T1 (ShowLink group and collapse), T2
// (ContradictedCancellation) and T3 (feed breaks); slice B adds T4 (the producer tables) and T5 (the
// organisation answer ledger); slice C adds T6 (EngagementLink) and moves T1, T4 and T6 onto the entry
// points `QueueModel.scope` calls, which take the rows themselves. Each later slice adds its terms here, so the fixture suites and the live
// store suite ask every ported term the same question through one comparison (L370).
enum TermsOverFacts {

    /// T5's inputs other than the rows: the stored organisation answers, the struck addresses, the shows a
    /// live run holds, and the instant freshness is judged at. Dan's producer corrections are read by T4
    /// as well, so they are a parameter of `findings` itself.
    struct Ledger {
        var answers: [OrgReachabilityAnswer]
        var refusals: ContactRefusal.Ledger = .none
        var heldKeys: Set<String> = []
        var now: Date
    }

    // MARK: slice F, the agent input terms

    /// `organisationRowCounts`, `DraftedDeadEnd` and `StalledReplyDraft`, models against facts. The counts are
    /// keyed by an organisation's folded name, a real organisation on the live store, so a difference names the
    /// rows whose presenter it is about rather than the name (L222).
    static func agentInputFindings(_ models: [Prospect], _ facts: [RowFacts], now: Date) -> [String] {
        var out: [String] = []
        let countsModels = QueueModel.organisationRowCounts(among: models)
        let countsFacts = QueueModel.organisationRowCounts(among: facts)
        if countsModels != countsFacts {
            let differing = Set(countsModels.keys).union(countsFacts.keys).filter { countsModels[$0] != countsFacts[$0] }
            let rows = models.filter { ProducerGate.key($0.presenter).map(differing.contains) ?? false }
            out += rows.map { "organisationRowCounts differs for the organisation of row \($0.persistentModelID)" }
            if rows.isEmpty { out.append("organisationRowCounts differs for an organisation no model presents") }
        }
        for (model, fact) in zip(models, facts)
        where DraftedDeadEnd.hasNobodyToSendTo(model, contacts: model.factContacts)
            != DraftedDeadEnd.hasNobodyToSendTo(fact, contacts: fact.factContacts) {
            out.append("DraftedDeadEnd.hasNobodyToSendTo differs for row \(model.persistentModelID)")
        }
        for instant in [now, Date.distantFuture] {
            let onModels = StalledReplyDraft.dueRecipients(from: models, contacts: { $0.factContacts }, now: instant, runAlive: false)
            let onFacts = StalledReplyDraft.dueRecipients(from: facts, contacts: { $0.factContacts }, now: instant, runAlive: false)
            if onModels.map({ "\($0.recipient.persistentModelID) \($0.requestedAt)" })
                != onFacts.map({ "\($0.recipient.persistentModelID) \($0.requestedAt)" }) {
                out.append("StalledReplyDraft.dueRecipients differs "
                           + (instant == now ? "now" : "at the end of time")
                           + ": \(onModels.count) over models, \(onFacts.count) over facts")
            }
        }
        return out
    }

    /// Every place a ported term answered differently over facts than over models, empty when they agree.
    /// `asOf` is the day the feed break term judges "still to come" against, and `drawn` the keys a
    /// surface draws, which is what the collapse hides rows in favour of (nil means every row is drawn).
    /// `facts` defaults to extracting `models` now; a positive control hands in facts taken BEFORE a model
    /// changed, to show the comparison can see a retained row that went stale (L159).
    /// `rowByRow` also asks `liveTwin` of every flagged row on both arms, which is flagged rows times all
    /// rows: about a second on the clone and over 40 on the 4x copy (measured 2026-10-02), so the 4x arm
    /// compares the indexed set alone, which is what the pass reads.
    /// `overrides` are Dan's producer corrections, read by T4 and T5. `ledger` nil means T5 is not asked,
    /// which is right for a fixture that seeds no answers: the ledger returns before reading a row when it
    /// has none.
    static func findings(_ models: [Prospect], facts given: [RowFacts]? = nil, asOf: String,
                         drawn: Set<String>? = nil, rowByRow: Bool = true,
                         overrides: ProducerOverrides = .none, ledger: Ledger? = nil) -> [String] {
        let facts = given ?? models.map(RowFacts.extract)
        let pidByKey = Dictionary(models.map { ($0.naturalKey, String(describing: $0.persistentModelID)) },
                                  uniquingKeysWith: { first, _ in first })
        func pid(_ key: String) -> String { pidByKey[key] ?? "a row no model holds" }
        var out: [String] = []

        // T1: the grouping and the collapse, through the entry points the pass calls (slice C).
        let groupModels = ShowLink.group(among: models)
        let groupFacts = ShowLink.group(among: facts)
        for key in Set(groupModels.keys).union(groupFacts.keys).sorted()
        where Set(groupModels[key] ?? []) != Set(groupFacts[key] ?? []) {
            out.append("ShowLink.group members differ for row \(pid(key))")
        }
        let collapseModels = ShowLink.collapse(among: models, drawn: drawn)
        let collapseFacts = ShowLink.collapse(among: facts, drawn: drawn)
        for key in Set(collapseModels.fronts.keys).union(collapseFacts.fronts.keys).sorted()
        where Set(collapseModels.fronts[key] ?? []) != Set(collapseFacts.fronts[key] ?? []) {
            out.append("ShowLink.collapse fronts differ for row \(pid(key))")
        }
        for key in collapseModels.hidden.symmetricDifference(collapseFacts.hidden).sorted() {
            out.append("ShowLink.collapse hidden differs for row \(pid(key))")
        }

        // T2: the set the pass reads, and the row by row rule it is an index of.
        let contradictedModels = ContradictedCancellation.contradictedKeys(among: models)
        let contradictedFacts = ContradictedCancellation.contradictedKeys(among: facts)
        for key in contradictedModels.symmetricDifference(contradictedFacts).sorted() {
            out.append("ContradictedCancellation.contradictedKeys differs for row \(pid(key))")
        }
        for (model, fact) in zip(models, facts) where model.disappearedFromFeed || fact.disappearedFromFeed {
            if model.disappearedFromFeed != fact.disappearedFromFeed {
                out.append("disappearedFromFeed differs for row \(pid(model.naturalKey))")
            }
            guard rowByRow else { continue }
            let twinModel = ContradictedCancellation.liveTwin(of: model, among: models)?.persistentModelID
            let twinFact = ContradictedCancellation.liveTwin(of: fact, among: facts)?.persistentModelID
            if twinModel != twinFact {
                out.append("ContradictedCancellation.liveTwin differs for row \(pid(model.naturalKey))")
            }
        }

        // T3: every event, field by field and by name, with the contradicted set the pass shares in.
        let eventsModels = FeedBreakEvent.events(among: models, asOf: asOf, contradicted: contradictedModels)
        let eventsFacts = FeedBreakEvent.events(among: facts, asOf: asOf, contradicted: contradictedFacts)
        out += eventFindings(eventsModels, eventsFacts, term: "FeedBreakEvent.events", pid: pid)

        // T4: each row's projection, then the two whole-corpus tables and the memo key built from them.
        let showsModels = models.map(ProducerGate.Show.init)
        let showsFacts = facts.map(ProducerGate.Show.init)
        for (model, (a, b)) in zip(models, zip(showsModels, showsFacts)) where a != b {
            out.append("ProducerGate.Show differs for row \(pid(model.naturalKey))")
        }
        let tablesModels = QueueModel.ProducerTables(rows: models, overrides: overrides)
        let tablesFacts = QueueModel.ProducerTables(rows: facts, overrides: overrides)
        out += tableFindings(tablesModels, tablesFacts, rows: models, term: "ProducerTables", pid: pid)
        if QueueModel.ProducerTables.key(shows: showsModels, overrides: overrides)
            != QueueModel.ProducerTables.key(shows: showsFacts, overrides: overrides) {
            out.append("ProducerTables.key differs")
        }

        // T6: the cross-venue engagements, member lists compared in the order the term returns them.
        let linkedModels = EngagementLink.group(among: models)
        let linkedFacts = EngagementLink.group(among: facts)
        for key in Set(linkedModels.keys).union(linkedFacts.keys).sorted() where linkedModels[key] != linkedFacts[key] {
            out.append("EngagementLink.group members differ for row \(pid(key))")
        }

        // T5: the inherited answer of every show, each arm with its own producer index, as the pass hands it.
        if let ledger {
            let inheritedModels = QueueModel.inheritedAnswers(
                ledger.answers, corpus: models, overrides: overrides, refusals: ledger.refusals,
                heldKeys: ledger.heldKeys, now: ledger.now, producerCorpus: tablesModels.corpus)
            let inheritedFacts = QueueModel.inheritedAnswers(
                ledger.answers, corpus: facts, overrides: overrides, refusals: ledger.refusals,
                heldKeys: ledger.heldKeys, now: ledger.now, producerCorpus: tablesFacts.corpus)
            out += inheritedFindings(inheritedModels, inheritedFacts, term: "OrgAnswerLedger.inherited", pid: pid)
        }

        // Slice F: the agent input terms, judged at noon Eastern on `asOf` so both arms share a clock.
        out += agentInputFindings(models, facts, now: (EasternDate.date(from: asOf) ?? Date(timeIntervalSince1970: 0))
            .addingTimeInterval(12 * 3600))

        // Slice D1: the computed members the reached-out terms read, on the show and on every contact.
        out += memberFindings(models, facts)

        // Slice D2: the reached-out terms, judged at a fixed instant on `asOf` so the two arms share a clock.
        out += reachedOutFindings(models, facts, now: reachedOutInstant(asOf), today: asOf)
        // Slice E1: the stage placement, the geography and client window it reads, and its members.
        out += stageFindings(models, facts, asOf: asOf)
        return out
    }

    // MARK: slice D2, the reached-out terms

    /// Noon Eastern on `day`, the instant the reached-out comparison judges at. Fixed by the day rather than
    /// read off the wall clock, so a fixture run and its rerun ask the same question (L74).
    static func reachedOutInstant(_ day: String) -> Date {
        (EasternDate.date(from: day) ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(12 * 3600)
    }

    /// What a reached-out term says about one contact on one show, read through the generic terms.
    struct ReachedOutAnswers: Equatable {
        let isInPlay: Bool
        let nextReachOut: Date?
        let nextActionableMoment: Date?
        let isDueNow: Bool
        let timingLabel: String
        let action: ReachedOutAction
        let isAwaitingNudge: Bool
        let nextPromptDate: Date?
        let prompt: PostEventPrompt.Prompt?

        init<Row: ProspectFacts>(_ r: Row.Contact, of show: ReachedOutQueue.Show<Row>, now: Date, today: String) {
            isInPlay = ReachedOutQueue.isInPlay(r, of: show)
            nextReachOut = ReachedOutQueue.nextReachOut(for: r, of: show, now: now)
            nextActionableMoment = ReachedOutQueue.nextActionableMoment(for: r, of: show, now: now)
            isDueNow = ReachedOutQueue.isDueNow(for: r, of: show, now: now)
            timingLabel = ReachedOutQueue.timingLabel(for: r, of: show, now: now, today: today)
            action = ReachedOutAction.of(r, in: show, now: now, today: today)
            isAwaitingNudge = FollowUp.isAwaitingNudge(r, in: show.row, now: now)
            nextPromptDate = PostEventPrompt.nextPromptDate(for: r, of: show)
            prompt = PostEventPrompt.prompt(for: r, of: show, now: now)
        }

        func differing(from other: ReachedOutAnswers) -> [String] {
            Mirror(reflecting: self).children.compactMap { child in
                guard let label = child.label,
                      let theirs = Mirror(reflecting: other).children.first(where: { $0.label == label })
                else { return nil }
                return String(describing: child.value) == String(describing: theirs.value) ? nil : label
            }
        }
    }

    /// The reached-out list over models and over facts, entry by entry, and every contact's answers.
    ///
    /// THE REPRESENTATIVE IS COMPARED AS A TIE CLASS (the inventory's word for this slice). Each show's row
    /// speaks for one contact, chosen by a total order whose last key is the store's identifier. A different
    /// contact on the two arms is one of two faults, and they are told apart: a contact OUTSIDE the
    /// representative's tie class (a different reply instant, or a different due date when nobody replied)
    /// means a fact the order reads came across differently; one INSIDE it means only the tie breaks
    /// (address, identifier) disagreed. Both are findings; the label says which.
    static func reachedOutFindings(_ models: [Prospect], _ facts: [RowFacts], now: Date, today: String) -> [String] {
        var out: [String] = []
        let onModels = ReachedOutQueue.activeWithDates(from: models, contacts: { $0.factContacts }, now: now)
        let onFacts = ReachedOutQueue.activeWithDates(from: facts, contacts: { $0.factContacts }, now: now)
        let factsByKey = Dictionary(onFacts.map { ($0.prospect.naturalKey, $0) }, uniquingKeysWith: { first, _ in first })
        if onModels.map(\.prospect.naturalKey) != onFacts.map(\.prospect.naturalKey) {
            out.append("ReachedOutQueue.activeWithDates order or membership differs")
        }
        for entry in onModels {
            let pid = String(describing: entry.prospect.persistentModelID)
            guard let other = factsByKey[entry.prospect.naturalKey] else {
                out.append("ReachedOutQueue.activeWithDates drops row \(pid) over facts")
                continue
            }
            if entry.next != other.next { out.append("ReachedOutQueue.activeWithDates date differs for row \(pid)") }
            if entry.recipient.persistentModelID != other.recipient.persistentModelID {
                let sameClass = entry.recipient.replied == other.recipient.replied
                    && (entry.recipient.replied
                        ? entry.recipient.replyArrivedAt == other.recipient.replyArrivedAt
                        : ReachedOutQueue.nextReachOut(for: entry.recipient, of: .init(entry.prospect, contacts: entry.prospect.factContacts), now: now)
                            == ReachedOutQueue.nextReachOut(for: other.recipient, of: .init(other.prospect, contacts: other.prospect.factContacts), now: now))
                out.append("ReachedOutQueue.activeWithDates representative differs "
                           + (sameClass ? "within its tie class" : "across tie classes") + " for row \(pid)")
            }
        }
        for (model, fact) in zip(models, facts) {
            let modelShow = ReachedOutQueue.Show(model, contacts: model.factContacts)
            let factShow = ReachedOutQueue.Show(fact, contacts: fact.factContacts)
            let factByID = Dictionary(fact.factContacts.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
            for contact in model.factContacts {
                guard let record = factByID[contact.persistentModelID] else { continue }   // memberFindings names it
                let names = ReachedOutAnswers(contact, of: modelShow, now: now, today: today)
                    .differing(from: ReachedOutAnswers(record, of: factShow, now: now, today: today))
                if !names.isEmpty {
                    out.append("reached-out answers \(names.joined(separator: ", ")) differ for contact "
                               + String(describing: contact.persistentModelID))
                }
            }
        }
        return out
    }

    // MARK: slice E1, the stage placement and the members it reads

    /// The context the stage comparison judges against: the day `asOf` at noon in New York, Overture's own
    /// geography rules with no refusals of Dan's, and a client window holding every other source id the rows
    /// carry (sorted, so it is the same set every run), so the client arm of the lead time rule is asked on
    /// both sides of its line rather than never.
    static func stageContext(for models: [Prospect], asOf: String) -> StageContext {
        let sources = Set(models.flatMap(\.sourceIds)).sorted()
        let clients = Set(sources.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        let noon = (EasternDate.date(from: asOf) ?? Date(timeIntervalSince1970: 0)).addingTimeInterval(12 * 3600)
        return StageContext(now: noon, geo: .none, clients: ClientWindow(clientSourceIds: clients), today: asOf)
    }

    /// Every show member slice E1 moved onto `ProspectFacts`, read through the protocol.
    struct StageMembers: Equatable {
        let hasDraft: Bool
        let hasOpened: Bool
        let isReprepQueued: Bool
        let sendsTogether: Bool
        let greetingAudienceSize: Int
        let blockedContactCount: Int
        let hasEnteredSendHalf: Bool
        let hiddenByGeography: Bool
        let isPastClientShow: Bool

        init(_ p: some ProspectFacts, context: StageContext) {
            hasDraft = p.hasDraft
            hasOpened = p.hasOpened(today: context.today)
            isReprepQueued = p.isReprepQueued
            sendsTogether = p.sendsTogether
            greetingAudienceSize = p.greetingAudienceSize
            blockedContactCount = p.blockedContactCount
            hasEnteredSendHalf = p.hasEnteredSendHalf
            hiddenByGeography = context.geo.hidesFromQueue(p)
            isPastClientShow = context.clients.isPastClientShow(p)
        }
    }

    /// Every contact rule slice E1 moved onto `ContactFacts`, each judged on the show's draft and audience.
    struct StageContactMembers: Equatable {
        let isLooksLikeAnotherPersons: Bool
        let isSendStuck: Bool
        let draftLintBlockers: [DraftIssue]
        let isBlockedByGreeting: Bool
        let isBlockedAwaitingReview: Bool

        init(_ c: some ContactFacts, body: String?, audience: Int, now: Date) {
            isLooksLikeAnotherPersons = c.isLooksLikeAnotherPersons
            isSendStuck = c.isSendStuck(now: now)
            draftLintBlockers = c.draftLintBlockers(body: body)
            isBlockedByGreeting = c.isBlockedByGreeting(body: body, audience: audience)
            isBlockedAwaitingReview = c.isBlockedAwaitingReview(body: body, audience: audience,
                                                                lintBlockers: c.draftLintBlockers(body: body))
        }
    }

    /// The placement over models (each row's own `recipients`, as the pass reads them) against the placement
    /// over facts (`factContacts`), focus by focus, then the members, then the resolved geography. Findings
    /// name a focus, a member and an identifier, never a title, a venue or an address (L222).
    static func stageFindings(_ models: [Prospect], _ facts: [RowFacts], asOf: String) -> [String] {
        let context = stageContext(for: models, asOf: asOf)
        var out: [String] = []
        let pidByKey = Dictionary(models.map { ($0.naturalKey, String(describing: $0.persistentModelID)) },
                                  uniquingKeysWith: { first, _ in first })
        let onModels = StageNavigation.placements(in: models, context: context)
        let onFacts = StageNavigation.placements(in: facts, context: context)
        if onModels.count != onFacts.count {
            out.append("StageNavigation.placements placed \(onModels.count) row(s) one way and \(onFacts.count) the other")
        }
        for focus in StageFocus.allCases {
            let a = Set(StageNavigation.naturalKeys(for: focus, in: onModels))
            let b = Set(StageNavigation.naturalKeys(for: focus, in: onFacts))
            for key in a.symmetricDifference(b).sorted() {
                out.append("StageNavigation.placements \(focus.rawValue) differs for row \(pidByKey[key] ?? "a row no model holds")")
            }
        }
        for (model, fact) in zip(models, facts) {
            let pid = String(describing: model.persistentModelID)
            if StageMembers(model, context: context) != StageMembers(fact, context: context) {
                out.append("stage members differ for row \(pid)")
            }
            let modelAudience = model.greetingAudienceSize(among: model.recipients)
            let factAudience = fact.greetingAudienceSize(among: fact.factContacts)
            let factByID = Dictionary(fact.factContacts.map { ($0.persistentModelID, $0) },
                                      uniquingKeysWith: { first, _ in first })
            for contact in model.recipients {
                guard let record = factByID[contact.persistentModelID] else { continue }
                if StageContactMembers(contact, body: model.draftBody, audience: modelAudience, now: context.now)
                    != StageContactMembers(record, body: fact.draftBody, audience: factAudience, now: context.now) {
                    out.append("stage contact members differ for contact \(String(describing: contact.persistentModelID))")
                }
            }
        }
        if context.resolvingPlaces(of: models).geo.resolvedPlaceCount
            != context.resolvingPlaces(of: facts).geo.resolvedPlaceCount {
            out.append("StageContext.resolvingPlaces resolved a different number of places")
        }
        return out
    }

    // MARK: slice D1, the members on the facts protocols

    /// Every computed show member slice D1 moved onto `ProspectFacts`, read through the protocol, which is how
    /// a generic term reads them. On a `Prospect` this deliberately reaches the protocol's body rather than
    /// any same-named member the model keeps for its setter, so the comparison is of the one rule.
    struct ShowMembers: Equatable {
        let status: ReviewStatus
        let showOutcome: ShowOutcome?
        let outcome: Outcome
        let performanceStatus: PerformanceStatus
        let isBooked: Bool
        let stoodDownBeforeAnyReply: Bool
        // Whether a reply after the stand-down puts the show back in play, which is the rule's other arm.
        let reopenedByALaterReply: Bool

        init(_ p: some ProspectFacts) {
            status = p.status
            showOutcome = p.showOutcome
            outcome = p.outcome
            performanceStatus = p.performanceStatus
            isBooked = p.isBooked
            stoodDownBeforeAnyReply = p.isOutreachStoodDown(asOf: nil)
            reopenedByALaterReply = p.outreachStoodDownAt.map { !p.isOutreachStoodDown(asOf: $0.addingTimeInterval(1)) } ?? false
        }
    }

    /// The same for every computed contact member slice D1 moved onto `ContactFacts`.
    struct ContactMembers: Equatable {
        let sendState: SendState
        let resolution: RecipientResolution?
        let outcomeSource: OutcomeSource?
        let outreachChannel: OutreachChannel
        let hasWatchableConversation: Bool
        let isUnwatchedFormPitch: Bool
        let hasProvenOutreach: Bool
        let isSilent: Bool
        let replyWatchConversationIsAttached: Bool
        let isAwaitingFollowUp: Bool
        let replyArrivedAt: Date?
        let hasUnhandledReply: Bool
        let standing: RecipientStanding
        let isOutreachStoodDown: Bool
        let isClosingNoteStoodDown: Bool
        // Slice F: the two reply draft members `StalledReplyDraft` reads. Stalled is asked at the end of time,
        // where it is true exactly when a draft is awaited; the fixture holds the timeout itself.
        let awaitedReplyDraftRequestedAt: Date?
        let stalledAtTheEndOfTime: Bool

        init(_ c: some ContactFacts) {
            sendState = c.sendState
            resolution = c.resolution
            outcomeSource = c.outcomeSource
            outreachChannel = c.outreachChannel
            hasWatchableConversation = c.hasWatchableConversation
            isUnwatchedFormPitch = c.isUnwatchedFormPitch
            hasProvenOutreach = c.hasProvenOutreach
            isSilent = c.isSilent
            replyWatchConversationIsAttached = c.replyWatchConversationIsAttached
            isAwaitingFollowUp = c.isAwaitingFollowUp
            replyArrivedAt = c.replyArrivedAt
            hasUnhandledReply = c.hasUnhandledReply
            standing = c.standing
            isOutreachStoodDown = c.isOutreachStoodDown
            isClosingNoteStoodDown = c.isClosingNoteStoodDown
            awaitedReplyDraftRequestedAt = c.awaitedReplyDraftRequestedAt
            stalledAtTheEndOfTime = c.isReplyDraftStalled(now: .distantFuture)
        }

        /// The names of the members that differ, so a finding says which rule disagreed.
        func differing(from other: ContactMembers) -> [String] {
            Mirror(reflecting: self).children.compactMap { child in
                guard let label = child.label,
                      let theirs = Mirror(reflecting: other).children.first(where: { $0.label == label })
                else { return nil }
                return String(describing: child.value) == String(describing: theirs.value) ? nil : label
            }
        }
    }

    /// Each show's members and each of its contacts' members, models against facts. Contacts are paired by
    /// their persistent identifier, and findings name identifiers only (L222).
    static func memberFindings(_ models: [Prospect], _ facts: [RowFacts]) -> [String] {
        var out: [String] = []
        for (model, fact) in zip(models, facts) {
            let pid = String(describing: model.persistentModelID)
            if ShowMembers(model) != ShowMembers(fact) {
                out.append("show members differ for row \(pid)")
            }
            let factByID = Dictionary(fact.factContacts.map { ($0.persistentModelID, $0) },
                                      uniquingKeysWith: { first, _ in first })
            for contact in model.factContacts {
                let cid = String(describing: contact.persistentModelID)
                guard let record = factByID[contact.persistentModelID] else {
                    out.append("contact \(cid) of row \(pid) has no extracted record")
                    continue
                }
                let names = ContactMembers(contact).differing(from: ContactMembers(record))
                if !names.isEmpty {
                    out.append("contact members \(names.joined(separator: ", ")) differ for contact \(cid)")
                }
            }
        }
        return out
    }

    /// Two sets of producer tables compared, naming every row whose presenter the two answer differently
    /// about: its venue count, whether it is a venue's own brand, whether it is spelled like a room. The
    /// row's identifier only, never the presenter's name, which is a real organisation on the live store.
    /// Shared with oracle part one, which asks the same of an old and a new build.
    static func tableFindings(_ left: QueueModel.ProducerTables, _ right: QueueModel.ProducerTables,
                              rows: [Prospect], term: String, pid: (String) -> String) -> [String] {
        var out: [String] = []
        for row in rows {
            guard let presenter = row.presenter else { continue }
            if let key = ProducerGate.key(presenter),
               left.corpus.distinctVenueCount(key) != right.corpus.distinctVenueCount(key) {
                out.append("\(term).corpus venue count differs for row \(pid(row.naturalKey))")
            }
            if left.venueBrands.contains(presenter) != right.venueBrands.contains(presenter) {
                out.append("\(term).venueBrands differs for row \(pid(row.naturalKey))")
            }
            if left.venueBrands.isRoomName(presenter) != right.venueBrands.isRoomName(presenter) {
                out.append("\(term).venueBrands room name differs for row \(pid(row.naturalKey))")
            }
        }
        // The whole values too, so a difference on a presenter no row of `rows` carries is still seen.
        if out.isEmpty, left.corpus != right.corpus { out.append("\(term).corpus differs") }
        if out.isEmpty, left.venueBrands != right.venueBrands { out.append("\(term).venueBrands differs") }
        return out
    }

    /// Two inherited answer tables compared show by show, naming the show by its identifier.
    static func inheritedFindings(_ left: [String: OrgAnswerLedger.Inherited],
                                  _ right: [String: OrgAnswerLedger.Inherited], term: String,
                                  pid: (String) -> String) -> [String] {
        Set(left.keys).union(right.keys).sorted().compactMap { key in
            left[key] == right[key] ? nil : "\(term) differs for row \(pid(key))"
        }
    }

    /// Two event lists compared field by field, naming the field and the event's first member by its
    /// identifier. Shared with oracle part one, which asks the same of an old and a new term.
    static func eventFindings(_ left: [FeedBreakEvent.Event], _ right: [FeedBreakEvent.Event], term: String,
                              pid: (String) -> String) -> [String] {
        guard left.count == right.count else {
            return ["\(term) returned \(left.count) event(s) one way and \(right.count) the other"]
        }
        var out: [String] = []
        for (index, (a, b)) in zip(left, right).enumerated() {
            let at = "\(term) event \(index) (first member \(pid(a.memberKeys.first ?? "")))"
            if a.venue != b.venue { out.append("\(at): venue differs") }
            if a.missedScoutCount != b.missedScoutCount { out.append("\(at): missedScoutCount differs") }
            if a.memberKeys != b.memberKeys { out.append("\(at): memberKeys differs") }
            if a.coveredByAnotherCard != b.coveredByAnotherCard { out.append("\(at): coveredByAnotherCard differs") }
        }
        return out
    }
}
