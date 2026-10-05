import Testing
import Foundation
import SwiftData

private final class CountingSender: MailSender, @unchecked Sendable {
    var sent: [OutgoingMail] = []
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent.append(mail)
        return SentReceipt(threadId: "t", messageID: "<m@x>")
    }
}

// #3326, plan 2.8: a pitch naming a night Dan skipped never leaves, whatever the screen allowed, and a
// pitch that does leave stamps what it promised (#3959).
@MainActor
@Suite("A pitch naming a skipped night does not send (#3326)")
struct SkippedNightSendBlockTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21, before every night below
    private static let nights = ["2026-10-06", "2026-10-13", "2026-10-20"]

    private func show(_ ctx: ModelContext, body: String) throws -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Skip Revue", performanceDate: Self.nights[0],
                                                             venue: "Room"),
                         groupName: "Skip Revue", discipline: "theater", venue: "Room",
                         performanceDate: Self.nights[0], sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.runNights = Self.nights
        p.runEndDate = Self.nights.last
        p.draftSubject = "Photographing your run"
        p.draftBody = body
        ctx.insert(p)
        let r = Recipient(id: "r-skip", email: "to@act.example", provenance: .act)
        p.setRecipients([r])
        try p.recordNightDecisions(pitched: [NightDecision(night: Self.nights[0], at: now, origin: .chosen),
                                             NightDecision(night: Self.nights[2], at: now, origin: .chosen)],
                                   skipped: [NightDecision(night: Self.nights[1], at: now, origin: .chosen)])
        try ctx.save()
        return p
    }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @Test func theServiceRefusesAPitchNamingASkippedNightAndClaimsNothing() async throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6, October 13 and October 20.")
        let sender = CountingSender()
        let sent = await SendService.sendOne(p, now: now, sender: sender)
        #expect(sent == false)
        #expect(sender.sent.isEmpty, "a pitch naming a skipped night reached the network")
        #expect(p.recipients.first?.sendState == .pending, "the refusal left the contact claimed")
    }

    // The positive control in the SAME fixture (L159): drop the skipped night from the words and it goes,
    // and the promise it froze is the nights it named.
    @Test func thePitchWithoutTheSkippedNightSendsAndFreezesItsPromise() async throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6 and October 20.")
        let sender = CountingSender()
        let sent = await SendService.sendOne(p, now: now, sender: sender)
        #expect(sent == true)
        #expect(sender.sent.count == 1)
        guard case .stamped(let promise)? = p.recipients.first?.promisedNights else {
            Issue.record("the send froze no promise"); return
        }
        #expect(promise.nights == ["2026-10-06", "2026-10-20"])
    }

    // The second way out: pitch the night after all, and the same draft now sends.
    @Test func pitchingTheNightAfterAllReleasesTheDraft() throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6, October 13 and October 20.")
        let today = EasternDate.dayString(from: now)
        #expect(KeptNights.skippedNightNamed(subject: p.draftSubject, body: p.draftBody ?? "", on: p,
                                             today: today) == "2026-10-13")
        try p.recordNightDecisions(pitched: [NightDecision(night: "2026-10-13", at: now, origin: .chosen)],
                                   skipped: [])
        #expect(KeptNights.skippedNightNamed(subject: p.draftSubject, body: p.draftBody ?? "", on: p,
                                             today: today) == nil)
    }

    // #4502: in the shipping app the send is judged on exactly the day the wall clock gave it before, because
    // every call the app makes hands it the moment it is made (`now: Date()`, which also stamps what is sent) and
    // the day of the press (`today: pressDay`, taken as `EasternDate.today(Date())` in the SAME function, before
    // anything awaits). Derived from the app's own sources (L96); each call is read as a whole expression however
    // it wraps, and the day is looked for inside the function that makes the call, never anywhere in the file
    // (L135). Refuses to pass on finding none (L98).
    @Test func everyShippingSendIsJudgedOnTheDayOfThePress() throws {
        let call = try NSRegularExpression(pattern: #"SendService\.(sendNext|sendOne|sendJointly)\("#)
        var calls = 0
        for file in AppSourceWalk.appFiles() {
            let text = file.text as NSString
            for match in call.matches(in: file.text, range: NSRange(location: 0, length: text.length)) {
                calls += 1
                // The whole call, to its balancing parenthesis, however many lines and nested calls it spans.
                var depth = 0
                var end = match.range.location + match.range.length - 1
                repeat {
                    let unit = text.character(at: end)
                    if unit == 40 { depth += 1 } else if unit == 41 { depth -= 1 }
                    end += 1
                } while depth > 0 && end < text.length
                let expression = text.substring(with: NSRange(location: match.range.location,
                                                              length: end - match.range.location))
                #expect(expression.contains("now: Date()") && expression.contains("today: pressDay"),
                        Comment(rawValue: "\(file.name): a send handed some other moment or day: \(expression)"))
                // The function the call sits in: from the last `func ` before it to the call itself.
                let before = text.substring(to: match.range.location)
                let function = before.range(of: "func ", options: .backwards).map { String(before[$0.lowerBound...]) } ?? ""
                #expect(function.contains("let pressDay = EasternDate.today(Date())"),
                        Comment(rawValue: "\(file.name): the function making this send does not take the press's day itself: \(expression)"))
            }
        }
        #expect(calls > 0, "no shipping call to the send was found, so this measured nothing")
    }

    // #4502: the send derives a day in exactly one form, once per entry point, from its own moment, and hands
    // that one `today` to every step. Any other day or clock read inside the send (a `dayString(from:)`, an
    // `EasternDate.today(` of anything but the entry point's derivation, a bare `Date()`) is a second day that
    // can disagree with the first across midnight, which is how the skipped-night check was missed twice.
    @Test func theSendReadsItsDayInOneFormOnly() throws {
        let source = SourceGuardHelper.source("Overture/Integration/SendService.swift")
        let derivation = "let today = today ?? EasternDate.today(now)"
        var derivations = 0
        for line in source.components(separatedBy: "\n") {
            let code = line.components(separatedBy: "//").first ?? ""
            guard code.contains("dayString(from:") || code.contains("EasternDate.today(") || code.contains("Date()")
            else { continue }
            if code.trimmingCharacters(in: .whitespaces) == derivation { derivations += 1; continue }
            Issue.record(Comment(rawValue: "SendService reads a day or the clock outside its one derivation: \(line)"))
        }
        #expect(derivations >= 3, "found \(derivations) derivations; the send's entry points each derive the day once")
    }

    // Why the skipped-night refusal needs no day-sensitive test of its own: whether a draft names a skipped night
    // does not depend on the day it is asked on (`EventDateInDraft.finding` reads only the named days and the
    // skipped set for that answer). Pinned, so a change that makes it day-dependent is seen, and then needs the
    // send's one `today`, which `theSendReadsItsDayInOneFormOnly` already requires.
    @Test func whetherADraftNamesASkippedNightDoesNotDependOnTheDay() throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6, October 13 and October 20.")
        let body = p.draftBody ?? ""
        let answers = ["2026-01-01", "2026-10-14", "2027-06-01"].map {
            KeptNights.skippedNightNamed(subject: p.draftSubject, body: body, on: p, today: $0)
        }
        #expect(answers == ["2026-10-13", "2026-10-13", "2026-10-13"], Comment(rawValue: "\(answers)"))
    }

    // #4502: a press is judged on ONE day, handed to `sendNext` by the press and down to every step, so each
    // step judges by the day it is handed rather than deriving its own: handed a day after the run, the press,
    // the single and the joint send all refuse, though their `now` is still before every night.
    @Test func eachStepOfASendJudgesByTheDayItIsHanded() async throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6 and October 20.")
        let sender = CountingSender()
        #expect(await SendService.sendNext(p, now: now, today: "2026-10-26", sender: sender) == false,
                "the press derived its own day instead of judging by the one the press handed it")
        #expect(await SendService.sendOne(p, now: now, today: "2026-10-26", sender: sender) == false,
                "the single send derived its own day instead of judging by the one it was handed")
        #expect(await SendService.sendJointly(p, to: p.recipients, now: now, today: "2026-10-26", sender: sender) == false,
                "the joint send derived its own day instead of judging by the one it was handed")
        #expect(sender.sent.isEmpty)
        // The control in the same fixture (L159): handed the day of its own moment, the single send goes.
        #expect(await SendService.sendOne(p, now: now, today: EasternDate.dayString(from: now), sender: sender))
    }

    // #4502: a send is judged on the day of the `now` it is handed, never the wall clock beside it. Handed a
    // moment after the run's last night, the same pitch the control above sends is refused, because that
    // run has passed on that day. Without this, the control above would turn red on its own the day real
    // time walks past October 20 (L130), and a send handed one clock would answer for another.
    @Test func aSendIsJudgedOnTheDayOfTheMomentItIsHanded() async throws {
        let ctx = try context()
        let p = try show(ctx, body: "Hello,\n\nI'd be glad to photograph October 6 and October 20.")
        let afterTheRun = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26, after every night above
        let sender = CountingSender()
        let sent = await SendService.sendOne(p, now: afterTheRun, sender: sender)
        #expect(sent == false, "a run that had passed on the send's own day was sent")
        #expect(sender.sent.isEmpty)
    }
}
