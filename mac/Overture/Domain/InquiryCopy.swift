import Foundation

// #1436/#885: the inquiry views' computed copy lives here, beside a test, not inside a SwiftUI body
// where no test can reach it. Static labels stay in the views; only the sentences that fold in a value
// or choose between wordings belong here.
enum InquiryCopy {
    static func replyTitle(to inquirerName: String) -> String {
        "Reply to \(inquirerName)"
    }

    // "Gala at Weill Recital Hall", or whichever parts are known, or empty when neither is.
    static func rowSubtitle(event: String, venue: String?) -> String {
        let e = event.trimmingCharacters(in: .whitespaces)
        let v = venue?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (e.isEmpty, v.isEmpty) {
        case (false, false): return "\(e) at \(v)"
        case (false, true): return e
        case (true, false): return "at \(v)"
        case (true, true): return ""
        }
    }

    // The one-line lifecycle state shown on the row.
    static func rowState(sentAt: Date?, replied: Bool) -> String {
        if sentAt == nil { return "Awaiting your first reply" }
        if replied { return "They replied" }
        return "Sent, waiting to hear back"
    }
}
