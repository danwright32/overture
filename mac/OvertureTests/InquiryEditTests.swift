import Testing
import Foundation
import SwiftData

// #1504: once an inquiry was logged there was no way to change it, so a typo in a name, or an event
// date learned later, was stuck forever. The date one matters beyond tidiness: an inquiry's natural key
// IS the event (performance / date / venue), so filling the date in later re-keys it and improves both
// duplicate detection and the Downbeat booking match.
//
// The edit reuses the SAME normalization as intake rather than a second copy of it. If it did not, the
// identical event typed twice (once at intake, once as an edit) would key two different ways and stop
// matching itself.
@MainActor
@Suite("Editing a logged inquiry (#1504)")
struct InquiryEditTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test("an edit normalizes exactly the way intake does, so the same event keys the same way")
    func editKeysIdenticallyToIntake() throws {
        let ctx = ModelContext(try container())
        let created = InquiryIntake.create(source: .contactForm, name: "Ada", email: "ada@x.org",
                                           eventName: "Spring Gala", performanceDate: "2026-05-01",
                                           venue: "Weill Recital Hall", notes: nil, in: ctx)

        let edited = InquiryIntake.create(source: .directEmail, name: "Bob", email: nil,
                                          eventName: "placeholder", performanceDate: nil,
                                          venue: nil, notes: nil, in: ctx)
        // The same event, typed with the untidy whitespace a person actually types.
        InquiryIntake.apply(to: edited, source: .contactForm, name: "  Bob  ", email: "  ",
                            eventName: "  Spring  Gala ", performanceDate: "2026-05-01",
                            venue: " Weill Recital Hall ", notes: "   ")

        #expect(edited.naturalKey == created.naturalKey)
        #expect(edited.inquirerName == "Bob")
        // A field left blank becomes genuinely absent, not an empty string pretending to be a value.
        #expect(edited.inquirerEmail == nil)
        #expect(edited.notes == nil)
    }

    // Learning the date later is the case the issue calls out: it re-keys the inquiry, which is what
    // makes the duplicate check and the booking match start working for it.
    @Test("filling in the date later re-keys the inquiry")
    func fillingInTheDateRekeys() throws {
        let ctx = ModelContext(try container())
        let inq = InquiryIntake.create(source: .contactForm, name: "Ada", email: nil,
                                       eventName: "Gala", performanceDate: nil, venue: "Weill",
                                       notes: nil, in: ctx)
        let keyWithoutDate = inq.naturalKey

        InquiryIntake.apply(to: inq, source: .contactForm, name: "Ada", email: nil,
                            eventName: "Gala", performanceDate: "2026-05-01", venue: "Weill", notes: nil)

        #expect(inq.performanceDate == "2026-05-01")
        #expect(inq.naturalKey != keyWithoutDate)
        #expect(inq.naturalKey == Inquiry.makeNaturalKey(eventName: "Gala",
                                                         performanceDate: "2026-05-01", venue: "Weill"))
    }

    // The bug this would otherwise walk straight into: while editing, the inquiry matches its OWN key,
    // so a plain duplicate check would warn Dan that every inquiry he opens is already logged.
    @Test("an inquiry being edited is never flagged as a duplicate of itself")
    func editingDoesNotFlagItself() throws {
        let ctx = ModelContext(try container())
        let inq = InquiryIntake.create(source: .contactForm, name: "Ada", email: nil,
                                       eventName: "Gala", performanceDate: "2026-05-01",
                                       venue: "Weill", notes: nil, in: ctx)
        let all = [inq]

        #expect(InquiryIntake.duplicate(ofKey: inq.naturalKey, in: all, excluding: inq) == nil)
        // Without the exclusion it WOULD match, which is exactly why the parameter exists.
        #expect(InquiryIntake.duplicate(ofKey: inq.naturalKey, in: all, excluding: nil) === inq)
    }

    // But a genuine clash with a DIFFERENT inquiry must still warn, or editing becomes a way to create
    // the duplicate the check exists to catch.
    @Test("editing onto another inquiry's event still warns")
    func editingOntoAnotherEventStillWarns() throws {
        let ctx = ModelContext(try container())
        let first = InquiryIntake.create(source: .contactForm, name: "Ada", email: nil,
                                         eventName: "Gala", performanceDate: "2026-05-01",
                                         venue: "Weill", notes: nil, in: ctx)
        let second = InquiryIntake.create(source: .directEmail, name: "Bob", email: nil,
                                          eventName: "Recital", performanceDate: "2026-06-01",
                                          venue: "Zankel", notes: nil, in: ctx)

        let clash = InquiryIntake.duplicate(ofKey: first.naturalKey, in: [first, second], excluding: second)

        #expect(clash === first)
    }

    // Reopening an inquiry has to show what is already there. A stored date must come back as a known
    // date, and an absent one must NOT arrive pre-ticked, which would silently invent a date on save.
    @Test("reopening an inquiry restores its date, and an unknown date stays unknown")
    func prefillRestoresTheDate() {
        let known = InquiryIntake.editingDate(from: "2026-05-01")
        #expect(known.hasDate)
        #expect(EasternDate.dayString(from: known.date) == "2026-05-01")

        let unknown = InquiryIntake.editingDate(from: nil)
        #expect(!unknown.hasDate)

        // A stored value that cannot be parsed must not read as a known date either.
        #expect(!InquiryIntake.editingDate(from: "not-a-date").hasDate)
    }

    // The sheet's whole save action, so the create-or-edit choice AND the write behind it are both
    // reachable by a test rather than stated in a SwiftUI body.
    @Test("saving with no inquiry to edit logs a new one, and confirms it")
    func saveCreatesWhenNotEditing() throws {
        let ctx = ModelContext(try container())
        let feedback = ActionFeedback()

        let saved = InquiryIntake.save(editing: nil, source: .contactForm, name: "Ada",
                                       email: "ada@x.org", eventName: "Gala",
                                       performanceDate: "2026-05-01", venue: "Weill", notes: nil,
                                       in: ctx, feedback: feedback)

        let all = try ctx.fetch(FetchDescriptor<Inquiry>())
        #expect(saved)
        #expect(all.count == 1)
        #expect(all.first?.inquirerName == "Ada")
        #expect(feedback.message == nil)
    }

    @Test("saving with an inquiry to edit changes that one instead of adding another")
    func saveEditsWhenEditing() throws {
        let ctx = ModelContext(try container())
        let existing = InquiryIntake.create(source: .contactForm, name: "Ada", email: nil,
                                            eventName: "Gala", performanceDate: nil, venue: nil,
                                            notes: nil, in: ctx)

        let saved = InquiryIntake.save(editing: existing, source: .directEmail, name: "Ada Lovelace",
                                       email: nil, eventName: "Spring Gala",
                                       performanceDate: "2026-05-01", venue: "Weill", notes: nil,
                                       in: ctx, feedback: ActionFeedback())

        let all = try ctx.fetch(FetchDescriptor<Inquiry>())
        #expect(saved)
        #expect(all.count == 1, "editing must not add a second record")
        #expect(existing.inquirerName == "Ada Lovelace")
        #expect(existing.performanceDate == "2026-05-01")
    }

    // The failure path. This sheet is the ONLY place these fields exist, so a write that fails
    // silently is Dan's typing gone with nothing said.
    @Test("a failing save warns Dan rather than losing what he typed in silence")
    func failedSaveIsSurfaced() async throws {
        let feedback = ActionFeedback()

        let saved = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Inquiry.self]),
            seed: { _ = InquiryIntake.create(source: .contactForm, name: "Seed", email: nil,
                                             eventName: "Seed event", performanceDate: nil,
                                             venue: nil, notes: nil, in: $0) },
            body: { ctx in
                InquiryIntake.save(editing: nil, source: .contactForm, name: "Ada", email: nil,
                                   eventName: "Gala", performanceDate: nil, venue: nil, notes: nil,
                                   in: ctx, feedback: feedback)
            })

        #expect(!saved)
        #expect(feedback.message == "Couldn't save the change for Ada")
        #expect(feedback.tone == .warning)
    }

    // Editing must not disturb the inquiry's lifecycle: the reply already sent, the thread being
    // watched, and its outcome are none of the edit sheet's business.
    @Test("editing leaves the reply, thread, and outcome untouched")
    func editLeavesLifecycleAlone() throws {
        let ctx = ModelContext(try container())
        let inq = InquiryIntake.create(source: .contactForm, name: "Ada", email: "ada@x.org",
                                       eventName: "Gala", performanceDate: nil, venue: nil,
                                       notes: nil, in: ctx)
        let sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        inq.sentAt = sentAt
        inq.gmailThreadId = "th-1"
        inq.gmailMessageId = "m-1"
        inq.replied = true

        InquiryIntake.apply(to: inq, source: .directEmail, name: "Ada Lovelace", email: "ada@x.org",
                            eventName: "Spring Gala", performanceDate: "2026-05-01", venue: "Weill",
                            notes: "moved to the big hall")

        #expect(inq.sentAt == sentAt)
        #expect(inq.gmailThreadId == "th-1")
        #expect(inq.gmailMessageId == "m-1")
        #expect(inq.replied)
        #expect(inq.isOpen)
    }
}
