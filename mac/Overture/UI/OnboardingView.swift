import SwiftUI
import UserNotifications

// #270 / Phase 6: the first-run onboarding checklist. One row per interactive grant the resident
// process needs but can only obtain while Dan is present. Each row shows a green check when satisfied
// and a button to grant it otherwise; every button gives visible feedback, including the no-op
// "already done" case (the no-silent-no-op rule, #285). Pure decisions live in OnboardingState.
struct OnboardingView: View {
    var onClose: () -> Void = {}

    @State private var gmail = GmailAuthManager.shared.isConnected
    @State private var omniFocus = false
    @State private var notifications = false
    @State private var agent = OnboardingState.agentInstalled()
    @State private var status: String?
    @State private var busy = false

    private var state: OnboardingState {
        OnboardingState(gmailConnected: gmail, omniFocusGranted: omniFocus,
                        notificationsAuthorized: notifications, loginAgentInstalled: agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Overture").font(.title2).bold()
            Text("Grant these once, here, so Overture can keep working while you're away from your desk.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 14) {
                row(.gmail, title: "Connect Gmail",
                    detail: "Lets Overture send approved emails and notice replies.",
                    actionTitle: "Connect", action: connectGmail)
                row(.omniFocus, title: "Allow OmniFocus control",
                    detail: "Lets Overture create your follow-up tasks.",
                    actionTitle: "Allow", action: grantOmniFocus)
                row(.notifications, title: "Allow notifications",
                    detail: "Lets Overture alert you when something needs you.",
                    actionTitle: "Allow", action: grantNotifications)
                row(.loginAgent, title: "Start at login",
                    detail: "Keeps Overture resident in the menu bar so the syncs run unattended.",
                    actionTitle: "Re-check", action: recheckAgent)
            }

            if let status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if state.isComplete {
                    Label("All set", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Spacer()
                Button(state.isComplete ? "Done" : "Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470)
        .task { await refreshAsync() }
    }

    @ViewBuilder
    private func row(_ step: OnboardingStep, title: String, detail: String,
                     actionTitle: String, action: @escaping () -> Void) -> some View {
        let done = state.isSatisfied(step)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if done {
                Image(systemName: "checkmark").foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action).disabled(busy)
            }
        }
    }

    // MARK: - Grant actions (each gives feedback, including the already-satisfied no-op)

    private func connectGmail() {
        busy = true; status = "Opening Google sign-in…"
        Task {
            do { try await GmailAuthManager.shared.connect(); status = "Gmail connected." }
            catch { status = "Couldn't connect Gmail: \(error.localizedDescription)" }
            busy = false
            await refreshAsync()
        }
    }

    private func grantOmniFocus() {
        busy = true; status = "Asking macOS for OmniFocus permission…"
        Task { @MainActor in
            // A REAL Apple event triggers the system consent dialog; the silent probe (#268) never does.
            // A harmless read is enough to provoke the one-time grant while Dan is present.
            _ = try? AppleScriptOmniFocusClient().existingOvertureTasks()
            await refreshAsync()
            status = omniFocus
                ? "OmniFocus permission granted."
                : "Still not granted — allow Overture in the prompt, or in System Settings ▸ Privacy & Security ▸ Automation."
            busy = false
        }
    }

    private func grantNotifications() {
        busy = true; status = "Requesting notification permission…"
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshAsync()
            status = granted
                ? "Notifications allowed."
                : "Not allowed — enable Overture in System Settings ▸ Notifications."
            busy = false
        }
    }

    private func recheckAgent() {
        agent = OnboardingState.agentInstalled()
        status = agent
            ? "Login agent is installed."
            : "Not installed yet — run your Overture build once to install it."
    }

    private func refresh() {
        gmail = GmailAuthManager.shared.isConnected
        omniFocus = OmniFocusAutomationPermission.current() == .granted
        agent = OnboardingState.agentInstalled()
    }

    private func refreshAsync() async {
        refresh()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = settings.authorizationStatus == .authorized
    }
}
