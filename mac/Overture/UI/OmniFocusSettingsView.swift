import SwiftUI

// #2397: what is left of the reminder-timing sheet (#178/#931) once the conversation-state cadence is
// retired. Its four steppers tuned intervals that no longer exist: three of them were "how long to wait
// before nudging a conversation in this state", and the fourth was the lead buffer that pulled such a
// reminder forward of the event.
//
// The look-ahead window survives, and it is the reason this sheet does rather than being deleted with
// them: OmniFocus sync only fires while Overture is open, so how far ahead it looks is a real setting with
// no other home. Renamed to say what it is now, because a sheet called "Reminder timing" holding one
// OmniFocus number would be a title describing something that had gone.
//
// The on/off toggle deliberately stays OUT of here (#931): it lives once, in the toolbar menu that opens
// this sheet, and two controls doing one job is what that issue removed.
struct OmniFocusSettingsView: View {
    @AppStorage(OmniFocusSyncConfig.Keys.enabled)
    private var omniFocusEnabled = OmniFocusSyncConfig().enabled
    @AppStorage(OmniFocusSyncConfig.Keys.horizon)
    private var omniFocusHorizon = OmniFocusSyncConfig().horizonDays

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text("OmniFocus sync").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            if omniFocusEnabled {
                Text("OmniFocus is syncing due follow-ups. It only fires while Overture is open, so it looks ahead by:")
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                row("Look-ahead window", value: $omniFocusHorizon, range: 1...60)
            } else {
                // An honest empty state rather than a stepper that changes nothing: with sync off there is
                // no window to look ahead through, and the control that turns it on is not on this sheet.
                Text("Sync is off. Turn it on from the OmniFocus menu in the toolbar, and the look-ahead window appears here.")
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
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
    OmniFocusSettingsView()
}
