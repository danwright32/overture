import Testing
import Foundation
import SwiftData
@testable import Overture

// #1260 Phase 1 / #1276: a merged same-date+venue prospect (SameDateVenueMerge, #1236) carries a
// conductor-LIST groupName ("We Sing Noel; Craig Courtney; The Four Freedoms"), fine on screen but wrong
// in an outbound follow-up/reminder email under Dan's name (those paths have NO edit surface). The name is
// substituted with a neutral phrase, keyed on the PERSISTED merge fact, NOT a "; " sniff: a real single
// title that happens to contain "; " (Carnegie's "Symphony of Psalms & Les Noces (Stravinsky); No Time for
// Idle Tears") must keep its real name. These pin both halves, including the wire from prospect.seriesId.
@Suite("Merged-name outbound sanitizer (#1260 / #1276)")
struct MergedNameOutboundSanitizerTests {
    private let mergedName = "We Sing Noel; Craig Courtney; The Four Freedoms"
    private let legitSemicolonTitle = "Symphony of Psalms & Les Noces (Stravinsky); No Time for Idle Tears"

    @Test func substitutesOnlyForAGenuineMergeNotForASemicolonTitle() {
        #expect(FollowUp.safeDisplayName(mergedName, isMerged: true) == FollowUp.mergedNameSubstitute)
        // #1276: a real single title with a semicolon keeps its true name.
        #expect(FollowUp.safeDisplayName(legitSemicolonTitle, isMerged: false) == legitSemicolonTitle)
        #expect(FollowUp.safeDisplayName("Aurora Strings", isMerged: false) == "Aurora Strings")
    }

    @Test func followUpNudgeSubstitutesOnlyWhenMerged() {
        let merged = FollowUp.nudgeContent(originalSubject: nil, groupName: mergedName, isMerged: true,
                                           contactName: "Sam", venue: "Carnegie Hall", followUpCount: 0)
        #expect(!merged.subject.contains(mergedName))
        #expect(!merged.body.contains(mergedName))
        #expect(merged.body.contains(FollowUp.mergedNameSubstitute))

        let legit = FollowUp.nudgeContent(originalSubject: nil, groupName: legitSemicolonTitle, isMerged: false,
                                          contactName: "Sam", venue: "Carnegie Hall", followUpCount: 0)
        #expect(legit.body.contains(legitSemicolonTitle))   // the #1276 fix: real name kept
    }

    @Test func conversationReminderSubstitutesOnlyWhenMerged() {
        func body(_ name: String, isMerged: Bool) -> String {
            ConversationReminder.nudgeContent(kind: .active(.interested), originalSubject: nil,
                                              groupName: name, isMerged: isMerged,
                                              contactName: "Sam", venue: "Carnegie Hall")?.body ?? ""
        }
        #expect(!body(mergedName, isMerged: true).contains(mergedName))
        #expect(body(mergedName, isMerged: true).contains(FollowUp.mergedNameSubstitute))
        #expect(body(legitSemicolonTitle, isMerged: false).contains(legitSemicolonTitle))
    }

    // The WIRING: the flag must actually flow from a stored Prospect's persisted seriesId through the
    // confirmation/send builder, not just exist as a parameter. A merged prospect substitutes; a
    // semicolon-titled single prospect (no seriesId) keeps its real name.
    @MainActor
    @Test func theConfirmationBuilderReadsTheProspectsPersistedMergeFlag() throws {
        let container = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)

        func confirmBody(groupName: String, seriesId: String?) throws -> String {
            let key = Prospect.makeNaturalKey(groupName: groupName, performanceDate: "2026-11-16", venue: "Stern")
            let p = Prospect(naturalKey: key, groupName: groupName, discipline: "choral", venue: "Stern",
                             performanceDate: "2026-11-16", sourceListingURL: nil, websiteURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .approved, ingestedAt: Date())
            p.seriesId = seriesId
            ctx.insert(p)
            let r = Recipient(id: "to@org.org", email: "to@org.org", name: "Sam", provenance: .act)
            r.sentAt = Date()   // a follow-up goes to an already-contacted recipient
            r.sendState = .sent
            p.setRecipients([r])
            try ctx.save()
            let c = try #require(SendConfirmation(followUpFor: r, of: p))
            return c.body
        }

        let mergedBody = try confirmBody(groupName: mergedName,
                                         seriesId: SameDateVenueMerge.syntheticSeriesId(date: "2026-11-16", venue: "Stern"))
        #expect(!mergedBody.contains(mergedName))
        #expect(mergedBody.contains(FollowUp.mergedNameSubstitute))

        let legitBody = try confirmBody(groupName: legitSemicolonTitle, seriesId: nil)
        #expect(legitBody.contains(legitSemicolonTitle))   // not merged -> real name survives to the recipient
    }
}
