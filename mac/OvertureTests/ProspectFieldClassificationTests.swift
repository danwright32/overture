import Testing
import Foundation

// #2433, the other half of #2009, which built this guard for `Recipient.wasWrittenTo` and left this one
// explicitly not done rather than half done.
//
// `NaturalKeyVenueMigration.hasRecordBeyondADismissal` decides whether a duplicate PROSPECT row may be
// deleted at launch. Like `wasWrittenTo`, it is a hand-written list of the fields that mean "this row
// holds something real", and it can only name what existed when it was written. `Prospect` gains fields
// regularly, and the day somebody adds one recording Dan's work without adding it here, a duplicate
// holding that work becomes deletable and the next launch deletes it. Nothing fails and nothing warns.
//
// WHY IT WAS SCALE RATHER THAN DOUBT: `Prospect` carries 128 stored properties against `Recipient`'s
// ~60. The machinery is shared and was already built; the burden is the judgment, per field.
//
// WHAT THE MERGE ACTUALLY DOES, which is what makes the judgment decidable. There is no field level
// merge: `NaturalKeyVenueMigration` picks ONE survivor and calls `context.delete` on every other member,
// so whatever only a loser knew is gone (L5). Three things stand between a row and that delete, and they
// ask different questions:
//
//   `mustDefer`                    two or more rows carrying history means nothing is merged at all
//   `hasOutreachHistory`           has ANYTHING happened here (it also counts `status != .new` and
//                                  `showOutcomeRaw`, so a row that has moved off new is protected by it)
//   `hasRecordBeyondADismissal`    did this row reach the outside world, which is what picks the survivor
//
// So this guard is about the third. A field belongs in the rule when it can be the ONLY evidence that a
// row reached the world; a field whose presence guarantees a counted field is beside it is a COMPANION
// and costs nothing to leave out. Both readings are recorded per field below, because "companion" is a
// claim about another field and is exactly the kind of thing that quietly stops being true.
@Suite("Every Prospect field is classified for the merge (#2433)")
struct ProspectFieldClassificationTests {

    // Read out of the rule's own body rather than restated, so this guard cannot drift from the rule it
    // guards (L41): a field removed from the function moves into this test's failure list rather than
    // being quietly still believed.
    private var migrationSource: String {
        SourceGuardHelper.source("Overture/Domain/NaturalKeyVenueMigration.swift")
    }
    private var prospectSource: String { SourceGuardHelper.source("Overture/Domain/Prospect.swift") }

    // Every stored property that is NOT evidence this row reached the outside world, each with the reason.
    static let notARecord: [String: String] = [
        // MARK: identity and the listing itself, all of it re-derivable by reading the page again
        "naturalKey": "the row's identity, which the merge is rewriting",
        "groupName": "the show's name as the scout last read it",
        "presenter": "who the listing bills, rewritten on every re-read",
        "presenterSource": "which writer that presenter came from, a fact about the read",
        "presenterWasTheRoom": "that the run reported the room rather than a name, a fact about the read",
        "location": "where the page said the show is, verbatim and re-readable",
        "discipline": "what the classifier made of it",
        "venue": "the room, as the listing gives it",
        "performanceDate": "the date, from the listing",
        "sourceListingURL": "the page this row was read off",
        "websiteURL": "a site the read found",
        "priorRelationship": "what the matcher made of the name, recomputed from the booking history",
        "production": "the classifier's answer",
        "profile": "the classifier's answer",
        "coverage": "the classifier's answer",
        "fitScore": "the ranker's answer, recomputed whenever its inputs move",
        "tier": "the ranker's answer",
        "fitReason": "the ranker explaining itself",
        "matchedClientName": "which client the matcher matched, recomputed from the booking history",
        "possibleMatchSource": "how the matcher got there",
        "possibleMatchName": "who the matcher thought it might be",
        "scoutGroupName": "the name the scout last emitted, kept current on purpose",
        "scoutVenue": "the room the scout last emitted",
        "sourceIds": "which watched sources have listed this show",
        "seriesId": "which run of nights this belongs to, derived by the scout",
        "ingestedAt": "when the scout last read it, rewritten every run",
        "firstSeenAt": "when it first arrived; carried onto the survivor before any delete, deliberately",
        "missedScoutCount": "how many runs did not list it, a fact about the feed",

        // MARK: the run's own shape, all re-read from the listing every time
        "runEndDate": "the last night of the run, from the listing",
        "partOfRelatedRun": "that this night belongs to a run, derived by the scout",
        "runSourceURLs": "the pages the run's nights were read off",
        "runNights": "the nights the listing gives",
        "droppedRunNights": "nights the scout dropped, recomputed on the next read",
        "performanceStartTimes": "start times from the listing",
        "startTimesVary": "derived from the times above",
        "nightStartTimes": "start times per night, from the listing",
        "disciplineGenreSourceKey": "which rule decided the genre, a fact about the classifier",
        "producerAxisSourceKey": "which rule decided the producer axis, a fact about the classifier",
        "showSummary": "what the AI read off the page, re-readable by reading it again",
        "showSummaryAbsentReasonRaw": "why there was no summary, a fact about that read",

        // MARK: the dismissal itself, which this rule is deliberately BEYOND
        // The function's name is the classification: #1780 split it out precisely so a bare dismissal
        // would stop wedging two refused duplicates into the deferred branch forever. A dismissal is a
        // decision, recoverable, and it is carried onto the survivor.
        "statusRaw": "the stage, and a dismissal is what this rule is explicitly beyond",
        "dismissReasonRaw": "the legacy dismissal reason, read only by ShowOutcomeBackfill now",
        "dismissedAt": "when the row left the queue, the dismissal's own date",
        "showOutcomeRaw": "how the show ended; counted by `hasOutreachHistory`, which is the predicate that asks whether anything happened at all",
        // #2915: WHEN that ending was recorded. Beside the ending itself rather than in `notARecord`,
        // because the two are one fact: a row carrying the ending already survives this rule through
        // `showOutcomeRaw`, and a merge that kept the ending and dropped its date would leave a survivor
        // whose ending can never be compared against a later reply, so the reopen rule would refuse it
        // for ever. Carried for the same reason `dismissedAt` is.
        "showOutcomeAt": "when the show was closed out; the ending's own date, and what a later reply is compared against (#2915)",

        // MARK: a paid check's answer. Re-derivable only by paying again, and that is the whole of why
        // #1845 took found addresses OUT of the deferral half of this rule: an address a check merely
        // found was wedging three shows into the queue twice, permanently, on nine rows not one of which
        // had ever been sent anything. The cost of leaving these out is a re-check; the cost of counting
        // them was measured and was permanent duplicates.
        "reachabilityProbedAt": "when a paid check last ran, which is a found answer rather than a send",
        "reachabilityRecheckRequestedAt": "Dan asking for another check, an instruction rather than a record of one",
        "reachabilityResultRaw": "what the paid check concluded, the same class as a found address",
        "reachabilityEmptyReasonRaw": "why the check came back empty, a fact about that check",
        "reachabilityUnansweredAt": "that a check never reached this show, a fact about the run",
        "fitScoreBeforeContactCheck": "the score before the check moved it, kept for retuning",
        "contactRouteAtScore": "which route was found at that score",
        "contactTierAtScore": "who was found at that score",

        // MARK: frozen copies of ranking features. Every one of them exists only on a row that was SENT,
        // and `sentAt` is counted, so each is a companion.
        "fitScoreAtSend": "frozen at the first send, so `sentAt` is beside it",
        "tierAtSend": "frozen at the first send, so `sentAt` is beside it",
        "profileAtSend": "frozen at the first send, so `sentAt` is beside it",
        "coverageAtSend": "frozen at the first send, so `sentAt` is beside it",
        "disciplineAtSend": "frozen at the first send, so `sentAt` is beside it",
        "productionAtSend": "frozen at the first send, so `sentAt` is beside it",
        "priorRelationshipAtSend": "frozen at the first send, so `sentAt` is beside it",

        // MARK: the draft, and everything that qualifies one. `draftBody` and `draftSubject` are counted,
        // and none of these can exist without a draft.
        "draftVariant": "which variant the drafter used, so a draft is beside it",
        "draftWrittenByDan": "that Dan wrote the draft himself, so a draft is beside it",
        "draftModel": "which model wrote the draft, so a draft is beside it",
        "experimentID": "which A/B experiment the draft belongs to, so a draft is beside it",
        "assignedArm": "which arm the draft was written for, so a draft is beside it",
        "experimentOpenerEdited": "that Dan edited the opener, so a draft is beside it",
        "draftNeedsSalutationReview": "a hold on a draft, so a draft is beside it",
        "draftSalutationReviewOverriddenBody": "the draft that hold was waved off on, so a draft is beside it",
        "jointOpeningOverride": "Dan's chosen opening for a joint draft, so a draft is beside it",
        "sendsTogetherOverride": "Dan's choice to send two contacts together, an instruction about a draft",
        "originalDraftSubject": "what the drafter wrote before Dan edited it, so a draft is beside it",
        "originalDraftBody": "what the drafter wrote before Dan edited it, so a draft is beside it",
        "heldBackAt": "that a run left this row out, a fact about the run rather than about the world",
        "heldBackBySlot": "which slot left it out, a fact about the run",
        "reprepLastServedAt": "when a re-prep was served, so a re-prep request is beside it",
        "reprepHandedToRun": "which run took the re-prep, so a re-prep request is beside it",

        // MARK: the send and what came back. `sentAt`, `gmailThreadId` and `gmailMessageId` are counted,
        // and none of these exists without one of them.
        "sentSubject": "the subject that went out, so `sentAt` is beside it",
        "sentBody": "the body that went out, so `sentAt` is beside it",
        "sendError": "why a send failed; a failed send wrote no `sentAt`, and the row still holds the draft that is counted",
        "excludedFromVoiceLearning": "Dan marking a SEND as a poor example, so `sentAt` is beside it",
        "outcomeSourceRaw": "where the outcome came from, so a non-default `outcomeRaw` is beside it",
        "outcomeAt": "when the outcome landed, so a non-default `outcomeRaw` is beside it",
        "lostReason": "why it was lost, so a non-default `outcomeRaw` is beside it",
        "followUpCount": "how many nudges went out, so `sentAt` is beside it",
        "lastFollowUpAt": "when the last nudge went out, so `sentAt` is beside it",
        "lastReplyText": "what came back, which only happens after a send",
        "lastReplyAt": "when it came back, which only happens after a send",
        "lastReplyId": "the message that came back, which only happens after a send",
        "dismissedReplyId": "Dan waving a reply off, which only happens after a reply",

        // MARK: booking reconciliation, which is Downbeat's record rather than this row's
        "downbeatClientId": "which Downbeat client this matched, recomputed from the export",
        "bookingSuggested": "that a booking looks like this show, recomputed from the export",
        "alreadyCoveredNote": "that Dan has shot this already, recomputed from the history",
        "autoBookedFromBookingId": "which booking claimed it, recomputed from the export",
        "autoBookingRejectedWithoutId": "a rejection with no id to key on, so `bookingSuggestionDismissed` is beside it",

        // MARK: the performer match, whose two Dan-facing answers are counted
        "relationshipCorrectedByPerformerMatch": "that the match moved the relationship, recomputed by the matcher",
        "matchedPerformerName": "who the matcher matched, recomputed by the matcher",
        "performerMatchNote": "the matcher explaining itself",
        "performerMatchPreviousRelationship": "undo state for the match, so a reviewed or dismissed match is beside it",
        "performerMatchPreviousFitScore": "undo state for the match, so a reviewed or dismissed match is beside it",
        "performerMatchPreviousTier": "undo state for the match, so a reviewed or dismissed match is beside it",
        "performerMatchPreviousMatchedClientName": "undo state for the match, so a reviewed or dismissed match is beside it",
        "performerMatchPreviousDownbeatClientId": "undo state for the match, so a reviewed or dismissed match is beside it",

        // MARK: the calendar clash, recomputed on every reconcile tick
        "conflictKey": "the night that clashes, recomputed from the calendar",
        "conflictOpen": "whether the clash is still open, recomputed from the calendar",

        // MARK: three that LOOK like decisions of Dan's and were each checked against their writer
        // before being classified, because "a decision" and "a fact derived from his history" are
        // indistinguishable from the field name alone.
        "passedOnThisShow": "NOT a decision recorded here: `HistoryMatch` derives it from the confident booking history and `ScoutService.apply` copies it onto the row, so every re-scout reproduces it",
        "outreachStoodDownAt": "Dan stopping the nudges on a show, and `ProspectMutations.standDown` writes `showOutcome = .turnedThemDown` in the same breath, which `hasOutreachHistory` counts (see #3124 for the survivor rule, which sees neither)",
        "rejectedBookingIdsRaw": "Dan rejecting one booking match, and `rejectAutoBooking` sets `bookingSuggestionDismissed` in the same call, which the rule counts",

        // MARK: retained storage, read by nothing (#1533)
        "classificationConfidence": "retained storage that nothing writes or reads since #1533",
    ]

    // Fields that record a DECISION OF DAN'S and are not evidence he reached the world. They are listed
    // separately from everything above because they are the ones this guard exists to keep visible: each
    // can be the only thing a row holds, and none of them is counted by the rule.
    //
    // They are NOT simply added to `hasRecordBeyondADismissal`, and the reason is #1780. That predicate's
    // other job is deciding a DEFERRAL, where it is asked "did this reach the outside world"; teaching it
    // to answer yes to a rename would make two renamed duplicates defer forever, which is the exact
    // deadlock #1780 was filed to remove. Where they belong is the survivor rule, and that is #3124.
    static let danDecisionsTheRuleCannotSee: [String: String] = [
        "keptVisibleAfterGenreChange": "written by GenreVisibility and nothing else, on a row that was showing when a genre change would have hidden it; that transition exists nowhere else once the row is gone",
        "groupNameOverriddenByDan": "Dan renamed the show. The rename writes only this, `groupName` and `scoutGroupName`, none of which the rule counts, and the scout never reproduces his name",
    ]

    private var classified: [String: String] {
        Self.notARecord.merging(Self.danDecisionsTheRuleCannotSee) { a, _ in a }
    }

    // The model's initializer takes every scout-derived field, so a row is built through one helper here
    // rather than repeated. Nothing it sets is counted by the rule under test, which is the point: the
    // row it makes is pristine.
    private func makeProspect(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: "Vienna Philharmonic", discipline: "music",
                 venue: "Stern Auditorium", performanceDate: "2026-11-14",
                 sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                 production: "self", profile: "strong", coverage: "likely_uncovered",
                 fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                 possibleMatchSource: nil, possibleMatchName: nil)
    }

    @Test func everyStoredFieldIsEitherCountedOrClassified() throws {
        let rule = try #require(
            SourceGuardHelper.bodyOfFunction(named: "hasRecordBeyondADismissal", in: migrationSource),
            "hasRecordBeyondADismissal could not be found: it is what this guard measures")

        let classBody = try #require(SourceGuardHelper.propertyBody("final class Prospect {",
                                                                     in: prospectSource))
        let stored = SourceGuardHelper.storedPropertyNames(inClassBody: classBody)
        #expect(stored.count > 100, "found \(stored.count) stored properties, which is a broken read")

        let unclassified = stored.filter { name in
            if classified.keys.contains(name) { return false }
            let asRead = name.hasSuffix("Raw") ? String(name.dropLast(3)) : name
            return !rule.contains(name) && !rule.contains(asRead)
        }

        #expect(unclassified.isEmpty, """
            \(unclassified.joined(separator: ", ")): neither counted by \
            `NaturalKeyVenueMigration.hasRecordBeyondADismissal` nor listed above. Decide whether the \
            field can be the ONLY evidence that this row reached the outside world, then add it to the \
            rule, or to `notARecord` with the reason, or to `danDecisionsTheRuleCannotSee` if it records \
            something of Dan's that no re-scout reproduces. Getting this wrong deletes his work on the \
            next launch's merge, silently and permanently, so the cheap direction is to classify as a \
            record.
            """)
    }

    // #3124: every field on that list must have a CARRY RULE, so a decision of Dan's is moved onto the
    // survivor instead of being deleted with the row that held it.
    //
    // Derived from the list rather than written out again beside it: a hand-written second copy only ever
    // checks what somebody remembered, and this is exactly the pairing that rots (L96, L41). Adding a
    // field to `danDecisionsTheRuleCannotSee` and nothing else now fails here, naming the field.
    @Test func everyDecisionOfDansIsCarriedOntoTheSurvivor() throws {
        let carry = try #require(
            SourceGuardHelper.bodyOfFunction(named: "carryDansDecisions", in: migrationSource),
            "carryDansDecisions could not be found: it is what moves a decision onto the survivor (#3124)")

        let uncarried = Self.danDecisionsTheRuleCannotSee.keys.filter { !carry.contains($0) }

        #expect(uncarried.isEmpty, """
            \(uncarried.sorted().joined(separator: ", ")): listed as a decision of Dan's that the \
            survivor rule cannot see, but `NaturalKeyVenueMigration.carryDansDecisions` does not name \
            it, so the launch merge still deletes it with whichever duplicate row happened to hold it. \
            Give it a carry rule, and say what carrying it MEANS when more than one member has one.
            """)
    }

    // The list must not rot the other way either: an entry for a field that has gone is a note about code
    // that no longer exists, and a real one could hide behind it.
    @Test func nothingIsListedThatIsNoLongerAField() throws {
        let classBody = try #require(SourceGuardHelper.propertyBody("final class Prospect {",
                                                                     in: prospectSource))
        let stored = Set(SourceGuardHelper.storedPropertyNames(inClassBody: classBody))
        let gone = classified.keys.filter { !stored.contains($0) }.sorted()
        #expect(gone.isEmpty, "these are listed but are no longer fields: \(gone.joined(separator: ", "))")
    }

    @Test func everyEntryCarriesItsReason() {
        for (field, reason) in classified {
            #expect(reason.count > 10, "\(field) is listed with no real reason: \"\(reason)\"")
        }
    }

    // Seen to fail (L1). A guard over a hand-written list is worth nothing until a new field has been
    // watched to trip it, and this is the exact shape the issue is about.
    @Test func aNewFieldTheRuleWasNeverTaughtIsReported() throws {
        let classBody = try #require(SourceGuardHelper.propertyBody("final class Prospect {",
                                                                     in: prospectSource))
        let withNewField = classBody + "\n    var danChangedHisMindAt: Date? = nil\n"
        let stored = SourceGuardHelper.storedPropertyNames(inClassBody: withNewField)

        #expect(stored.contains("danChangedHisMindAt"))
        #expect(!classified.keys.contains("danChangedHisMindAt"))
        #expect(!prospectSource.contains("danChangedHisMindAt"),
                "the fixture name must not exist for real, or this proves nothing")
    }

    // A local inside one of the model's own methods is not a stored property, and before #2433 it arrived
    // as one. `Prospect` really does declare `var s`, `var i`, `var result`, `var decoded` and `var ids`
    // inside its helpers, so without this the list above would have had to carry five entries explaining
    // that a loop counter is not a record.
    @Test func aLocalInsideAMethodIsNotAStoredProperty() throws {
        let classBody = try #require(SourceGuardHelper.propertyBody("final class Prospect {",
                                                                     in: prospectSource))
        let stored = Set(SourceGuardHelper.storedPropertyNames(inClassBody: classBody))
        for local in ["s", "i", "result", "decoded", "ids"] {
            #expect(!stored.contains(local), "\(local) is a local in a method, not a stored property")
        }
        // And the rule did not throw the real ones out with them.
        for field in ["naturalKey", "groupName", "sentAt", "showOutcomeRaw"] {
            #expect(stored.contains(field), "\(field) is a stored property and must still be seen")
        }
    }

    // The rule's own reason for existing, restated so it cannot be lost in a refactor: a row nothing has
    // happened to is deletable, and one that reached the world is not.
    @Test func aPristineRowIsDeletableAndASentOneIsNot() {
        let pristine = makeProspect("k1")
        #expect(!NaturalKeyVenueMigration.hasRecordBeyondADismissal(pristine))

        let sent = makeProspect("k2")
        sent.sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(NaturalKeyVenueMigration.hasRecordBeyondADismissal(sent))
    }

    // And the finding this guard was built to make permanent (#3124): each of these is something no
    // re-scout reproduces, on a row the merge would treat as pristine. Asserted rather than described, so
    // the day one of them starts being counted this test says so and the list above is corrected.
    //
    // Written out one at a time rather than driven from a table of closures: a `static let` of closures
    // is not Sendable, and the point of each case is legible enough without one.
    @Test func keptVisibleAfterAGenreChangeAloneLeavesTheRowLookingPristine() {
        let row = makeProspect("k-genre")
        row.keptVisibleAfterGenreChange = true
        #expect(!NaturalKeyVenueMigration.hasRecordBeyondADismissal(row))
        #expect(!NaturalKeyVenueMigration.hasOutreachHistory(row))
    }

    @Test func aRenameOfDansAloneLeavesTheRowLookingPristine() {
        let row = makeProspect("k-rename")
        row.scoutGroupName = row.groupName
        row.groupName = "The name Dan gave it"
        row.groupNameOverriddenByDan = true
        #expect(!NaturalKeyVenueMigration.hasRecordBeyondADismissal(row))
        #expect(!NaturalKeyVenueMigration.hasOutreachHistory(row))
    }

    // The three that were CHECKED and are not this defect, asserted so the check does not have to be
    // repeated by the next person reading the list.
    @Test func theThreeThatLookLikeDecisionsAreCoveredByTheirCompanions() {
        // `standDown(scope: .show)` writes the ending in the same call, and `hasOutreachHistory` counts it.
        let stoodDown = makeProspect("k-stood-down")
        stoodDown.standDownOutreach(now: Date(timeIntervalSince1970: 1_780_000_000))
        stoodDown.showOutcome = .turnedThemDown
        #expect(NaturalKeyVenueMigration.hasOutreachHistory(stoodDown))

        // `rejectAutoBooking` sets `bookingSuggestionDismissed`, which the rule itself counts.
        let rejected = makeProspect("k-rejected")
        rejected.rejectAutoBooking(bookingId: "b1", now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(NaturalKeyVenueMigration.hasRecordBeyondADismissal(rejected))

        // `passedOnThisShow` is derived by the matcher from the booking history, so a re-scout writes it
        // again. Nothing to protect, and it is listed as not a record for that reason rather than this one.
        let passed = makeProspect("k-passed")
        passed.passedOnThisShow = true
        #expect(!NaturalKeyVenueMigration.hasRecordBeyondADismissal(passed))
    }
}
