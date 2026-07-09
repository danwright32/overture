import Testing
import Foundation

// Regression guard for #631: ArchiveView and QueueView each defined their own copy of the
// "Send this email now?" confirm alert and the "Reconnect Gmail" alert, identical titles,
// buttons, and message text, copy pasted rather than shared. Both screens must route through
// one shared modifier so the two copies can never drift apart again.
@Suite("Send-confirm and reconnect-Gmail alerts are shared, not duplicated")
struct SendConfirmAndReconnectAlertsSharedTests {
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    private static let sendConfirmMessageBody =
        "This sends one email right now, to this recipient only. Nothing else goes out."
    private static let reconnectMessageBody =
        "Your Gmail access has expired or was revoked, so nothing was sent."

    @Test func archiveViewUsesTheSharedAlertsModifier() {
        #expect(!archiveView.isEmpty)
        #expect(archiveView.contains(".sendConfirmAndReconnectAlerts("),
                "ArchiveView must attach the shared alerts modifier instead of declaring its own .alert(...) calls (#631).")
    }

    @Test func queueViewUsesTheSharedAlertsModifier() {
        #expect(!queueView.isEmpty)
        #expect(queueView.contains(".sendConfirmAndReconnectAlerts("),
                "QueueView must attach the shared alerts modifier instead of declaring its own .alert(...) calls (#631).")
    }

    @Test func neitherViewStillDeclaresItsOwnSendConfirmAlert() {
        #expect(!archiveView.contains(".alert(\"Send this email now?\""),
                "ArchiveView must not keep its own copy of the send-confirm alert once it's shared (#631).")
        #expect(!queueView.contains(".alert(\"Send this email now?\""),
                "QueueView must not keep its own copy of the send-confirm alert once it's shared (#631).")
    }

    @Test func neitherViewStillDeclaresItsOwnReconnectAlert() {
        #expect(!archiveView.contains(".alert(\"Reconnect Gmail\""),
                "ArchiveView must not keep its own copy of the reconnect alert once it's shared (#631).")
        #expect(!queueView.contains(".alert(\"Reconnect Gmail\""),
                "QueueView must not keep its own copy of the reconnect alert once it's shared (#631).")
    }

    @Test func messageTextLivesOnlyInTheSharedHelperNotInEitherView() {
        #expect(!archiveView.contains(Self.sendConfirmMessageBody),
                "The send-confirm message text must live only in the shared alerts helper, not copy pasted into ArchiveView (#631).")
        #expect(!queueView.contains(Self.sendConfirmMessageBody),
                "The send-confirm message text must live only in the shared alerts helper, not copy pasted into QueueView (#631).")
        #expect(!archiveView.contains(Self.reconnectMessageBody),
                "The reconnect message text must live only in the shared alerts helper, not copy pasted into ArchiveView (#631).")
        #expect(!queueView.contains(Self.reconnectMessageBody),
                "The reconnect message text must live only in the shared alerts helper, not copy pasted into QueueView (#631).")
    }
}
