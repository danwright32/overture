import Testing
import Foundation
import SwiftData

// #249: the anonymization guard. The #242 distiller is told to strip every org/venue/contact/
// production specific from the voice guidance, but nothing verified it. This guard fails CLOSED:
// it checks the auto-generated section of overture-voice-guidance.md against the real names in the
// store, and if any leak through it quarantines that section (so a contaminated guidance can never
// feed a future draft) and reports the leak so Dan is warned. Dan's own notes section is never
// inspected or touched — what he writes there is his call.

@Suite("Voice guidance guard (#249)")
struct VoiceGuidanceGuardTests {
    private func prospect(group: String = "Aurora Strings", venue: String? = "Carnegie Hall",
                          contact: String? = "Maria Lopez", production: String = "self",
                          possibleMatch: String? = nil, matchedClient: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k-\(group)", groupName: group, discipline: "music", venue: venue,
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: production, profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: matchedClient, possibleMatchSource: nil,
                         possibleMatchName: possibleMatch, status: .contacted)
        if let contact {
            p.setRecipients([Recipient(id: contact, email: nil, name: contact, provenance: .act)])
        }
        return p
    }

    private let clean = """
    ## Dan's notes (authoritative, never auto-edited)

    Keep it level.

    ## Observed tendencies (auto-generated; regenerated each run)

    - Dan cuts the second opener sentence.
    - He replaces "cover" with "photograph".
    """

    @Test func forbiddenTermsCollectsRealNamesAndDropsShortOnes() {
        let terms = VoiceGuidanceGuard.forbiddenTerms(from: [prospect()])
        #expect(terms.contains("Aurora Strings"))
        #expect(terms.contains("Carnegie Hall"))
        #expect(terms.contains("Maria Lopez"))
        // The "self" production sentinel and anything under 4 chars are dropped (false-positive noise).
        #expect(!terms.contains("self"))
    }

    @Test func findLeaksDetectsANameInTheAutoSection() {
        let leaked = clean.replacingOccurrences(
            of: "He replaces \"cover\" with \"photograph\".",
            with: "Like the Aurora Strings email, lead with the venue.")
        let found = VoiceGuidanceGuard.findLeaks(inAutoSectionOf: leaked, forbidden: ["Aurora Strings"])
        #expect(found == ["Aurora Strings"])
    }

    @Test func findLeaksIgnoresDansOwnNotesSection() {
        // A name in Dan's notes is his call, not a leak — only the auto section is guarded.
        let inNotes = """
        ## Dan's notes (authoritative, never auto-edited)

        Remember the Aurora Strings tone.

        ## Observed tendencies (auto-generated; regenerated each run)

        - Dan keeps it level.
        """
        let found = VoiceGuidanceGuard.findLeaks(inAutoSectionOf: inNotes, forbidden: ["Aurora Strings"])
        #expect(found.isEmpty)
    }

    @Test func findLeaksIsCaseInsensitiveAndWordBounded() {
        let lowered = clean.replacingOccurrences(of: "- Dan cuts the second opener sentence.",
                                                 with: "- like the aurora strings note, stay plain.")
        #expect(VoiceGuidanceGuard.findLeaks(inAutoSectionOf: lowered, forbidden: ["Aurora Strings"]) == ["Aurora Strings"])
        // A name embedded inside a longer word is NOT a leak ("Aurora" inside "aurorae").
        let embedded = clean.replacingOccurrences(of: "- Dan cuts the second opener sentence.",
                                                  with: "- aurorae of phrasing, not real names.")
        #expect(VoiceGuidanceGuard.findLeaks(inAutoSectionOf: embedded, forbidden: ["Aurora"]).isEmpty)
    }

    @Test func cleanGuidanceHasNoLeaks() {
        #expect(VoiceGuidanceGuard.findLeaks(inAutoSectionOf: clean, forbidden: ["Aurora Strings", "Carnegie Hall"]).isEmpty)
    }

    @Test func quarantineRemovesAutoBodyButKeepsDansNotes() {
        let leaked = clean.replacingOccurrences(
            of: "- Dan cuts the second opener sentence.",
            with: "- Like the Aurora Strings email, lead with the venue.")
        let cleaned = VoiceGuidanceGuard.quarantineAutoSection(in: leaked)
        #expect(cleaned.contains("## Dan's notes (authoritative, never auto-edited)"))
        #expect(cleaned.contains("Keep it level."))                 // Dan's notes preserved
        #expect(!cleaned.contains("Aurora Strings"))                // leaked auto body gone
        #expect(cleaned.contains("## Observed tendencies"))         // heading kept
    }

    @Test func auditQuarantinesFileOnLeakAndReportsIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vg-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let leaked = clean.replacingOccurrences(
            of: "- Dan cuts the second opener sentence.",
            with: "- Like the Aurora Strings email, lead with the venue.")
        try leaked.write(to: url, atomically: true, encoding: .utf8)

        let found = VoiceGuidanceGuard.audit(fileURL: url, prospects: [prospect()])
        #expect(found == ["Aurora Strings"])
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(!after.contains("Aurora Strings"))   // file was sanitized on disk
        #expect(after.contains("Keep it level."))    // Dan's notes still there
    }

    @Test func auditLeavesACleanFileUntouchedAndReportsNoLeak() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vg-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try clean.write(to: url, atomically: true, encoding: .utf8)

        #expect(VoiceGuidanceGuard.audit(fileURL: url, prospects: [prospect()]).isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == clean)
    }

    @Test func auditOnMissingFileIsANoLeak() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).md")
        #expect(VoiceGuidanceGuard.audit(fileURL: url, prospects: [prospect()]).isEmpty)
    }
}
