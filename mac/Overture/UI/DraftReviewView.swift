import SwiftUI

// The Trigger-2 review surface, shown inside a row once the Prep run has found a
// contact and drafted an email. Dan reads the contact (with its confidence), edits
// the draft inline if he likes, then approves or skips. Approving is what later
// hands the email to the throttled Gmail send.
struct DraftReviewView: View {
    let item: QueueItem
    let onApprove: () -> Void
    let onUnapprove: () -> Void
    let onSkip: () -> Void
    let onSaveDraft: (_ subject: String, _ body: String) -> Void

    @State private var editing = false
    @State private var draftSubject = ""
    @State private var draftBody = ""

    private var isApproved: Bool { item.status == .approved }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            contactLine
            draftBlock
            actionRow
        }
        .padding(OVSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OVColor.surfaceSunk.opacity(0.5))
        )
    }

    @ViewBuilder private var contactLine: some View {
        HStack(spacing: OVSpacing.xs) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(OVColor.inkFaint)
            if let name = item.contactName {
                Text(name).fontWeight(.medium).foregroundStyle(OVColor.ink)
                if let role = item.contactRole {
                    Text(role).foregroundStyle(OVColor.inkFaint)
                }
            } else if let email = item.contactEmail {
                Text(email).foregroundStyle(OVColor.ink)
            } else {
                Text("No contact found").foregroundStyle(OVColor.inkFaint)
            }
            if let conf = item.contactConfidence {
                ConfidencePip(confidence: conf)
            }
            Spacer()
            if let email = item.contactEmail {
                Text(email).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private var draftBlock: some View {
        if editing {
            VStack(alignment: .leading, spacing: OVSpacing.xs) {
                TextField("Subject", text: $draftSubject)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $draftBody)
                    .font(OVType.body)
                    .frame(minHeight: 120)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OVColor.line))
                HStack {
                    Button("Save") {
                        onSaveDraft(draftSubject, draftBody)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { editing = false }
                        .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let subject = item.draftSubject {
                    Text(subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(OVColor.ink)
                }
                if let body = item.draftBody {
                    Text(body)
                        .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.draftEditedByDan {
                    Text("Edited").font(.system(size: 10)).foregroundStyle(OVColor.gold)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: OVSpacing.xs) {
            if isApproved {
                Label("Approved to send", systemImage: "checkmark.seal.fill")
                    .font(OVType.meta).foregroundStyle(OVColor.forest)
                Button("Unapprove") { onUnapprove() }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            } else {
                Button { onApprove() } label: {
                    Text("Approve").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .disabled(item.contactEmail == nil)
                Button("Edit") {
                    draftSubject = item.draftSubject ?? ""
                    draftBody = item.draftBody ?? ""
                    editing = true
                }
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
        }
    }
}

private struct ConfidencePip: View {
    let confidence: ContactConfidence
    var body: some View {
        let (label, color): (String, Color) = {
            switch confidence {
            case .high: return ("high confidence", OVColor.forest)
            case .medium: return ("medium confidence", OVColor.gold)
            case .low: return ("low confidence", OVColor.rust)
            }
        }()
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
