import Testing
import Foundation
import SwiftData

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

    // #2615 moved the closing note's BODY off the group name entirely (it names the show's date and room
    // instead), so the whole message is what this has to be asked of: the conductor list must reach the
    // recipient nowhere, and a legitimate semicolon title must still survive where the name is used.
    @Test func conversationReminderSubstitutesOnlyWhenMerged() {
        func message(_ name: String, isMerged: Bool) -> String {
            let c = PostEventPrompt.nudgeContent(kind: .closingNote, originalSubject: nil,
                                                 groupName: name, isMerged: isMerged,
                                                 contactName: "Sam", performanceDate: "2026-11-16",
                                                 venue: "Carnegie Hall")
            return (c?.subject ?? "") + "\n" + (c?.body ?? "")
        }
        #expect(!message(mergedName, isMerged: true).contains(mergedName))
        #expect(message(mergedName, isMerged: true).contains(FollowUp.mergedNameSubstitute))
        #expect(message(legitSemicolonTitle, isMerged: false).contains(legitSemicolonTitle))
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

// #1273: the audit of #1260 Phase 1 found the NAME was guarded but the VENUE was not. The same no-edit
// nudge/reminder bodies interpolate the venue verbatim ("photographing X at <venue>"). A stored venue has
// already cleared the ingest guard (ExtractedEventGuard rejects a missing/placeholder/numeric-id venue),
// but that guard never checks for scrape artifacts, so "Carnegie Hall\n881 7th Ave" is a perfectly storable
// venue that would inject a line break mid-sentence into an email sent under Dan's name with no review.
// safeVenue is the venue's counterpart to safeDisplayName: a clean venue to interpolate, or nil to drop the
// " at <venue>" clause, never an ugly one. (Audit of the other interpolated fields: groupName is guarded by
// safeDisplayName; contactName is normalized by Salutation.greeting/firstName; originalSubject is
// prospect.draftSubject, which Dan reviewed before the first send. Venue was the one gap.)
@Suite("Outbound nudge venue is guarded (#1273)")
struct SafeVenueGuardTests {
    @Test func aCleanVenueSurvivesUnchanged() {
        #expect(FollowUp.safeVenue("Carnegie Hall") == "Carnegie Hall")
        #expect(FollowUp.safeVenue("Merkin Concert Hall, Kaufman Music Center")
                == "Merkin Concert Hall, Kaufman Music Center")
    }

    @Test func aVenueWithAnEmbeddedLineBreakIsDropped() {
        #expect(FollowUp.safeVenue("Carnegie Hall\n881 7th Ave") == nil)
        #expect(FollowUp.safeVenue("Carnegie Hall\r\nNew York, NY") == nil)
    }

    @Test func aVenueWithAControlCharacterIsDropped() {
        #expect(FollowUp.safeVenue("Zankel\tHall") == nil)
    }

    @Test func aBlankOrMissingVenueIsNil() {
        #expect(FollowUp.safeVenue(nil) == nil)
        #expect(FollowUp.safeVenue("   ") == nil)
    }

    @Test func surroundingWhitespaceIsTrimmedAndInternalRunsCollapsed() {
        #expect(FollowUp.safeVenue("  Carnegie Hall  ") == "Carnegie Hall")
        #expect(FollowUp.safeVenue("Carnegie   Hall") == "Carnegie Hall")
    }

    // The WIRING: the guard must actually reach the no-edit send bodies, not just exist as a helper.
    @Test func aFollowUpNudgeDropsTheClauseForAMessyVenueButKeepsACleanOne() {
        let messy = FollowUp.nudgeContent(originalSubject: nil, groupName: "Aurora Strings",
                                          contactName: "Dana", venue: "Carnegie Hall\n881 7th Ave",
                                          followUpCount: 0)
        #expect(!messy.body.contains("881 7th Ave"))
        #expect(messy.body.contains("photographing Aurora Strings."))   // clean, no broken " at <junk>"

        let clean = FollowUp.nudgeContent(originalSubject: nil, groupName: "Aurora Strings",
                                          contactName: "Dana", venue: "Merkin Hall", followUpCount: 0)
        #expect(clean.body.contains("photographing Aurora Strings at Merkin Hall."))
    }

    @Test func theClosingNoteDropsTheClauseForAMessyVenueButKeepsACleanOne() {
        func body(venue: String?) -> String {
            PostEventPrompt.nudgeContent(kind: .closingNote, originalSubject: nil,
                                              groupName: "Aurora Strings", contactName: "Dana",
                                              performanceDate: "2026-11-16", venue: venue)?.body ?? ""
        }
        #expect(!body(venue: "Carnegie Hall\n881 7th Ave").contains("881 7th Ave"))
        // #2615: the show is named by its date and room, not by the group name.
        #expect(body(venue: "Merkin Hall").contains("your November 16 show at Merkin Hall"))
        #expect(body(venue: "Carnegie Hall\n881 7th Ave").contains("your November 16 show has come and gone"))
    }
}
