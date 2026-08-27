import Testing
import Foundation
import SwiftData
import SwiftUI
import ViewInspector
@testable import Overture

// #2017, the rendering half. The pure suite proves the confirmation CARRIES the candidates and that the
// send honours a selection; only a rendered sheet can show the tick list actually reaches the screen, and
// that half is exactly what a model test cannot see (#2015 shipped a card whose model was right and whose
// screen never showed it).
//
// This is also the screen I deliberately did not drive the live app to, because its primary button sends a
// real email to a real venue. Rendering it here proves the control is there without standing next to that.
//
// @MainActor: inspecting a SwiftUI view must run on the main actor, or it crashes intermittently depending
// on the parallel runner's thread. Every ViewInspector suite in this repo carries it.
@MainActor
@Suite("The send sheet offers the contact picker (#2017)")
struct SendConfirmSheetPickerTests {
    private func show(contacts: Int) throws -> Prospect {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let key = Prospect.makeNaturalKey(groupName: "Lumen", performanceDate: "2026-09-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "Lumen", discipline: "choral", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved, ingestedAt: Date())
        p.draftSubject = "Photographs of your September concert"
        p.draftBody = "Hello,\n\nI photograph performing arts in New York."
        ctx.insert(p)
        let people = [("ann@org.example", "Ann Alder"), ("ben@org.example", "Ben Ortiz")]
        for (email, name) in people.prefix(contacts) {
            let r = Recipient(id: email, email: email, name: name, provenance: .presenter)
            p.recipients.append(r)
            ctx.insert(r)
        }
        try? ctx.save()
        return p
    }

    private func sheet(_ p: Prospect, rebuildable: Bool) throws -> SendConfirmSheet {
        let confirmation = try #require(SendConfirmation(prospect: p))
        return SendConfirmSheet(
            confirmation: confirmation, onSend: {}, onCancel: {},
            rebuild: rebuildable ? { selected, _ in SendConfirmation(prospect: p, selecting: selected) } : nil
        )
    }

    // Every contact is on the screen by NAME and by ADDRESS, because Dan picks by recognising a person and
    // confirms by reading the address the email is going to.
    @Test func bothContactsAppearOnTheSheet() throws {
        let view = try sheet(try show(contacts: 2), rebuildable: true)

        let text = try view.inspect().findAll(ViewType.Text.self).map { try? $0.string() }
        #expect(text.contains("Ann Alder"))
        #expect(text.contains("Ben Ortiz"))
        #expect(text.contains("ann@org.example"))
        #expect(text.contains("ben@org.example"))
        #expect(text.contains(SendConfirmCopy.chooseLabel))
    }

    // A tick per contact, so the choice is actually made here rather than merely described.
    @Test func eachContactCarriesItsOwnTick() throws {
        let view = try sheet(try show(contacts: 2), rebuildable: true)

        #expect(try view.inspect().findAll(ViewType.Toggle.self).count == 2)
    }

    // The how-it-goes-out choice sits on the same screen, which is the second half of what Dan asked for:
    // "It should send all three now but also give me the option to put them all on the same email."
    @Test func theTogetherOrSeparatelyChoiceIsOnTheSameScreen() throws {
        let view = try sheet(try show(contacts: 2), rebuildable: true)

        let text = try view.inspect().findAll(ViewType.Text.self).map { try? $0.string() }
        #expect(text.contains(SendModeCopy.together))
        #expect(text.contains(SendModeCopy.separately))
    }

    // One contact is no choice at all, so the sheet stays exactly the screen it was. A picker offering a
    // single tick would be a control that cannot change anything (#1778).
    @Test func aOneContactShowIsOfferedNoPicker() throws {
        let view = try sheet(try show(contacts: 1), rebuildable: true)

        let text = try view.inspect().findAll(ViewType.Text.self).map { try? $0.string() }
        #expect(text.contains(SendConfirmCopy.chooseLabel) == false)
        #expect(try view.inspect().findAll(ViewType.Toggle.self).isEmpty)
    }

    // The follow-up and note sends come through this same sheet with nothing to choose, and must be left
    // untouched by all of the above.
    @Test func aCallerThatOffersNoChoiceGetsNoPicker() throws {
        let view = try sheet(try show(contacts: 2), rebuildable: false)

        let text = try view.inspect().findAll(ViewType.Text.self).map { try? $0.string() }
        #expect(text.contains(SendConfirmCopy.chooseLabel) == false)
        #expect(try view.inspect().findAll(ViewType.Toggle.self).isEmpty)
    }
}
