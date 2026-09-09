import Testing
import Foundation

// #3655 Phase 5: what a search over a ROW can still find, and what it can no longer silently stop
// finding.
//
// Archive used to search a CARD, which carries the whole `RecipientSnapshot`. It now searches a
// `SearchableContact`, which carries two fields. That narrowing is the phase's saving and it is also the
// phase's one product risk: a field the search used to match and the new value does not carry would drop
// out with nothing reporting it, because a search that finds nothing and a search whose corpus lost a
// field render the same empty popover (L98).
//
// TWO GUARDS, and they answer different halves.
//
//   1. PARITY. What a row matches and what a card matches are the same answer, field by field, over the
//      same show. That is the "no matched field is lost" claim, checked against the thing it narrowed
//      FROM rather than against a list somebody wrote.
//   2. COVERAGE. Every stored property of `Recipient` is CLASSIFIED, so a contact field added later
//      cannot silently sit outside the search: it is in neither list, and this goes red until somebody
//      says which it is (L96). A hand-written list of what IS searched would only ever check what
//      somebody remembered; the list is derived from the model and the classification is what is
//      declared.
@Suite("Search over a row finds what search over a card found (#3655)")
struct SearchCoversEveryContactFieldTests {

    // MARK: - 1. Parity

    private func card(name: String?, email: String?, groupName: String = "Aurora Strings",
                      venue: String? = "Weill Recital Hall") -> QueueItem {
        var item = QueueItem(id: "k", groupName: groupName, discipline: "music", venue: venue,
                             performanceDate: "2026-08-01", sourceListingURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .new)
        item.contacts = [RecipientSnapshot(id: "r1", name: name, email: email, role: nil,
                                           provenance: .manual, sendState: .pending, replied: false,
                                           lastReplyText: nil, resolution: nil, bounced: false,
                                           outcomeSource: nil)]
        return item
    }

    // The row built from the SAME card, through the splice initialiser, plus the searchable fact the
    // pass's contacts walk would have gathered. Two values standing for one show, which is what makes the
    // comparison below a parity check rather than two separate assertions.
    private func row(from item: QueueItem) -> QueueScopeRow {
        var scopeRow = QueueScopeRow(item)
        scopeRow.facts = RecipientFacts(
            standings: [], reachabilityAsHeld: nil,
            searchableContacts: item.contacts.map { SearchableContact(name: $0.name, email: $0.email) })
        return scopeRow
    }

    // Every field the search reads, one query each, plus the two shapes that are easy to lose in a
    // rewrite: a different case and a stripped diacritic. A single "it still matches" test would pass
    // with three of the five fields dropped.
    @Test("a row and a card give the same answer for every field and every query")
    func rowAndCardAgreeFieldByField() {
        let item = card(name: "Wren Ashcombe", email: "wren.a@example.invalid",
                        groupName: "Aurora Strings", venue: "Weill Recital Hall")
        let scopeRow = row(from: item)

        let queries = [
            "Aurora",              // the group name
            "Weill",               // the venue
            "Ashcombe",            // a contact's name
            "wren.a@example",      // a contact's address
            "AURORA",              // case folding
            "aUrOrA",              // case folding, the other way
            "",                    // an empty query matches everything
            "   ",                 // whitespace only is still empty
            "Ashcombe Weill",      // spans two fields, and must match NEITHER
            "nothinghere",         // a plain miss
        ]

        for query in queries {
            #expect(ShowSearch.matches(scopeRow, query: query) == ShowSearch.matches(item, query: query),
                    Comment(rawValue: "a row and a card disagree about \"\(query)\". The row is what "
                            + "Archive and the queue's bar now search, so a disagreement here is a show "
                            + "Dan can no longer find (#3655)."))
        }
    }

    // The diacritic folding, which is the half a rewrite is most likely to lose, because the obvious way
    // to make a search cheap is to lowercase everything into one string and that reproduces the case
    // folding while silently dropping this (L107).
    @Test("a row folds diacritics exactly as a card does")
    func diacriticsFoldOnBothSides() {
        let item = card(name: "Zoë Marchbank", email: "zoe@example.invalid")
        let scopeRow = row(from: item)

        for query in ["Zoe", "Zoë", "zoe marchbank"] {
            #expect(ShowSearch.matches(scopeRow, query: query) == ShowSearch.matches(item, query: query),
                    Comment(rawValue: "a row and a card disagree about \"\(query)\""))
        }
        #expect(ShowSearch.matches(scopeRow, query: "Zoe"),
                Comment(rawValue: "a diacritic-insensitive match stopped working on the row, so a name "
                        + "Dan types plainly no longer finds the show it is on"))
    }

    // THE JOINING SEPARATOR, stated as its own test because the rejected design is the cheap one and the
    // next person to make this faster will reach for it. A lowercased concatenation makes the separator
    // matchable, so a query spanning a name-to-email boundary matches text that exists in no record
    // (L555). This asserts it does not.
    @Test("a query spanning two contact fields matches nothing")
    func aQuerySpanningTwoFieldsFindsNothing() {
        let item = card(name: "Wren Ashcombe", email: "wren.a@example.invalid")
        let scopeRow = row(from: item)

        // The two fields, adjacent, as a joined haystack would hold them.
        #expect(!ShowSearch.matches(scopeRow, query: "Ashcombe wren.a"))
        #expect(!ShowSearch.matches(scopeRow, query: "Ashcombewren.a"))
        // And the halves on their own still match, or the assertion above would pass on a broken search.
        #expect(ShowSearch.matches(scopeRow, query: "Ashcombe"))
        #expect(ShowSearch.matches(scopeRow, query: "wren.a"))
    }

    // A show whose contacts were never gathered matches on its own text and never crashes. `.none` is
    // what a spliced row carries (a departing card keeps its contacts and the row beside it does not), so
    // this is a real state rather than a defensive one.
    @Test("a row with no searchable contacts still matches its group and venue")
    func aRowWithNoContactsStillMatchesItsOwnText() {
        var scopeRow = QueueScopeRow(card(name: "Wren Ashcombe", email: "wren.a@example.invalid"))
        scopeRow.facts = .none

        #expect(ShowSearch.matches(scopeRow, query: "Aurora"))
        #expect(ShowSearch.matches(scopeRow, query: "Weill"))
        #expect(!ShowSearch.matches(scopeRow, query: "Ashcombe"))
    }

    // MARK: - 2. Coverage

    // What search reads. Derived from `SearchableContact` itself rather than named, so a field added to
    // the searchable value and not matched by `ShowSearch` is caught here rather than by nobody.
    private let searched: Set<String> = ["name", "email"]

    // Everything else on `Recipient`, grouped by WHY it is not searched. Grouped rather than listed flat,
    // because an entry with no written reason standing beside entries that each have one is evidence it
    // was never reasoned about rather than deliberately chosen (L233).
    //
    // Adding a field to `Recipient` puts it in NEITHER list and turns this red. That is the guard: the
    // question "should this be searchable" gets asked once, at the moment the field is added, while it is
    // still cheap to answer.
    private var notSearched: [String: Set<String>] {
        [
            // Not text at all: a flag, an instant, a count, a relationship. Nothing here is something a
            // person types into a search box.
            "not text": [
                "looksLikeVenue", "looksLikeVenueDismissed", "looksLikePressContact",
                "looksLikePressContactDismissed", "looksLikeDuplicateContact",
                "looksLikeDuplicateContactDismissed", "looksLikeAnotherPersons",
                "looksLikeAnotherPersonsDismissed", "heldDownToUnverified",
                "heldDownToUnverifiedDismissed", "nameMatchOnly", "nameMatchOnlyDismissed",
                "roleIsACharacterisation", "formOutreachRecordedAt", "formOutreachStartedAt",
                "replyMarkedByHandAt", "replyMarkClearedStandDown", "replyCandidateSearchedAt",
                "conversationAttachedAt", "attachPriorReplyDraftWrittenByDan",
                "attachPriorReplyDraftEditedByDan", "attachWroteAddress", "conversationEverAttachedAt",
                "replyProposedSentAt", "replyProposedScore", "replyProposedAt", "sentAt",
                "replyTrackingDegraded", "threadingDegraded", "sendClaimedAt", "replySendClaimedAt",
                "replyCopiedAt", "nudgeSendClaimedAt", "followUpCount", "outreachStoodDownAt",
                "nudgeRemindedAt", "closingNoteStoodDownAt", "lastFollowUpAt", "replied", "repliedAt",
                "inboundReplySentAt", "replyTextCheckedAt", "replyHandledAt", "bounced", "delayNoticeAt",
                "conversationRemindedAt", "pausedByReply", "replyDraftRequestedAt",
                "replyDraftEditedByDan", "replySentAt", "prospect", "replyDraftWrittenByDan",
            ],
            // Machine-minted identifiers. Text, but nobody types a Gmail thread id looking for a show, and
            // matching them would make a query of digits hit unrelated rows.
            "a machine identifier": [
                "id", "gmailThreadId", "gmailMessageId", "gmailReferences", "lastReplyId",
                "dismissedReplyId", "lastBounceId", "dismissedBounceId", "lastDelayMessageId",
                "inboundReplyMessageId", "replyProposedMessageId", "replyProposedThreadId",
                "attachDisplacedThreadId", "attachDisplacedMessageId", "dismissedConversationIds",
                "attachPausedRecipientIds", "sendGroupId",
            ],
            // A stored enum or code, read back through its own type. Its spelling is an implementation
            // detail of the store, so matching on it would let a query find shows by a word Dan never
            // sees on screen.
            "a stored code": [
                "provenanceRaw", "contactMethodRaw", "contactConfidenceRaw", "heldDownReasonRaw",
                "contactTierRaw", "outreachChannelRaw", "formOutreachPriorStatusRaw",
                "attachPriorResolutionRaw", "sendStateRaw", "suppressionReasonRaw", "resolutionRaw",
                "outcomeSourceRaw", "replyAudience", "intentHint", "replyDraftModel",
            ],
            // The CONTENT of correspondence rather than who it is with. Deliberately out: a search over
            // letter bodies would match a large share of the store on any ordinary word, so the popover
            // would stop being a way to find one show.
            "the text of a letter": [
                "overrideBody", "lintOverriddenBody", "replyDraftSubject", "replyDraftBody",
                "originalReplyDraftBody", "sentReplyBody", "attachPriorOriginalReplyDraftBody",
                "greetingOverriddenBody", "openingOverride", "attachedThreadSubject",
                "replyProposedSubject", "lastReplyText", "sendError",
            ],
            // A way IN rather than a person. The card already labels a contact form by its site, and the
            // host is shared by every act on it, so matching a URL would return whole platforms at once.
            "a route rather than a person": [
                "contactFormURL", "contactSourceURL", "formOutreachURL",
            ],
            // The identity of somebody on the OTHER side of a thread, recorded from what arrived rather
            // than from what Overture holds. Left out because that is what the search did before this
            // phase too: a card's `contacts` carries this show's contacts, never the reply's sender. Named
            // as its own group rather than folded into one of the others, because it is the one group
            // where the answer is arguable and somebody may want it searchable later.
            "the other party on a thread": [
                "replyFromAddress", "replyFromName", "replyProposedFromAddress", "replyProposedFromName",
                "attachDisplacedEmail",
            ],
            // What a contact does, not who they are. A characterisation the run wrote as often as a title
            // the page carried, so it is not a reliable thing to search by.
            "a descriptive label": ["role"],
        ]
    }

    @Test("every stored property of Recipient is classified as searched or not")
    func everyRecipientFieldIsClassified() {
        let source = SourceGuardHelper.source("Overture/Domain/Recipient.swift")
        let body = try! #require(SourceGuardHelper.between("final class Recipient", and: "\n}", in: source))
        let stored = Set(SourceGuardHelper.storedPropertyNames(inClassBody: body))

        // A floor, because under-reporting is the dangerous direction: a reader that found nothing would
        // classify nothing and pass (L98).
        #expect(stored.count >= 100,
                "read only \(stored.count) stored properties off Recipient, so this checked almost nothing")

        let classified = notSearched.values.reduce(into: searched) { $0.formUnion($1) }
        let unclassified = stored.subtracting(classified)
        #expect(unclassified.isEmpty,
                Comment(rawValue: "these Recipient fields are in neither list: "
                        + "\(unclassified.sorted().joined(separator: ", ")). Say whether search should "
                        + "match them. If it should, they go on `SearchableContact` and into "
                        + "`ShowSearch.matches`; if not, into the group above that says why. A contact "
                        + "field nobody classifies is one that silently sits outside search (#3655, L96)."))

        // And the other direction: a name in the classification that Recipient no longer has is a stale
        // entry, and a list carrying dead names stops being a reading of the model.
        let stale = classified.subtracting(stored)
        #expect(stale.isEmpty,
                Comment(rawValue: "these classified names are not on Recipient any more: "
                        + "\(stale.sorted().joined(separator: ", "))"))

        // No field in two groups, or the count above would agree while the classification said two
        // different things about one field.
        let groupedTotal = notSearched.values.reduce(0) { $0 + $1.count } + searched.count
        #expect(groupedTotal == classified.count,
                "a field is classified twice: \(groupedTotal) entries collapse to \(classified.count) names")
    }

    // The other half of the coverage question, and the one the model list cannot answer: every field the
    // searchable value CARRIES is actually read by the matcher. A field added to `SearchableContact` and
    // not matched is a field that costs memory on every row and finds nothing.
    @Test("every field on SearchableContact is read by the matcher")
    func everySearchableFieldIsMatched() {
        let row = SourceGuardHelper.source("Overture/UI/QueueScopeRow.swift")
        let body = try! #require(SourceGuardHelper.between("struct SearchableContact", and: "\n}", in: row))
        let fields = body.components(separatedBy: "\n").compactMap { line -> String? in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("let "), code.contains(":") else { return nil }
            return String(code.dropFirst(4).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }.filter { !$0.isEmpty && $0 != "redactedMark" }

        #expect(Set(fields) == searched,
                Comment(rawValue: "SearchableContact carries \(fields.sorted()) and the matcher reads "
                        + "\(searched.sorted()). A field it carries and the matcher does not read is paid "
                        + "for on every row in the store and finds nothing."))

        let matcher = SourceGuardHelper.source("Overture/Domain/ShowSearch.swift")
        for field in searched {
            #expect(matcher.contains("contact.\(field)"),
                    Comment(rawValue: "ShowSearch.matches never reads contact.\(field), so a show is no "
                            + "longer findable by it"))
        }
    }
}
