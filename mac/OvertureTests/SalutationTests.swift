import Testing
import Foundation
import SwiftData
@testable import Overture

// One shared greeting helper so FollowUp, ConversationReminder, and the per-recipient send greeting
// (Phase 2.5) all produce the same "Hi <first>," in Dan's voice instead of three copies.
@Suite("Salutation")
struct SalutationTests {
    @Test func firstNameTakesTheFirstToken() {
        #expect(Salutation.firstName("Emma Robinson") == "Emma")
    }

    @Test func firstNameTrimsWhitespace() {
        #expect(Salutation.firstName("  Anna Pierre  ") == "Anna")
    }

    @Test func firstNameFallsBackToThereWhenMissing() {
        #expect(Salutation.firstName(nil) == "there")
        #expect(Salutation.firstName("") == "there")
        #expect(Salutation.firstName("   ") == "there")
    }

    @Test func greetingWrapsTheFirstName() {
        #expect(Salutation.greeting(for: "Emma Robinson") == "Hi Emma,")
    }

    // #610: Dan's own preferred wording for the no-name case, replacing "Hi there,".
    @Test func greetingFallsBackToHelloWhenNameMissing() {
        #expect(Salutation.greeting(for: nil) == "Hello,")
        #expect(Salutation.greeting(for: "") == "Hello,")
        #expect(Salutation.greeting(for: "   ") == "Hello,")
    }
}

// #610: a name Prep found behind a generic-inbox address routes the pitch to the right desk
// without pretending the email is addressed to that person directly (the greeting stays
// impersonal, see SalutationTests above).
@Suite("Salutation attn line (#610)")
struct SalutationAttnLineTests {
    private func recipient(name: String?, role: String? = nil,
                           method: ContactMethod?) -> Recipient {
        Recipient(id: "info@org.example", email: "info@org.example", name: name, role: role,
                  provenance: .act, contactMethodRaw: method?.rawValue)
    }

    @Test func genericInboxWithNameOnlyGetsAnAttnLine() {
        let r = recipient(name: "Jane Doe", method: .genericInbox)
        #expect(Salutation.attnLine(for: r) == "Attn: Jane Doe\n\n")
    }

    @Test func genericInboxWithNameAndRoleIncludesTheRole() {
        let r = recipient(name: "Jane Doe", role: "PR Associate Director", method: .genericInbox)
        #expect(Salutation.attnLine(for: r) == "Attn: Jane Doe, PR Associate Director\n\n")
    }

    @Test func genericInboxWithNoNameGetsNoAttnLine() {
        let r = recipient(name: nil, method: .genericInbox)
        #expect(Salutation.attnLine(for: r) == "")
    }

    @Test func namedDecisionMakerNeverGetsAnAttnLineEvenWithAName() {
        let r = recipient(name: "Jane Doe", method: .namedDecisionMaker)
        #expect(Salutation.attnLine(for: r) == "")
    }

    @Test func formOrDMNeverGetsAnAttnLineEvenWithAName() {
        let r = recipient(name: "Jane Doe", method: .formOrDM)
        #expect(Salutation.attnLine(for: r) == "")
    }

    @Test func genericInboxGreetingStaysImpersonalEvenWithAName() {
        let r = recipient(name: "Jane Doe", method: .genericInbox)
        #expect(Salutation.greeting(for: r) == "Hello,")
    }

    @Test func namedDecisionMakerGreetingStaysPersonal() {
        let r = recipient(name: "Jane Doe", method: .namedDecisionMaker)
        #expect(Salutation.greeting(for: r) == "Hi Jane,")
    }
}
