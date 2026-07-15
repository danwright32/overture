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

    func body(content: Content) -> some View {
        content
            // #360: the send confirmation is now the branded SendConfirmSheet (From / To / Subject +
            // a preview of the exact body), not a stock system alert, since confirming it sends a real
            // email to a real recipient. The reconnect prompt stays a plain alert (it's a recoverable
            // interruption, not the consequential commit).
            .sheet(item: $pendingConfirm) { pending in
                SendConfirmSheet(
                    confirmation: pending.confirmation,
                    onSend: { onSend(pending.id) },
                    onCancel: { pendingConfirm = nil }
                )
            }
            .alert("Reconnect Gmail", isPresented: $showReconnect) {
                Button("Connect Gmail") { onConnectGmail() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again.")
            }
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
