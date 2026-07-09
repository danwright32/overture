import Foundation

// Pure view-model helpers for the approval queue: labels, badges, timing hints,
// and date groupings. Ported from the engine's queueView.ts so the display logic
// is identical across the (retired) web app and this native app, and unit-testable
// without SwiftData. The SwiftUI views build QueueItem values from Prospect models.

struct QueueItem: Identifiable, Equatable, Sendable {
    let id: String
    let groupName: String
    let discipline: String
    let venue: String?
    let performanceDate: String?
    let sourceListingURL: String?
    let websiteURL: String?
    let priorRelationship: String
    let production: String
    let profile: String
    let coverage: String
    let fitScore: Int
    let tier: String
    let fitReason: String
    let matchedClientName: String?
    let possibleMatchSource: String?
    let possibleMatchName: String?
    let status: ReviewStatus

    // Trigger 2: the drafted email, when present. Contact identity (name/role/email/confidence/
    // method/form URL) lives per-recipient on `contacts` now (#654); see `primaryContact`.
    var draftSubject: String? = nil
    var draftBody: String? = nil
    var draftEditedByDan: Bool = false
    var outcome: Outcome = .noResponse
    // Phase F (#424): the show's status derived from its contacts, snapshotted at build time.
    var performanceStatus: PerformanceStatus = .new
    var sentAt: Date? = nil
    // At least one recipient is still pending with an address, so this performance can still send (#394).
    // Drives the Send button under fan-out: the lead `sentAt` rollup flips on the FIRST recipient, but
    // the button must persist until the LAST recipient goes, so it gates on this, not on `isSent`.
    var hasPendingRecipient: Bool = false
    var sendError: String? = nil
    var lostReason: String? = nil
    var classificationConfidence: String = Confidence.confident.rawValue
    var confidenceReviewedByDan: Bool = false
    var classificationOverriddenByDan: Bool = false
    var bookingSuggested: Bool = false
    var outcomeSourceRaw: String? = nil
    var runEndDate: String? = nil
    var partOfRelatedRun: Bool = false
    // The show dropped out of the feed across enough scouts to count as cancelled/pulled (#133).
    var disappearedFromFeed: Bool = false
    // The performance's recipients as flat snapshots for the per-contact conversation surface (#418 B1).
    // Empty for a single-contact legacy view; built from prospect.recipients in send order.
    var contacts: [RecipientSnapshot] = []

    // Show the "unsure" mark only for a rules-guessed classification Dan hasn't reviewed (#32).
    var isClassificationUncertain: Bool {
        classificationConfidence == Confidence.uncertain.rawValue && !confidenceReviewedByDan
    }

    // True when Downbeat or Gmail auto-detected a booking (#114); Dan must confirm before it locks.
    var isAutoBooked: Bool {
        outcome == .booked && outcomeSourceRaw == OutcomeSource.auto.rawValue
    }

    // True when a reply was auto-detected from Gmail (#219); Dan can mark it "not a real reply".
    var isAutoReplied: Bool {
        outcome == .replied && outcomeSourceRaw == OutcomeSource.auto.rawValue
    }

    var isSent: Bool { sentAt != nil }
    var isHighFit: Bool { tier == "high" }
    var isKept: Bool { status == .queued || status == .drafted || status == .approved || status == .contacted }
    var hasDraft: Bool { draftBody != nil }
    // Lost: every contact resolved away (derived), or Dan marked the lead lost by hand / closing note.
    // The row shows an editable reason note. (Phase F: derive from the contacts, not only the lead.)
    var isLost: Bool {
        performanceStatus == .lostDoorOpen || performanceStatus == .lostNotInterested
            || outcome == .lostSoft || outcome == .lostHard
    }
    // Confirmed booked (auto-detected or hand-marked); the row reads as Booked, not a lead to pitch.
    var isBooked: Bool { performanceStatus == .booked || outcome == .booked }
    // A booking Dan has confirmed (manual source) is settled and leaves the reach-out queue (#201);
    // an auto-detected one (isAutoBooked) stays until he confirms it, so a wrong match can be caught.
    var isConfirmedBooking: Bool { outcome == .booked && outcomeSourceRaw == OutcomeSource.manual.rawValue }

    // #596: a quick-glance hint when a prospect carries more than one recipient (e.g. 2 named
    // performers found for a self-produced show, #366), so Dan doesn't have to expand every row
    // to see when multiple people were found. nil for the common single-contact case (no clutter).
    var contactCountLabel: String? {
        contacts.count > 1 ? "\(contacts.count) contacts" : nil
    }

    // #654: the single contact a show-level display (the review card's contactLine) shows, replacing
    // the old lead-level mirror fields. Mirrors PrepImporter's own selection rule exactly: act or
    // performer preferred (mutually exclusive per performance, #587), else the first contact.
    var primaryContact: RecipientSnapshot? {
        contacts.first(where: { $0.provenance == .act || $0.provenance == .performer }) ?? contacts.first
    }
}

// One contact on a performance, flattened for the conversation surface (#418 B1). The per-contact
// status Dan reads is DERIVED from send/reply/resolution/bounced state; only the terminal resolutions
// and bounce aren't otherwise knowable, which is why the model stores those, not a status enum.
struct RecipientSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let email: String?
    let role: String?
    let provenance: RecipientProvenance
    let sendState: SendState
    let replied: Bool
    let lastReplyText: String?
    let resolution: RecipientResolution?
    let bounced: Bool
    let outcomeSource: OutcomeSource?
    // Only meaningful when sendState == .suppressed (#542); defaulted so existing call sites that
    // never touch a suppressed recipient don't need updating.
    var suppressionReason: RecipientSuppressionReason = .bookedElsewhere
    var replyDraftSubject: String? = nil
    var replyDraftBody: String? = nil
    var replyDraftRequestedAt: Date? = nil
    var intentHint: String? = nil
    var replyDraftEditedByDan: Bool = false
    // #642 (#634 Phase D): a performer's direct-address draft, so the review screen can show Dan
    // exactly what this specific contact will receive instead of the shared draft body. Only ever
    // set when provenance == .performer; defaulted so existing call sites don't need updating.
    var overrideBody: String? = nil
    // #652: this contact's OWN conversation state, mirroring what QueueItem carries lead-level today,
    // so the per-contact review controls can read and act on it directly.
    var conversationState: ConversationState? = nil
    var conversationStateSource: OutcomeSource? = nil
    var conversationRemindedAt: Date? = nil
    // #654: moved from the now-deleted lead-level QueueItem fields, since contact confidence/method/
    // form-URL are genuinely per-recipient data.
    var contactConfidence: ContactConfidence? = nil
    var contactMethod: ContactMethod? = nil
    var contactFormURL: String? = nil

    // The AI reply drafter has produced a draft Dan can send or copy (#420 C6).
    var hasReplyDraft: Bool { (replyDraftBody?.isEmpty == false) }

    // The deterministic self-check findings to surface on the reply draft (#456), or none once Dan has
    // edited it: it's his text then, the same suppression the cold path applies via draftEditedByDan
    // (#459). Lives here, not in the view, so the suppression is unit-testable.
    func replyDraftFindings(knownsDate: Bool, knownsVenue: Bool) -> [DraftIssue] {
        guard !replyDraftEditedByDan, let body = replyDraftBody else { return [] }
        return DraftCheck.findings(in: body, knownsDate: knownsDate, knownsVenue: knownsVenue)
    }
    // A draft was requested but hasn't arrived yet: show progress.
    var isDraftingReply: Bool { replyDraftRequestedAt != nil && !hasReplyDraft }

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return "Unknown contact"
    }

    // A reply Overture auto-detected (not one Dan hand-marked): only these get a "not a real reply"
    // dismiss control.
    var isAutoReplied: Bool { replied && outcomeSource != .manual }

    // A bounce Overture auto-detected (not one Dan hand-marked): only these get a "not really
    // bounced" dismiss control (#398).
    var isAutoBounced: Bool { bounced && outcomeSource != .manual }

    // The plain-language status line. Terminal marks win; then bounce; then reply; then send state.
    var statusLabel: String {
        if let resolution {
            switch resolution {
            case .booked: return "Booked"
            case .declinedSoft: return "Closed (not now)"
            case .declinedHard: return "Closed (not interested)"
            }
        }
        if bounced { return "Bounced" }
        if replied { return "In conversation" }
        switch sendState {
        case .sent: return "Awaiting reply"
        case .pending: return (email?.isEmpty == false) ? "Not sent yet" : "No email yet"
        case .suppressed:
            switch suppressionReason {
            case .bookedElsewhere: return "Paused (booked elsewhere)"
            case .declined: return "Paused (show declined)"
            case .removedByDan: return "Removed"
            }
        case .sending: return "Sending…"
        }
    }
}

enum QueueModel {
    // Plain-language label for the AI's non-binding reply-intent hint (#420 C6).
    static func replyIntentLabel(_ raw: String) -> String {
        switch ReplyIntent(rawValue: raw) {
        case .interested: return "interested"
        case .wantsToBook: return "wants to book"
        case .hasQuestion: return "has a question"
        case .declined: return "declined"
        case nil: return raw
        }
    }

    // #350: Choral is no longer its own category (folded into Music); a leftover raw "choral"
    // string degrades to the generic fallback below rather than a dedicated label.
    static func disciplineLabel(_ discipline: String) -> String {
        switch discipline {
        case "dance": return "Dance"
        case "opera": return "Opera"
        case "theater": return "Theater"
        case "music": return "Music"
        case "band": return "Band"
        case "comedy": return "Comedy"
        default: return "Performance"
        }
    }

    static func productionLabel(_ production: String) -> String? {
        switch production {
        case "self": return "Self-produced"
        case "agency": return "Agency-routed"
        default: return nil
        }
    }

    static func coverageLabel(_ coverage: String) -> String? {
        switch coverage {
        case "likely_uncovered": return "Likely uncovered"
        case "likely_covered": return "Likely covered"
        default: return nil
        }
    }

    // A confident match is stated plainly; a fuzzy "possible" match is a question.
    static func historyFlag(_ item: QueueItem) -> String? {
        if item.priorRelationship == "booked" {
            if let name = item.matchedClientName {
                return "Worked together before (\(name))"
            }
            return "Worked together before"
        }
        if item.priorRelationship == "declined_by_you" {
            return "You declined before (usually a date conflict)"
        }
        if item.priorRelationship == "warm" {
            return "Warm lead from a prior relationship"
        }
        if item.priorRelationship == "lost_soft" {
            return "Lost before, open to the future"
        }
        if item.priorRelationship == "lost_hard" {
            return "Lost before, not interested"
        }
        if item.priorRelationship == "contacted" {
            return "Cold-contacted before, no booking"
        }
        if let name = item.possibleMatchName {
            let where_ = item.possibleMatchSource == "downbeat_client" ? "a past client" : "the booking log"
            return "Possible match to \(where_): \(name)?"
        }
        return nil
    }

    // Today, as a "yyyy-MM-dd" string in New York time (Overture's canonical zone), so
    // "is this in the past / within the booking window" never drifts a day off UTC or the
    // Mac's local zone wherever Dan happens to be.
    static func easternToday(_ now: Date = Date()) -> String {
        EasternDate.today(now)
    }

    // The window the queue shows: past performances drop out, and anything more than this
    // many days out is beyond the planning horizon Dan wants to look at.
    static let leadTimeWindowDays = 90
    // Within this many days a booking is unrealistic to land, so the event still shows but
    // sinks below everything bookable rather than sitting up top with the nearest dates.
    static let tooCloseDays = 5

    // Whole days from `today` (a "yyyy-MM-dd" string) to the performance, as New York
    // calendar dates so nothing drifts a day across timezones.
    static func daysUntil(performanceDate: String?, today: String) -> Int? {
        guard let performanceDate else { return nil }
        return EasternDate.daysUntil(from: today, to: performanceDate)
    }

    enum Urgency { case past, tooSoon, imminent, soon, ahead, unknown, booked }
    struct Timing: Equatable { let label: String; let urgency: Urgency
        static func == (l: Timing, r: Timing) -> Bool { l.label == r.label && l.urgency == r.urgency } }

    static func outreachTiming(performanceDate: String?, today: String) -> Timing {
        guard let days = daysUntil(performanceDate: performanceDate, today: today) else {
            return Timing(label: "Date TBD", urgency: .unknown)
        }
        if days < 0 { return Timing(label: "Performance passed", urgency: .past) }
        if days == 0 { return Timing(label: "Performs today, too close to book", urgency: .tooSoon) }
        if days <= tooCloseDays {
            return Timing(label: "In \(days) day\(days == 1 ? "" : "s"), likely too close to book", urgency: .tooSoon)
        }
        if days <= 7 {
            return Timing(label: "In \(days) days, reach out now", urgency: .imminent)
        }
        if days <= 21 {
            return Timing(label: "In \(days) days, good to send", urgency: .soon)
        }
        return Timing(label: "In \(days) days, send ~3 weeks out", urgency: .ahead)
    }

    // A booked prospect reads "Booked" instead of any outreach urgency, so the row never nags
    // Dan to pitch someone he has already booked (#198). Otherwise the normal outreach timing.
    static func displayTiming(performanceDate: String?, today: String, isBooked: Bool) -> Timing {
        if isBooked { return Timing(label: "Booked", urgency: .booked) }
        return outreachTiming(performanceDate: performanceDate, today: today)
    }

    // Orders the queue for display: hide past performances and anything beyond the lead-time
    // window, keep everything else, and demote the too-close events to the bottom, graded so
    // the nearest (least bookable) sits lowest. Undated events stay (they group last anyway).
    // Computed live against `today` so it stays correct as days pass between scout runs.
    static func queueOrder(_ items: [QueueItem], today: String) -> [QueueItem] {
        // Hide shows that vanished from the feed and Dan never acted on (#133): pure noise. Ones
        // he kept/drafted/approved stay (shown struck-through) so a cancellation he was pursuing
        // stays visible.
        let items = items.filter { !($0.status == .new && $0.disappearedFromFeed) }
        var bookable: [QueueItem] = []
        var tooSoon: [(item: QueueItem, days: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            // A confirmed booking is settled and leaves the reach-out queue (#201). An auto-detected
            // booking is kept (handled just below) so Dan can confirm it or catch a wrong match.
            if item.isConfirmedBooking { continue }
            // A detected booking awaiting Dan's confirmation is a separate workflow from
            // pitching, so it stays put regardless of how near or past its date is.
            if item.bookingSuggested {
                bookable.append(item)
                continue
            }
            guard let days = daysUntil(performanceDate: item.performanceDate, today: today) else {
                bookable.append(item)
                continue
            }
            if days < 0 || days > leadTimeWindowDays { continue }
            if days <= tooCloseDays {
                tooSoon.append((item, days, index))
                continue
            }
            bookable.append(item)
        }
        let demoted = tooSoon
            .sorted { $0.days != $1.days ? $0.days > $1.days : $0.index < $1.index }
            .map(\.item)
        return bookable + demoted
    }

    struct DateGroup: Identifiable, Equatable {
        let id: String
        let weekday: String
        let monthDay: String
        let year: String
        let items: [QueueItem]
    }

    // Groups by performance date, preserving incoming order. Undated collect last.
    static func groupByDate(_ items: [QueueItem]) -> [DateGroup] {
        var order: [String] = []
        var buckets: [String: [QueueItem]] = [:]
        for item in items {
            let key = item.performanceDate ?? "tbd"
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(item)
        }
        return order.map { key in
            let bucket = buckets[key] ?? []
            if key != "tbd", let d = day(key) {
                let cal = easternCalendar
                return DateGroup(
                    id: key,
                    weekday: shortWeekday(cal.component(.weekday, from: d)),
                    monthDay: "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))",
                    year: String(cal.component(.year, from: d)),
                    items: bucket
                )
            }
            return DateGroup(id: key, weekday: "", monthDay: "Date to be confirmed", year: "", items: bucket)
        }
    }

    // A blank or whitespace-only lost reason clears the note (stored as nil) rather than
    // persisting an empty string, so "has a reason" stays meaningful.
    static func normalizedLostReason(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // #217: the to-send queue is the bookable order with anyone already reached out to removed, so
    // the "To send" and "Reached out" pipelines never show the same prospect twice.
    static func toSendQueue(_ items: [QueueItem], reachedOutKeys: Set<String>, today: String) -> [QueueItem] {
        queueOrder(items.filter { !reachedOutKeys.contains($0.id) }, today: today)
    }

    // Whether a single show would actually render somewhere in the Queue right now, reusing
    // the exact same reached-out/toSendQueue rules the Queue itself renders with (on a one item
    // array), so this can never drift from what Dan would actually see if he looked.
    static func isReachableInQueue(_ item: QueueItem, reachedOutKeys: Set<String>, today: String) -> Bool {
        if reachedOutKeys.contains(item.id) { return true }
        return !toSendQueue([item], reachedOutKeys: [], today: today).isEmpty
    }

    static func summary(_ items: [QueueItem]) -> (total: Int, high: Int) {
        (items.count, items.filter { $0.tier == "high" }.count)
    }

    static func pendingBookingCount(_ items: [QueueItem]) -> Int {
        items.filter(\.bookingSuggested).count
    }

    // "Jun 25" for a single date (end nil or same as start), "Jun 25 to 28" for a same-month
    // range, "Jun 28 to Jul 2" for a cross-month range, "Date to be confirmed" for a bad start.
    static func runDateLabel(start: String?, end: String?) -> String {
        guard let start, let d = day(start) else { return "Date to be confirmed" }
        let cal = easternCalendar
        let startLabel = "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))"
        guard let end, end != start, let e = day(end) else { return startLabel }
        let sameMonth = cal.component(.month, from: d) == cal.component(.month, from: e)
        let endLabel = sameMonth
            ? "\(cal.component(.day, from: e))"
            : "\(shortMonth(cal.component(.month, from: e))) \(cal.component(.day, from: e))"
        return "\(startLabel) to \(endLabel)"
    }

    static func relatedRunNote(_ item: QueueItem) -> String? {
        item.partOfRelatedRun ? "This group also performs at this venue on other dates" : nil
    }

    // MARK: - Date helpers

    // Overture is always reckoned in New York time, never UTC or the Mac's local zone.
    // Date math delegates to the shared EasternDate helper, the one source of truth (#116). The
    // label formatting below still uses the Eastern calendar + day parsing through it.
    private static let easternCalendar = EasternDate.calendar
    private static func day(_ iso: String) -> Date? { EasternDate.date(from: iso) }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static func shortWeekday(_ component: Int) -> String { weekdays[(component - 1 + 7) % 7] }
    private static func shortMonth(_ component: Int) -> String { months[(component - 1 + 12) % 12] }
}
