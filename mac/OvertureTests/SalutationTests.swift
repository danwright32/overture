import Testing
import Foundation
import SwiftData

// One shared greeting helper so FollowUp and PostEventPrompt produce the same "Hi <first>," in Dan's
// voice instead of two copies.
//
// #2545 removed its third caller and the attn-line suite that used to sit below this one. The pitch's
// own greeting is written into the body by whoever writes the body, so nothing here is reached from the
// pitch path any more: two places that can greet is the defect #2545 fixed. What a pitch's greeting must
// LOOK like is now a runbook rule, and what makes one acceptable is DraftGreeting's.
@Suite("Salutation")
struct SalutationTests {
    @Test func firstNameTakesTheFirstToken() {
        #expect(Salutation.firstName("Emma Robinson") == "Emma")
    }

    @Test func firstNameTrimsWhitespace() {
        #expect(Salutation.firstName("  Nora Calder  ") == "Nora")
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
