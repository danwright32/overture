import Testing
import Foundation
@testable import Overture

// The conversation-reminder cadence (#178) lives in ConversationReminderConfig so Dan can tune it in
// real use without a code change. It persists to UserDefaults: saved values round-trip, and any key
// Dan hasn't touched falls back to the baked default, so behavior is unchanged until he edits.
// A transient suite keeps each test's side effects out of the global defaults.
@Suite("Conversation reminder config persistence")
struct ConversationReminderConfigTests {
    private func transientDefaults() -> UserDefaults {
        let suite = "test.reminderconfig.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func absentKeysFallBackToBakedDefaults() {
        let loaded = ConversationReminderConfig.loaded(from: transientDefaults())
        #expect(loaded.wantsToBookDays == 7)
        #expect(loaded.hasQuestionDays == 2)
        #expect(loaded.interestedDays == 10)
        #expect(loaded.leadBufferDays == 3)
    }

    @Test func savedValuesRoundTrip() {
        let defaults = transientDefaults()
        var config = ConversationReminderConfig()
        config.wantsToBookDays = 5
        config.hasQuestionDays = 1
        config.interestedDays = 14
        config.leadBufferDays = 4
        config.save(to: defaults)

        let loaded = ConversationReminderConfig.loaded(from: defaults)
        #expect(loaded.wantsToBookDays == 5)
        #expect(loaded.hasQuestionDays == 1)
        #expect(loaded.interestedDays == 14)
        #expect(loaded.leadBufferDays == 4)
    }

    @Test func aPartiallySetStoreKeepsBakedDefaultsForTheRest() {
        let defaults = transientDefaults()
        defaults.set(5, forKey: ConversationReminderConfig.Keys.wantsToBook)

        let loaded = ConversationReminderConfig.loaded(from: defaults)
        #expect(loaded.wantsToBookDays == 5)   // the one Dan set
        #expect(loaded.hasQuestionDays == 2)   // the rest stay baked
        #expect(loaded.interestedDays == 10)
        #expect(loaded.leadBufferDays == 3)
    }

    @Test func anExplicitZeroLeadBufferIsHonoured() {
        // 0 is a legitimate buffer (due no later than the event day), and must be distinguished from
        // an absent key (which would fall back to 3).
        let defaults = transientDefaults()
        var config = ConversationReminderConfig()
        config.leadBufferDays = 0
        config.save(to: defaults)
        #expect(ConversationReminderConfig.loaded(from: defaults).leadBufferDays == 0)
    }
}
