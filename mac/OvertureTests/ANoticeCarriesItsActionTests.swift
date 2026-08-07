import Testing
import Foundation

// #2250: a masthead notice that names a fault must carry the action for it.
//
// The OmniFocus failure says "OmniFocus sync failing" and hides its remedy (retry the sync, check the app
// is installed and has Automation permission) in a tooltip. That is L49, a caveat nobody hovers over is a
// caveat nobody reads, and L80, a message identifying a specific fault must carry the action for it. The
// cost of missing it is real: follow-up tasks may be silently not getting created the whole time.
//
// The capability is what matters here, not the one caller. No message on this surface could carry an
// action at all, which is also what leaves #1805's shortfall report naming a set of shows and offering
// nothing to do with them.
//
// The action is NAMED by the domain and PERFORMED by the view. A closure on the notice would make it
// neither Equatable nor Sendable, and the masthead diffs these values on every write; a named case keeps
// the notice a plain value a test can read, and leaves the view holding the how.
@Suite("A notice carries its action (#2250)")
struct ANoticeCarriesItsActionTests {

    @Test func theOmniFocusFailureCarriesItsRetry() {
        let notices = AppNotices.current(omniFocusFailing: true, status: StatusLine())
        #expect(notices.first?.action == .retryOmniFocusSync)
    }

    // The remedy moves out of the tooltip and into the line, because that is the complaint. What stays in
    // the tooltip is the part that explains rather than instructs.
    @Test func theRemedyIsInTheLineNotOnlyInAHover() {
        let notice = AppNotices.current(omniFocusFailing: true, status: StatusLine()).first
        #expect(notice?.action?.title.isEmpty == false)
    }

    // An ordinary message carries no action, so the masthead never grows a button beside a receipt.
    @Test func aPlainReceiptCarriesNoAction() {
        var status = StatusLine()
        status.set("Scouted 12 shows")
        let notices = AppNotices.current(omniFocusFailing: false, status: status)
        #expect(notices.count == 1)
        #expect(notices.first?.action == nil)
    }

    // Two notices at once keep their own actions: the standing fault has one, the run receipt does not.
    @Test func eachNoticeKeepsItsOwnAction() {
        var status = StatusLine()
        status.set("Scouted 12 shows")
        let notices = AppNotices.current(omniFocusFailing: true, status: status)
        #expect(notices.count == 2)
        #expect(notices.first?.action == .retryOmniFocusSync)
        #expect(notices.last?.action == nil)
    }

    // A notice is identified by its text, and the masthead diffs on that. An action must not break it.
    @Test func aNoticeWithAnActionIsStillAPlainComparableValue() {
        let a = AppNotice(text: "x", tone: .warning, action: .retryOmniFocusSync)
        let b = AppNotice(text: "x", tone: .warning, action: .retryOmniFocusSync)
        #expect(a == b)
        #expect(a.id == b.id)
    }
}
