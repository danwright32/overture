import Foundation
import SwiftData

// #2394: carries every ending Overture had already recorded onto the one show-level field.
//
// There were three places an ending could be sitting, and the whole reason for this change is that no
// reader could see all three: the legacy dismiss reason (the never-pitched half), the show-level
// `outcome` (only ever written as booked), and a contact's `resolution` (where every close-out actually
// landed, invisible to the funnel, #2401).
//
// Idempotent by construction: it only ever fills a row whose `showOutcomeRaw` is still nil, so a second
// pass is a no-op and no run-once flag is needed. It never overwrites, because a value already there was
// either written by Dan or written by an earlier pass, and both outrank a guess from legacy storage.
//
// It reports what it did rather than returning a bare count, because the three things that can happen to
// a row are genuinely different and one of them needs Dan's attention: an ending carried across, a live
// pitch deliberately left open, and a stored value that decodes to nothing at all.
enum ShowOutcomeBackfill {
    struct Result: Equatable, Sendable {
        var filled = 0
        // A pitch that has not ended. Left with no outcome ON PURPOSE: the alternative is filing every
        // open pitch as closed on the day this ships.
        var leftOpen = 0
        // A stored value that decodes to no known ending. Never guessed at, because the nearest value
        // would file the show under an ending nobody chose and would then be indistinguishable from one
        // Dan closed himself (L11).
        var unrecognised = 0
    }

    @discardableResult
    static func run(in context: ModelContext) -> Result {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var result = Result()
        var unrecognisedValues: Set<String> = []

        for p in prospects where p.showOutcomeRaw == nil {
            // The never-pitched half, straight off the legacy column. A dismissed show has left the queue
            // whatever its send record says, so this is read first and its recorded reason is kept rather
            // than reclassified to fit the menu split: the split governs what Dan is OFFERED next, not
            // what history says happened.
            if let legacy = p.dismissReasonRaw, !legacy.isEmpty {
                guard let reason = DismissReason(rawValue: legacy) else {
                    result.unrecognised += 1
                    unrecognisedValues.insert(legacy)
                    continue
                }
                p.showOutcome = reason.asShowOutcome
                result.filled += 1
                continue
            }

            // A booking recorded at the show level, which is the one ending that already lived here.
            if p.outcome == .booked {
                p.showOutcome = .booked
                result.filled += 1
                continue
            }

            // Everything else has to come off the contacts, and whether the show is OVER is not a new
            // judgement: `PerformanceStatus` already decides it, and already knows that one contact still
            // in play or still untried keeps the whole show open. Reusing it means a show cannot read as
            // closed on the one field while reading as active everywhere else.
            switch PerformanceStatus.of(p) {
            case .booked:
                p.showOutcome = .booked
                result.filled += 1
            case .stoodDown:
                p.showOutcome = .turnedThemDown
                result.filled += 1
            case .lostDoorOpen:
                // Both a soft no and a silence leave the door open, so they arrive here together. An
                // actual answer outranks the absence of one: somebody having said "not now" is the more
                // specific fact, and it is the one Dan would want the report to show.
                let resolutions = p.recipients.compactMap(\.resolution)
                p.showOutcome = resolutions.contains(.declinedSoft) ? .theySaidNotNow : .neverHeardBack
                result.filled += 1
            case .lostNotInterested:
                p.showOutcome = .theySaidNo
                result.filled += 1
            case .new, .active:
                result.leftOpen += 1
            }
        }

        report(unrecognisedValues, count: result.unrecognised, half: "prospect")
        return result
    }

    // #2400: the same job for the other half of the funnel. Its own pass rather than a branch inside the one
    // above, because an inquiry keeps none of a prospect's machinery: no contacts, no send record, no
    // derived performance status. What it shares is the vocabulary, which is the whole point.
    //
    // The three retired reasons map on meaning, not on spelling. "Not a fit for me" was DAN'S pass, so it
    // becomes "I turned them down": reading it as their refusal would record a no nobody said.
    @discardableResult
    static func runForInquiries(in context: ModelContext) -> Result {
        let inquiries = (try? context.fetch(FetchDescriptor<Inquiry>())) ?? []
        var result = Result()
        var unrecognisedValues: Set<String> = []

        for i in inquiries where i.showOutcomeRaw == nil {
            if i.outcome == .booked {
                i.showOutcome = .booked
                result.filled += 1
                continue
            }
            // Still open: somebody is waiting on a reply, and closing it here would take it off the queue
            // that exists to stop that being forgotten.
            guard !i.isOpen else {
                result.leftOpen += 1
                continue
            }
            if let legacy = i.lostReasonRaw, !legacy.isEmpty {
                guard let ending = retiredInquiryReasons[legacy] else {
                    result.unrecognised += 1
                    unrecognisedValues.insert(legacy)
                    continue
                }
                i.showOutcome = ending
                result.filled += 1
                continue
            }
            // Closed with no reason recorded, by a build that never captured one. A silence is the only
            // thing the stored data can honestly support, and it is the same fallback the reporting already
            // used, so this keeps the inquiry in the year-end total rather than letting it vanish.
            i.showOutcome = .neverHeardBack
            result.filled += 1
        }

        report(unrecognisedValues, count: result.unrecognised, half: "inquiry")
        return result
    }

    private static let retiredInquiryReasons: [String: ShowOutcome] = [
        "they_declined": .theySaidNo,
        "not_a_fit": .turnedThemDown,
        "never_heard_back": .neverHeardBack,
    ]

    private static func report(_ unrecognisedValues: Set<String>, count: Int, half: String) {
        if !unrecognisedValues.isEmpty {
            // copy-inventory:ignore-start  agent log, not a sentence Overture says to Dan (#915)
            AgentLog.problem("#2394 ShowOutcomeBackfill: \(count) \(half)(s) carry a stored ending that "
                + "decodes to nothing and were left with no outcome, so they are absent from the reporting "
                + "until somebody closes them by hand. Values: "
                + unrecognisedValues.sorted().joined(separator: ", "))
            // copy-inventory:ignore-end
        }
    }
}
