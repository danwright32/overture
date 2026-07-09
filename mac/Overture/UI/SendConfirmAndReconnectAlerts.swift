import SwiftUI

// #631: ArchiveView and QueueView each defined their own copy of the send-confirm and
// reconnect-Gmail alerts, identical titles, buttons, and message text, copy pasted rather than
// shared. Both screens now attach this one modifier instead, so the two copies can't drift out
// of sync over time.
private struct SendConfirmAndReconnectAlerts: ViewModifier {
    @Binding var pendingConfirm: PendingSend?
    @Binding var showReconnect: Bool
    let onSend: (String) -> Void
    let onConnectGmail: () -> Void

    private var sendConfirmBinding: Binding<Bool> {
        Binding(get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert("Send this email now?", isPresented: sendConfirmBinding, presenting: pendingConfirm) { pending in
                Button("Send") { onSend(pending.id) }
                Button("Cancel", role: .cancel) { pendingConfirm = nil }
            } message: { pending in
                Text(Self.sendConfirmMessage(pending))
            }
            .alert("Reconnect Gmail", isPresented: $showReconnect) {
                Button("Connect Gmail") { onConnectGmail() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again.")
            }
    }

    static func sendConfirmMessage(_ pending: PendingSend) -> String {
        "To: \(pending.confirmation.recipient)\nSubject: \(pending.confirmation.subject)\n\nThis sends one email right now, to this recipient only. Nothing else goes out."
    }
}

extension View {
    // Attach the shared send-confirm and reconnect-Gmail alerts to a screen that owns its own
    // pendingConfirm/showReconnect state (ArchiveView, QueueView).
    func sendConfirmAndReconnectAlerts(
        pendingConfirm: Binding<PendingSend?>,
        showReconnect: Binding<Bool>,
        onSend: @escaping (String) -> Void,
        onConnectGmail: @escaping () -> Void
    ) -> some View {
        modifier(SendConfirmAndReconnectAlerts(
            pendingConfirm: pendingConfirm,
            showReconnect: showReconnect,
            onSend: onSend,
            onConnectGmail: onConnectGmail
        ))
    }
}
