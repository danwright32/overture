import SwiftUI
import SwiftData

// #1027: the inline FIX (correct the URL) and CONFIRM (this page is right, stop nagging) controls for a
// failing source. ONE component, used in both the end-of-scout popup and the durable Sources sheet, so
// the two surfaces cannot drift into offering different actions or wording.
//
// FIX is offered wherever a wrong address could be the cause (failure.offersFix). CONFIRM is offered
// only on a page that read fine but was empty (failure.offersConfirm). Neither is gated on
// hasUnreadChanges: a no_dated_content failure always leaves that flag set, so gating on it would
// disable CONFIRM in the exact case it is meant for. confirmEmpty anchors to the bytes last read, and
// the ingest match is exact, so a stale confirmation can only fail to suppress (a harmless re-nag),
// never suppress the wrong page.
struct SourceFixConfirmActions: View {
    let source: WatchedSource
    let failure: SourceFailure
    // Called with the source id when Dan saves a corrected URL, so the popup can read the ones he fixed.
    var onFixed: (String) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback

    @State private var editing = false
    @State private var draftURL = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xxs) {
            if editing {
                TextField("Their events or season page", text: $draftURL)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit(saveURL)
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: OVSpacing.xs) {
                Spacer()
                if failure.offersConfirm, !editing {
                    capsule(SourceFixConfirmCopy.confirmTitle, tint: OVColor.forest, action: confirm)
                        .help(SourceFixConfirmCopy.confirmHelp)
                }
                if failure.offersFix {
                    if editing {
                        capsule(SourceFixConfirmCopy.cancelTitle, tint: OVColor.inkSoft) {
                            editing = false; message = nil
                        }
                        capsule(SourceFixConfirmCopy.saveTitle, tint: OVColor.forest, action: saveURL)
                    } else {
                        capsule(SourceFixConfirmCopy.fixTitle, tint: OVColor.inkSoft) {
                            draftURL = source.listingsURL ?? ""
                            message = nil
                            editing = true
                        }
                        .help(SourceFixConfirmCopy.fixHelp)
                    }
                }
            }
        }
    }

    private func capsule(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.horizontal, OVSpacing.sm)
                .padding(.vertical, 4)
                .background(Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func saveURL() {
        switch WatchlistEditing.editURL(source, to: draftURL, in: context) {
        case .saved(let id):
            editing = false
            message = nil
            feedback.acknowledge(SourceFixConfirmCopy.fixedAck(org: source.orgName))
            onFixed(id)
        case .invalidURL:
            message = WatchlistEditing.invalidURLMessage
        case .conflict(let org):
            message = SourceFixConfirmCopy.conflictMessage(org: org)
        case .refused(let org):
            message = WatchlistEditing.resumeRefusedMessage(orgName: org)
        }
    }

    private func confirm() {
        switch WatchlistEditing.confirmEmpty(source, in: context) {
        case .confirmed:
            feedback.acknowledge(SourceFixConfirmCopy.confirmedAck(org: source.orgName))
        case .noHash:
            feedback.acknowledge(SourceFixConfirmCopy.confirmedNoHashAck(org: source.orgName),
                                 tone: .warning)
        }
    }
}

// The component's own words, kept out of the view body so the copy inventory reads them and a test can
// pin them (#863/#885).
enum SourceFixConfirmCopy {
    static let fixTitle = "Fix the address"
    static let fixHelp = "Correct this source's web address, then read it to check"
    static let saveTitle = "Save"
    static let cancelTitle = "Cancel"
    static let confirmTitle = "This page is right"
    static let confirmHelp = "Keep this page but stop flagging it, until its contents change"

    static func fixedAck(org: String) -> String { "Updated \(org)'s address." }
    static func confirmedAck(org: String) -> String {
        "Marked \(org)'s page as right. It won't be flagged again until it changes."
    }
    static func confirmedNoHashAck(org: String) -> String {
        "Cleared the flag on \(org), but read it once so a quiet page can stay quiet."
    }
    static func conflictMessage(org: String) -> String {
        "You already watch \(org) at that address."
    }
}
