import SwiftUI
import SwiftData

// #1436: Dan writes and sends his own first reply to a hire inquiry, through the standalone
// InquiryReplySender (never the AI drip). The sheet keeps working, still-alive, and failed as three
// visibly different states (CLAUDE.md): a live "Sending" state, and a genuine failure that converts to
// an actionable error with a retry rather than a dead spinner or a silent fake success.
struct InquiryReplySheet: View {
    let inquiry: Inquiry
    var sender: MailSender = ProspectMutations.liveSender()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var subject = "Re: your inquiry"
    @State private var replyBody = ""
    @State private var phase: Phase = .compose

    private enum Phase: Equatable { case compose, sending, failed(String) }

    private var canSend: Bool {
        (inquiry.inquirerEmail?.isEmpty == false)
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !replyBody.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header
            switch phase {
            case .compose, .sending:
                compose
            case .failed(let message):
                Text(message).font(OVType.body).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(OVSpacing.lg)
        .frame(width: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(InquiryCopy.replyTitle(to: inquiry.inquirerName)).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OVColor.ink)
            if let email = inquiry.inquirerEmail, !email.isEmpty {
                Text(email).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            } else {
                Text("No email on file for this inquiry, so it can't be sent from here.")
                    .font(OVType.meta).foregroundStyle(OVColor.rust)
            }
            if let notes = inquiry.notes, !notes.isEmpty {
                Text(notes).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                .disabled(phase == .sending)
            TextEditor(text: $replyBody)
                .font(OVType.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
                .disabled(phase == .sending)
        }
    }

    private var footer: some View {
        HStack {
            if phase == .sending {
                ProgressView().controlSize(.small)
                Text("Sending your reply...").font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                .disabled(phase == .sending)
            if case .failed = phase {
                Button("Back") { phase = .compose }.buttonStyle(.plain).foregroundStyle(OVColor.forest)
            }
            Button(action: send) {
                Text("Send reply").font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .disabled(!canSend || phase == .sending)
        }
    }

    private func send() {
        phase = .sending
        Task {
            let ok = await InquiryReplySender.sendFirstReply(inquiry, subject: subject, body: replyBody,
                                                             now: Date(), sender: sender)
            if ok {
                // Persist the sent stamp and thread so reply-watching can attach; a save failure is
                // surfaced, never swallowed.
                do {
                    try context.save()
                    dismiss()
                } catch {
                    phase = .failed("The reply was sent, but saving it here failed. Reopen Overture before relying on reply tracking for this one.")
                }
            } else {
                phase = .failed("The reply couldn't be sent. Check that Gmail is connected, then try again.")
            }
        }
    }
}
