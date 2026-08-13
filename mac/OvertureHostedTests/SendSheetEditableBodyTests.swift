import Testing
import Foundation
import SwiftData
import SwiftUI
import ViewInspector
@testable import Overture

// #2575, the rendering half. The pure suite proves the SEND honours an edited body; only a rendered sheet
// can show that a box exists for Dan to type in, which is the whole of what he was missing when he said
// "I have no way to edit closing notes" (L3: built is not wired, and wired is not proven).
@MainActor
@Suite("The send sheet's text box (#2575)")
struct SendSheetEditableBodyTests {

    private func passedShow() throws -> (Prospect, Recipient) {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let key = Prospect.makeNaturalKey(groupName: "Ryan James Monroe",
                                          performanceDate: "2026-08-01", venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Ryan James Monroe", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-08-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted, ingestedAt: Date())
        p.draftSubject = "Photographing Ryan James Monroe's August 1 show at 54 Below"
        p.sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        ctx.insert(p)
        let r = Recipient(id: "ryan@ryanjamesmonroe.com", email: "ryan@ryanjamesmonroe.com",
                          name: "Ryan", provenance: .act)
        r.sendState = .sent
        r.sentAt = p.sentAt
        p.recipients.append(r)
        ctx.insert(r)
        try? ctx.save()
        return (p, r)
    }

    private func editors(_ view: SendConfirmSheet) throws -> Int {
        try view.inspect().findAll(ViewType.TextEditor.self).count
    }

    // The closing note, the exact sheet Dan was looking at.
    @Test func theclosingNoteSheetCarriesATextBox() throws {
        let (p, r) = try passedShow()
        let confirmation = try #require(SendConfirmation(closingNoteFor: r, of: p))

        let editable = SendConfirmSheet(confirmation: confirmation, onSend: {}, onCancel: {},
                                        onSendEdited: { _ in })

        #expect(try editors(editable) == 1)
    }

    // And the follow-up, the other path with no box.
    @Test func thefollowUpSheetCarriesATextBox() throws {
        let (p, r) = try passedShow()
        let confirmation = try #require(SendConfirmation(followUpFor: r, of: p))

        let editable = SendConfirmSheet(confirmation: confirmation, onSend: {}, onCancel: {},
                                        onSendEdited: { _ in })

        #expect(try editors(editable) == 1)
    }

    // The paths that already had their own editor upstream are untouched: this sheet stays a read-only
    // confirmation for them, so the cold pitch does not acquire a second place to write the same email.
    @Test func asheetWithNoEditCallbackHasNoBox() throws {
        let (p, r) = try passedShow()
        let confirmation = try #require(SendConfirmation(closingNoteFor: r, of: p))

        let readOnly = SendConfirmSheet(confirmation: confirmation, onSend: {}, onCancel: {})

        #expect(try editors(readOnly) == 0)
    }

    // The caption over the box says what the box IS, so a screen that can now be changed does not still
    // describe itself as a preview.
    @Test func thecaptionSaysTheBoxIsWhatWillSend() throws {
        let (p, r) = try passedShow()
        let confirmation = try #require(SendConfirmation(closingNoteFor: r, of: p))
        let editable = SendConfirmSheet(confirmation: confirmation, onSend: {}, onCancel: {},
                                        onSendEdited: { _ in })

        let text = try editable.inspect().findAll(ViewType.Text.self).map { try? $0.string() }

        #expect(text.contains(SendConfirmCopy.editLabel))
        #expect(!text.contains(SendConfirmCopy.previewLabel))
    }
}
