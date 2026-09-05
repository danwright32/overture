import Testing
import Foundation
import SwiftData

// #3549 / #3551, milestone 77. A show has exactly ONE outgoing letter.
//
// Until this, a `provenance: .performer` contact could carry its own second copy of the pitch
// (`Recipient.overrideBody`), which the send path preferred over the show's shared body. The card
// previewed, edited and badged the SHARED body, so an edit Dan made was reported as applied and
// could never reach the recipient. Measured on the live store 2026-09-05: 9 contacts held a second
// copy, 8 of those shows had only one contact (so the body in the box reached nobody at all), and
// three of the nine carried an edit that had gone nowhere, two of them already sent.
//
// Dan's call, 2026-09-05, in session, on being shown the two texts side by side: "what do we have
// two versions at all? we should just always only have 1 version."
//
// The evidence for it being safe, measured the same day: of 199 shows carrying any contact, only 16
// held both a performer and somebody else, and of those 16 exactly one had a second copy written.
// That one show is dismissed for a date conflict on a date already past, so no live show in the
// store needed two letters. Prep knows who a show's contacts are when it drafts, so the address form
// belongs in the one body it writes rather than in a second copy beside it.
@MainActor
@Suite("One letter per show (#3549)")
struct OneLetterPerShowTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, body: String) -> Prospect {
        let p = Prospect(naturalKey: "k|2026-11-10|weill", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2026-11-10",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.draftSubject = "Photographs of your recital"
        p.draftBody = body
        ctx.insert(p)
        return p
    }

    // The rule itself, stated on the two provenances that used to disagree. A performer is the case
    // that carried the second copy; a presenter never could, so the two together say the answer no
    // longer depends on who the contact is.
    @Test func everyContactOfAShowReceivesTheShowsOwnLetter() throws {
        let ctx = try context()
        let p = show(ctx, body: "Hi Corin, I photograph performing arts in New York.")

        let performer = Recipient(id: "v@example.com", email: "v@example.com",
                                  name: "Corin Hale", role: "Pianist",
                                  provenance: .performer)
        let presenter = Recipient(id: "b@example.com", email: "b@example.com",
                                  name: "Bright Star Presents", role: "Presenter",
                                  provenance: .presenter)
        for r in [performer, presenter] { p.recipients.append(r); ctx.insert(r) }

        #expect(performer.effectiveBody == p.draftBody)
        #expect(presenter.effectiveBody == p.draftBody)
        #expect(performer.effectiveBody == presenter.effectiveBody)
    }

    // The whole app, not the one file the defect was found in (L30). A second stored copy of the
    // outgoing body is the shape being retired, so nothing anywhere may declare, write or read one.
    @Test func noSecondCopyOfTheOutgoingLetterExistsAnywhere() throws {
        let files = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("Overture"))
        if let refusal = AppSourceWalk.refusal(found: files.count, floor: AppSourceWalk.appFloor,
                                               directory: "mac/Overture") {
            Issue.record(Comment(rawValue: refusal)); return
        }

        // CODE only, through the shared tokenizer, so a comment recording that this was retired is not
        // itself reported as the thing being retired. A guard that cannot tell a line USING a construct
        // from a line ABOUT it forces its own documentation out of the tree (L103).
        // The one line that may name it is its own RETAINED declaration on the persisted model. The
        // column stays because dropping a stored property would be this app's first subtractive
        // migration against Dan's live store, which the schema convention says gets its own rehearsed
        // change (see AppSchema, and Prospect's retained columns). What must not come back is any READ
        // or WRITE of it, which is the whole defect: the value landing somewhere nothing consults.
        var found: [String] = []
        var retainedDeclaration: String?
        for file in files {
            for (line, code) in SwiftSource.scannableLines(in: file.text)
            where code.contains("overrideBody") {
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if file.name == "Recipient.swift", trimmed.hasPrefix("var overrideBody") {
                    retainedDeclaration = "\(file.name):\(line)"
                    continue
                }
                found.append("\(file.name):\(line)  \(trimmed)")
            }
        }
        #expect(found.isEmpty, """
            A per contact copy of the outgoing letter is read or written again. A show has one letter \
            (#3549), and a second copy beside it is the defect this retired: the card edits one and the \
            send composes from the other, so an edit reports as applied and reaches nobody.
            \(found.joined(separator: "\n"))
            """)
        // Asserted rather than assumed: its ABSENCE would mean somebody dropped the column, which is
        // the risky half of this and must not happen as a side effect of a behaviour change (L5).
        #expect(retainedDeclaration != nil, """
            Recipient.overrideBody's retained declaration is gone. Dropping a stored property is this \
            app's first subtractive migration against a live store whose only net is the launch backup, \
            so it gets its own change with a rehearsal against a store clone, never a quiet deletion.
            """)
    }

    // One definition of the text a contact receives, with no branch in it. A branch here is what let
    // the card and the send path read different things while both looked correct (L263, L402).
    @Test func theTextAContactReceivesHasOneDefinitionAndNoBranch() throws {
        let source = SourceGuardHelper.source("Overture/Domain/Recipient.swift")
        #expect(!source.isEmpty, "Could not read Recipient.swift, so nothing was measured.")

        guard let decl = source.range(of: "var effectiveBody: String? {") else {
            Issue.record("Recipient.effectiveBody is gone or renamed, so this guard measured nothing.")
            return
        }
        let body = String(source[decl.upperBound...].prefix(while: { $0 != "}" }))
        #expect(body.contains("prospect?.draftBody"),
                "effectiveBody must resolve to the show's own body: \(body)")
        #expect(!body.contains("provenance"), """
            effectiveBody branches on who the contact is, which is the shape #3549 retired: it is how \
            one show came to have two letters with only one of them editable. Body was: \(body)
            """)
    }

    // The card's own surface. A read only preview of a second letter beside an editable box is the
    // exact screen Dan was reading when he found this, and it cannot come back.
    @Test func theCardHasNoSecondReadOnlyLetterBesideTheEditableOne() throws {
        let source = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(!source.isEmpty, "Could not read DraftReviewView.swift, so nothing was measured.")
        #expect(!source.contains("performerOverridePreviews"), """
            The card renders a second, read only letter beside the editable one. That is the screen \
            #3549 was filed from: the box carrying Edit showed text that reached nobody, and the text \
            that would send sat under it with no way to change it.
            """)
    }
}
