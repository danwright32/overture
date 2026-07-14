import SwiftUI

// A small control to tune the conversation-reminder cadence (#178). The intervals (one per active
// state) and the lead buffer before the event start as the baked ConversationReminderConfig defaults;
// this lets Dan adjust them in real use without a code change. Each stepper is bound through
// @AppStorage under the same keys ConversationReminderConfig reads, so editing here updates the
// loaded config that drives ConversationReminder.due. Whole days, to match the calculator.
struct ReminderSettingsView: View {
    @AppStorage(ConversationReminderConfig.Keys.wantsToBook)
    private var wantsToBookDays = ConversationReminderConfig().wantsToBookDays
    @AppStorage(ConversationReminderConfig.Keys.hasQuestion)
    private var hasQuestionDays = ConversationReminderConfig().hasQuestionDays
    @AppStorage(ConversationReminderConfig.Keys.interested)
    private var interestedDays = ConversationReminderConfig().interestedDays
    @AppStorage(ConversationReminderConfig.Keys.leadBuffer)
    private var leadBufferDays = ConversationReminderConfig().leadBufferDays
    @AppStorage(OmniFocusSyncConfig.Keys.enabled)
    private var omniFocusEnabled = OmniFocusSyncConfig().enabled
    @AppStorage(OmniFocusSyncConfig.Keys.horizon)
    private var omniFocusHorizon = OmniFocusSyncConfig().horizonDays

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text("Reminder timing").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text("How long to wait before nudging an active conversation, and how close to the event a reminder may still fire.")
                .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            row("Verbal yes, not booked", value: $wantsToBookDays, range: 1...60)
            row("Owes a reply", value: $hasQuestionDays, range: 1...60)
            row("Interested, going quiet", value: $interestedDays, range: 1...90)
            Divider()
            row("Lead buffer before the event", value: $leadBufferDays, range: 0...30)
            Divider()
            Toggle(isOn: $omniFocusEnabled) {
                Text("Sync due reminders to OmniFocus").font(OVType.body).foregroundStyle(OVColor.ink)
            }
            if omniFocusEnabled {
                Text("Adds a follow-up task to your Outreach project (deferred to 11am, due 6pm on the day it's due) so a near-event lead reaches you when you're away from Overture. Only fires while Overture is open, so it looks ahead by:")
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                row("Look-ahead window", value: $omniFocusHorizon, range: 1...60)
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 340)
    }

    private func row(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label).font(OVType.body).foregroundStyle(OVColor.ink)
                Spacer(minLength: OVSpacing.sm)
                Text(Plural.count(value.wrappedValue, "day"))   // #885
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft).monospacedDigit()
            }
        }
    }
}

#Preview {
    ReminderSettingsView()
}
