import Testing
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
        #expect(Salutation.greeting(for: nil) == "Hi there,")
    }
}
