import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The slice G2 card as it stood at bd1517dc
// (QueueItem.init(_:sendGroups:contacts:), RecipientSnapshot.init(_:lintBlockers:), SendGroup.CardGroups and
// previewGroup with Recipient.isSendablePending(today:), FormPitch.state(of:), Recipient.inSendOrder,
// holdReason, and the show and contact members the card reads), copied verbatim bar names, comments and the
// receiver, run against the generic card through its model entry points over ONE frozen snapshot of the live
// clone and its fourfold copy. Its output is pasted into the PR, and then this file is deleted in the same PR
// (L613).
@MainActor
@Suite("Oracle part one for slice G2: the model only card against the generic one (#4357, temporary)")
final class OldAgainstNewCardTests {
    private let sandboxes = TemporarySandboxes()

    struct OldGroups {
        let preview: [Recipient]
        let pending: [Recipient]
        var hasPending: Bool { !preview.isEmpty }
    }

    enum Old {
        static func isHeldByAGuard(_ r: Recipient) -> Bool {
            r.email?.isEmpty == false
                && ((r.looksLikeVenue && !r.looksLikeVenueDismissed)
                    || (r.looksLikePressContact && !r.looksLikePressContactDismissed)
                    || (r.looksLikeDuplicateContact && !r.looksLikeDuplicateContactDismissed)
                    || r.isLooksLikeAnotherPersons)
        }

        static func holdReason(_ r: Recipient) -> Recipient.HoldReason? {
            guard isHeldByAGuard(r) else { return nil }
            if (r.looksLikeVenue && !r.looksLikeVenueDismissed)
                || (r.looksLikePressContact && !r.looksLikePressContactDismissed) { return .venueOrPress }
            if r.looksLikeDuplicateContact && !r.looksLikeDuplicateContactDismissed { return .duplicate }
            return .unaccountedAddress
        }

        static func replyPostdatesDraftRequest(_ r: Recipient) -> Bool {
            guard let requested = r.replyDraftRequestedAt, let theirs = r.replyArrivedAt else { return false }
            return theirs > requested
        }

        static func conflictNote(_ p: Prospect) -> String? {
            guard let day = p.conflictKey.flatMap({ BlockedCalendar.Day(key: $0) }) else { return nil }
            let scope = ConflictScope.of(blockedDate: p.conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.date,
                                         performanceDate: p.performanceDate)
            return day.reason(scope: scope ?? .thisNight)
        }

        static func sendOrderRank(_ r: Recipient) -> Int {
            switch RecipientProvenance(rawValue: r.provenanceRaw) ?? .manual {
            case .act, .performer: return 0
            case .presenter: return 1
            case .manual: return 2
            }
        }

        static func inSendOrder(_ recipients: [Recipient]) -> [Recipient] {
            recipients.sorted { a, b in
                if sendOrderRank(a) != sendOrderRank(b) { return sendOrderRank(a) < sendOrderRank(b) }
                if (a.email?.isEmpty == false) != (b.email?.isEmpty == false) { return a.email?.isEmpty == false }
                return a.id < b.id
            }
        }

        static func isSendablePending(_ r: Recipient, today: String) -> Bool {
            r.sendState == .pending && (r.email?.isEmpty == false) && !r.pausedByReply
                && !(r.prospect.map { EasternDate.lastNightHasPassed(performanceDate: $0.performanceDate,
                                                                      runEndDate: $0.runEndDate,
                                                                      today: today) } ?? false)
                && r.prospect?.conflictOpen != true
                && r.prospect.map { $0.draftBody != nil && ($0.draftSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } != true
                && !(r.looksLikeVenue && !r.looksLikeVenueDismissed)
                && !(r.looksLikePressContact && !r.looksLikePressContactDismissed)
                && !(r.looksLikeDuplicateContact && !r.looksLikeDuplicateContactDismissed)
                && !r.isLooksLikeAnotherPersons
                && !r.isBlockedByDraftLint
                && !r.isBlockedByGreeting
        }

        static func groups(of prospect: Prospect, today: String) -> OldGroups {
            let sendable = inSendOrder(prospect.recipients.filter { isSendablePending($0, today: today) })
            let preview = prospect.sendsTogether ? sendable : Array(sendable.prefix(1))
            let pending = (prospect.status == .approved && prospect.draftBody != nil) ? preview : []
            return OldGroups(preview: preview, pending: pending)
        }

        static func formPitchState(of prospect: Prospect) -> FormPitch.State {
            if let recorded = prospect.recipients.compactMap(\.formOutreachRecordedAt).min() {
                return .recorded(at: recorded)
            }
            let verdict = prospect.reachabilityResultFromRecipients
            guard verdict == .contactFormOnly || verdict == .socialOnly else { return .unavailable }
            let routes = prospect.usableContactFormURLs + prospect.socialRouteURLs
            let candidates = inSendOrder(
                prospect.recipients.filter { r in
                    guard let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                    return routes.contains(raw)
                })
            guard let target = candidates.first,
                  let formURL = target.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .unavailable
            }
            guard let startedAt = target.formOutreachStartedAt else {
                return .ready(recipientId: target.id, formURL: formURL)
            }
            return .awaitingConfirmation(recipientId: target.id, formURL: formURL, startedAt: startedAt)
        }

        static func item(_ p: Prospect, sendGroups: OldGroups, contacts: [Recipient]? = nil) -> QueueItem {
            let voiceLearningCandidate = p.sentAt != nil && p.originalDraftBody != nil
            let nextRecipientIds = sendGroups.pending.map(\.id)
            let contactsOnce = contacts ?? p.countedRecipients
            let weakContactHoldReason = contactsOnce.compactMap(holdReason).first
            let formPitch = formPitchState(of: p)
            let draftGreetedContactName = contactsOnce.first { $0.sendState == .pending && $0.greetingNamesSomeoneElse }?.name
            let conflictBlockedDate = p.conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.date
            let draftGreetedName = contactsOnce
                .first { $0.sendState == .pending && $0.greetingNamesSomeoneElse }
                .flatMap { DraftGreeting.greetedName($0.effectiveBody) }
            let pendingRecipients = contactsOnce.filter { $0.sendState == .pending }
            let lintBlockersByRecipient = Dictionary(uniqueKeysWithValues:
                pendingRecipients.map { ($0.id, $0.draftLintBlockers) })
            func lintBlockers(_ r: Recipient) -> [DraftIssue] {
                lintBlockersByRecipient[r.id] ?? r.draftLintBlockers
            }
            let draftLintBlockers = DraftIssue.orderedBlockers(
                Set(pendingRecipients.flatMap { lintBlockers($0) }))
            let contacts = inSendOrder(contactsOnce)
                .map { snapshot($0, lintBlockers: lintBlockers($0)) }
            let offersSendModeChoice = contactsOnce.filter { $0.email?.isEmpty == false }.count > 1
            let hasWeakContactEmail = contactsOnce.contains(where: isHeldByAGuard)
            let hasAnyEmailContact = contactsOnce.contains { $0.email?.isEmpty == false }
            let draftMissingGreeting = contactsOnce.contains { $0.sendState == .pending && $0.draftIsMissingGreeting }
            let draftGreetingMisaddressed = contactsOnce.contains { $0.sendState == .pending && $0.greetingMisaddressed }
            let draftGreetingNamesSomeoneElse = contactsOnce.contains { $0.sendState == .pending && $0.greetingNamesSomeoneElse }
            let greetingOverridden = !contactsOnce.contains { $0.sendState == .pending && $0.isBlockedByGreeting }
            let draftLintBlocked = pendingRecipients.contains {
                $0.isBlockedByDraftLint(lintBlockers: lintBlockers($0))
            }

            return QueueItem(
                id: p.naturalKey,
                groupName: p.groupName,
                discipline: p.discipline,
                venue: p.venue,
                performanceDate: p.performanceDate,
                sourceListingURL: p.sourceListingURL,
                presenter: p.presenter,
                reachabilityProbedAt: p.reachabilityProbedAt,
                reachabilityRecheckRequestedAt: p.reachabilityRecheckRequestedAt,
                reachabilityResult: p.reachabilityResultAsHeld,
                reachabilityEmptyReason: p.reachabilityEmptyReasonRaw.flatMap(Reachability.EmptyReason.init(rawValue:)),
                reachabilityUnansweredAt: p.reachabilityUnansweredAt,
                location: p.location,
                priorRelationship: p.priorRelationship,
                production: p.production,
                profile: p.profile,
                coverage: p.coverage,
                passedOnThisShow: p.passedOnThisShow,
                fitScore: p.fitScore,
                tier: p.tier,
                fitReason: p.fitReason,
                matchedClientName: p.matchedClientName,
                possibleMatchSource: p.possibleMatchSource,
                possibleMatchName: p.possibleMatchName,
                status: p.status,
                showOutcome: p.showOutcome,
                draftSubject: p.draftSubject,
                draftBody: p.draftBody,
                draftEditedByDan: p.draftEditedByDan,
                draftWrittenByDan: p.draftWrittenByDan,
                draftModel: p.draftModel,
                outcome: p.outcome,
                performanceStatus: p.performanceStatus,
                sentAt: p.sentAt,
                voiceLearningCandidate: voiceLearningCandidate,
                excludedFromVoiceLearning: p.excludedFromVoiceLearning,
                hasPendingRecipient: sendGroups.hasPending,
                nextRecipientIds: nextRecipientIds,
                sendsTogether: p.sendsTogether,
                offersSendModeChoice: offersSendModeChoice,
                hasWeakContactEmail: hasWeakContactEmail,
                weakContactHoldReason: weakContactHoldReason,
                runSourceURLs: p.runSourceURLs,
                formPitch: formPitch,
                hasAnyEmailContact: hasAnyEmailContact,
                blockedContactCount: p.blockedContactCount(lintBlockers: lintBlockers),
                hasEnteredSendHalf: p.hasEnteredSendHalf,
                sendError: p.sendError,
                lostReason: p.lostReason,
                classificationOverriddenByDan: p.classificationOverriddenByDan,
                groupNameOverriddenByDan: p.groupNameOverriddenByDan,
                bookingSuggested: p.bookingSuggested,
                alreadyCoveredNote: p.alreadyCoveredNote,
                alreadyCoveredDismissed: p.alreadyCoveredDismissed,
                showSummary: p.showSummary,
                showSummaryAbsence: p.showSummaryAbsentReasonRaw.flatMap(ShowSummaryAbsence.init(rawValue:)),
                orgDoNotContact: p.orgDoNotContact,
                relationshipCorrectedByPerformerMatch: p.relationshipCorrectedByPerformerMatch,
                performerMatchNote: p.performerMatchNote,
                performerMatchDismissed: p.performerMatchDismissed,
                performerMatchReviewed: p.performerMatchReviewed,
                draftMissingGreeting: draftMissingGreeting,
                draftGreetingMisaddressed: draftGreetingMisaddressed,
                draftGreetingNamesSomeoneElse: draftGreetingNamesSomeoneElse,
                draftGreetedName: draftGreetedName,
                draftGreetedContactName: draftGreetedContactName,
                greetingAudienceSize: p.greetingAudienceSize,
                greetingOverridden: greetingOverridden,
                draftLintBlockers: draftLintBlockers,
                draftLintBlocked: draftLintBlocked,
                outcomeSourceRaw: p.outcomeSourceRaw,
                hasUnclearedConflict: p.conflictOpen,
                conflictNote: conflictNote(p),
                conflictBlockedDate: conflictBlockedDate,
                runEndDate: p.runEndDate,
                runNights: p.runNights,
                skippedNights: NightDecision.all(p.skippedRunNights).map(\.night),
                performanceStartTimes: p.performanceStartTimes,
                startTimesVary: p.startTimesVary,
                nightStartTimes: p.nightStartTimes,
                partOfRelatedRun: p.partOfRelatedRun,
                heldBackFrom: p.heldBackAt == nil ? nil : p.heldBackBySlot,
                disappearedFromFeed: p.disappearedFromFeed,
                contacts: contacts,
                reprepDraftRequested: p.reprepDraftRequested,
                reprepContactsRequested: p.reprepContactsRequested,
                reprepLastServedAt: p.reprepLastServedAt
            )
        }

        static func snapshot(_ r: Recipient, lintBlockers: @autoclosure () -> [DraftIssue]) -> RecipientSnapshot {
            RecipientSnapshot(id: r.id, name: r.name, email: r.email, role: r.role,
                      roleIsACharacterisation: r.roleIsACharacterisation,
                      provenance: RecipientProvenance(rawValue: r.provenanceRaw) ?? .manual, sendState: r.sendState, replied: r.replied,
                      lastReplyText: r.lastReplyText, resolution: r.resolution,
                      bounced: r.bounced, outcomeSource: r.outcomeSource,
                      suppressionReason: r.suppressionReasonRaw.flatMap(RecipientSuppressionReason.init) ?? .bookedElsewhere,
                      isHeldFromSending: r.isBlockedAwaitingReview(lintBlockers: lintBlockers()),
                      replyDraftBody: r.replyDraftBody,
                      replyDraftRequestedAt: r.replyDraftRequestedAt,
                      replyCopiedAt: r.replyCopiedAt,
                      awaitedReplyDraftRequestedAt: r.awaitedReplyDraftRequestedAt,
                      hasUnhandledReply: r.hasUnhandledReply,
                      replyPostdatesDraftRequest: replyPostdatesDraftRequest(r),
                      replyDraftReplacesDraftOnFile: r.replyDraftReplacesDraftOnFile,
                      replyIsAnswered: r.replied && !r.bounced && r.resolution == nil && r.replyHandledAt != nil && !r.hasUnhandledReply,
                      intentHint: r.intentHint,
                      replyDraftEditedByDan: r.replyDraftEditedByDan,
                      replyDraftWrittenByDan: r.replyDraftWrittenByDan,
                      replyAudience: SendGroup.replyAudience(of: r),
                      replyDraftModel: r.replyDraftModel,
                      conversationRemindedAt: r.conversationRemindedAt,
                outreachStoodDownAt: r.outreachStoodDownAt,
                      contactConfidence: r.contactConfidenceRaw.flatMap(ContactConfidence.init),
                      contactTier: r.contactTierRaw.flatMap(ContactTier.init(rawValue:)),
                      contactMethod: r.contactMethodRaw.flatMap(ContactMethod.init),
                      contactFormURL: r.contactFormURL,
                      nameMatchOnly: r.nameMatchOnly,
                      nameMatchOnlyDismissed: r.nameMatchOnlyDismissed,
                      contactSourceURL: r.contactSourceURL,
                      delayNoticeAt: r.delayNoticeAt,
                      looksLikeVenue: r.looksLikeVenue,
                      looksLikeVenueDismissed: r.looksLikeVenueDismissed,
                      looksLikePressContact: r.looksLikePressContact,
                      looksLikePressContactDismissed: r.looksLikePressContactDismissed,
                      looksLikeDuplicateContact: r.looksLikeDuplicateContact,
                      looksLikeDuplicateContactDismissed: r.looksLikeDuplicateContactDismissed,
                      looksLikeDuplicateContactKey: r.looksLikeDuplicateContactKey,
                      heldDownToUnverified: r.heldDownToUnverified,
                      heldDownToUnverifiedDismissed: r.heldDownToUnverifiedDismissed,
                      heldDownReason: r.heldDownReasonRaw.flatMap(ContactConfidenceGuard.HoldDown.init(rawValue:)),
                      looksLikeAnotherPersons: r.looksLikeAnotherPersons,
                      looksLikeAnotherPersonsDismissed: r.looksLikeAnotherPersonsDismissed)
        }

    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericCardAnswersAsTheModelOnlyOneDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-card")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let today = EasternDate.today(Date())
            for (label, url) in corpora {
                let rows = try ModelContext(try Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                var diff: [String] = []
                var withDraft = 0, withPending = 0, pitches = 0, contactsSeen = 0
                for p in rows {
                    let pid = String(describing: p.persistentModelID)
                    let contacts = p.countedRecipients
                    contactsSeen += contacts.count
                    let oldGroups = Old.groups(of: p, today: today)
                    let newGroups = SendGroup.CardGroups(of: p, today: today)
                    if oldGroups.preview.map(\.persistentModelID) != newGroups.preview.map(\.persistentModelID)
                        || oldGroups.pending.map(\.persistentModelID) != newGroups.pending.map(\.persistentModelID) {
                        diff.append("CardGroups differ for row \(pid)")
                    }
                    if !oldGroups.pending.isEmpty { withPending += 1 }
                    let oldPitch = Old.formPitchState(of: p)
                    if oldPitch != FormPitch.state(of: p) { diff.append("FormPitch.state differs for row \(pid)") }
                    if oldPitch != .unavailable { pitches += 1 }
                    if p.draftBody != nil { withDraft += 1 }
                    let old = Old.item(p, sendGroups: oldGroups, contacts: contacts)
                    let new = QueueItem(p, sendGroups: newGroups, contacts: contacts)
                    if old != new {
                        diff.append("QueueItem differs for row \(pid) in " + QueueModel.differingFieldNames(old, new).joined(separator: ", "))
                    }
                    if Old.item(p, sendGroups: oldGroups) != QueueItem(p, sendGroups: newGroups) {
                        diff.append("QueueItem with the contacts read by the card differs for row \(pid)")
                    }
                    for r in contacts where Old.isSendablePending(r, today: today) != r.isSendablePending(today: today)
                        || Old.holdReason(r) != r.holdReason {
                        diff.append("the contact's send gate or hold differs for contact \(r.persistentModelID)")
                    }
                }
                let oldT = Phase0.median5 {
                    for p in rows { _ = Old.item(p, sendGroups: Old.groups(of: p, today: today), contacts: p.recipients) }
                }
                let newT = Phase0.median5 {
                    for p in rows { _ = QueueItem(p, sendGroups: SendGroup.CardGroups(of: p, today: today), contacts: p.recipients) }
                }
                print("old against new, \(label): \(rows.count) row(s), \(contactsSeen) contact(s), \(withDraft) drafted, "
                      + "\(withPending) with a pending send group, \(pitches) with a form pitch state, \(diff.count) difference(s)")
                print("old against new, \(label): cards old \(oldT.text), new \(newT.text); load \(Phase0.load())")
                for line in diff.prefix(20) { print("old against new, \(label): " + line) }
                #expect(diff.isEmpty, Comment(rawValue: diff.prefix(20).joined(separator: "\n")))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
