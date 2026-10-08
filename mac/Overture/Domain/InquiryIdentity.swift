import Foundation
import SwiftData

// #4579 (plan v7 Phase 3, step 5): the identity of the hire inquiry behind a press, and the ONE rule that finds
// the live row it names. `ShowIdentity`'s rule, for the other kind of row the queue draws.
//
// WHY IT EXISTS. The pass published each inquiry row's model (`RenderData.inquiriesByRowID` and the Reached
// out list's inquiry rows), so every Reply, Edit, Booked, Lost and Detach control captured an `Inquiry` the
// pass took when it ran, and a published pass is meant to hold values a later pass, the engine's verifier or
// another thread can compare without reading the store (#4357 step 5, `OutputsHoldNoModelTests`). A captured
// model read at press time is also the #3651 hazard: the row it names may have gone since.
//
// THE IDENTITY IS THE STORE IDENTIFIER; THE WITNESS IS `createdAt`, NOT THE EVENT KEY. A show's witness is its
// natural key because merges hand a deleted show's key to a survivor (`ShowIdentity`). An inquiry is never
// merged, and its key is COMPUTED from the event fields, so the edit sheet re-keys it whenever Dan corrects the
// event (`InquiryIntake.apply`). A key witness would refuse a press on the very inquiry Dan just edited, which
// is the right row. `createdAt` is written once, in `Inquiry.init`, and by nothing else, so it can only
// disagree when the identifier names a DIFFERENT record from the one drawn.
//
// THE ROW'S OWN ID, `rowID(of:)`, is defined here too, because it is the key `RenderData.inquiriesByRowID` is
// looked up by. It used to be `String(describing: persistentModelID)`, and that is NOT distinct for an inquiry
// that has not been saved. Measured 2026-10-07 (and pinned by `InquiryIdentityTests`): two unsaved rows'
// identifiers compare unequal while their descriptions are the same string, so the map kept the FIRST
// inquiry under both rows' key and a press on the second acted on the first, with nothing said (L131, L70).
struct InquiryIdentity: Equatable, Hashable, Sendable {
    let inquiryID: PersistentIdentifier
    // The WITNESS, never the identity. If this disagrees with the row `inquiryID` finds, that row is not the
    // inquiry that was drawn and the press is refused.
    let createdAt: Date

    init(inquiryID: PersistentIdentifier, createdAt: Date) {
        self.inquiryID = inquiryID
        self.createdAt = createdAt
    }

    init(_ inquiry: Inquiry) {
        self.init(inquiryID: inquiry.persistentModelID, createdAt: inquiry.createdAt)
    }

    /// The id a row drawn from this inquiry carries, distinct for every live inquiry, saved or not. A saved
    /// one's is its store identifier's description, as it always was. An unsaved one's identifier describes
    /// itself exactly as every other unsaved one's does (see above), so it is named by the object instead,
    /// which is distinct for as long as the object is alive; its first save gives it a permanent identifier and
    /// the next pass draws it under that.
    static func rowID(of inquiry: Inquiry) -> String {
        let id = inquiry.persistentModelID
        guard id.storeIdentifier == nil else { return String(describing: id) }
        return "unsaved-\(UInt(bitPattern: ObjectIdentifier(inquiry)))"
    }

    // WHY A PRESS FINDS NOTHING. Three causes, three sentences, on `ShowIdentity.Refusal`'s rule (L11, L260).
    enum Refusal: Equatable, CaseIterable, CustomStringConvertible {
        /// No live inquiry carries this identifier. It was removed.
        case gone
        /// A live inquiry carries the identifier and is not the one drawn: its `createdAt` differs.
        case notTheOneDrawn
        /// The row was drawn before the inquiry's first save. The identifier is minted AT that save
        /// (`InsertedRowIdentifierAcrossSaveTests`), so the one the row carries no longer names anything, and
        /// nothing maps the old identifier to the new one. Refused rather than resolved by any other field
        /// (L75).
        case drawnBeforeItsFirstSave

        var description: String {
            switch self {
            case .gone: return "gone"
            case .notTheOneDrawn: return "notTheOneDrawn"
            case .drawnBeforeItsFirstSave: return "drawnBeforeItsFirstSave"
            }
        }

        // Said in Dan's words, in the shape `ShowIdentity.Refusal.sentence` settled, one WHOLE sentence per
        // branch so the copy inventory records sentences and never fragments (#2570, #2548). `name` is the
        // inquirer's, which is what the row Dan pressed shows in its first line.
        //
        // COLD READ, 2026-10-07, in the order Dan meets it: he presses Reply, Edit, Booked, Lost or Detach on
        // an inquiry row, nothing opens or changes, and this appears. "Logged" rather than "saved" or "added",
        // because logging is what he did (the sheet's own title is "Log an inquiry"), and a save is not his
        // word (L399). Each says what happened and that nothing was changed, and none asks him to fix
        // anything, because the save that moved the row has already rebuilt the list.
        func sentence(name: String?) -> String {
            switch self {
            case .gone:
                guard let name, !name.isEmpty else {
                    return "That inquiry is no longer in Overture, so nothing was changed. The row you pressed is "
                        + "out of date"
                }
                return "The inquiry from \(name) is no longer in Overture, so nothing was changed. The row you "
                    + "pressed is out of date"
            case .notTheOneDrawn:
                guard let name, !name.isEmpty else {
                    return "This row no longer matches the inquiry Overture holds, so nothing was changed. The "
                        + "list has caught up, so press it again if it is still there"
                }
                return "The row for \(name)'s inquiry no longer matches the inquiry Overture holds, so nothing "
                    + "was changed. The list has caught up, so press it again if it is still there"
            case .drawnBeforeItsFirstSave:
                guard let name, !name.isEmpty else {
                    return "That inquiry was still being logged when this row was drawn, so Overture could not "
                        + "tell which inquiry you pressed. Nothing was changed. The list has caught up, so press "
                        + "it again if it is still there"
                }
                return "The inquiry from \(name) was still being logged when this row was drawn, so Overture "
                    + "could not tell which inquiry you pressed. Nothing was changed. The list has caught up, so "
                    + "press it again if it is still there"
            }
        }
    }

    enum Outcome {
        case found(Inquiry)
        case refused(Refusal)

        var inquiry: Inquiry? {
            if case .found(let inquiry) = self { return inquiry }
            return nil
        }
    }

    // ONE definition of "find the inquiry behind this press" (L263, L370).
    //
    // `inquiries` must be LIVE (the view's own query, read at the press), never a pass's captured list, for
    // `ShowIdentity.resolve`'s reason (#3690).
    @MainActor
    func resolve(in inquiries: [Inquiry]) -> Outcome {
        guard let inquiry = inquiries.first(where: { $0.persistentModelID == inquiryID }) else {
            // An identifier carries its store only once saved, so its absence marks one minted before the
            // first save, which the save has since replaced (`ShowIdentity.resolve` reads it the same way).
            return .refused(inquiryID.storeIdentifier == nil ? .drawnBeforeItsFirstSave : .gone)
        }
        guard inquiry.createdAt == createdAt else { return .refused(.notTheOneDrawn) }
        return .found(inquiry)
    }

    /// The inquiry behind a row Dan pressed, or nil HAVING SAID SO (#1778): a control that does nothing with
    /// nothing said cannot be told from a broken one. A row with no identity at all (the pass held none for
    /// its id) is `gone`, as a card naming no show is for `ShowResolver.show(for:feedback:)`. `name` is the
    /// row's inquirer, for the sentence.
    @MainActor
    static func inquiry(for identity: InquiryIdentity?, name: String?, in inquiries: [Inquiry],
                        feedback: ActionFeedback) -> Inquiry? {
        guard let identity else {
            feedback.acknowledge(Refusal.gone.sentence(name: name), tone: .warning)
            return nil
        }
        switch identity.resolve(in: inquiries) {
        case .found(let inquiry):
            return inquiry
        case .refused(let refusal):
            feedback.acknowledge(refusal.sentence(name: name), tone: .warning)
            return nil
        }
    }
}
