import Testing
import Foundation

// #4354 (plan v7 D8): the divergence log keys on KIND and SOURCE, every new kind has a cooldown, and no
// record can carry a show identity.
//
// WHAT WAS WRONG. `compacted` and `prunedArchive` keyed a record on `fields.joined("|")` alone, so a record
// said nothing about WHICH check wrote it, and every record with no field names shared the single key "".
// The queue engine's verifier (#4358) is about to write a family of kinds into this file (a no-op dirty
// row, a fact mismatch, a per-term mismatch), most of them naming no field, so a thousand of the cheap one
// would have compacted the only record of a rare one out of the live file and pruned it from the archive:
// the cheap writer evicting the expensive observation (L191). This is the fix, landed before any of those
// writers exists, as the plan orders it.
@Suite("The divergence log keys on kind and source, with cooldowns (#4354)")
struct TheDivergenceLogKeysOnKindAndSourceTests {
    private let sandboxes = TemporarySandboxes()
    typealias Kind = CardDivergenceRecord.Kind
    typealias Source = CardDivergenceRecord.Source

    private func record(_ sequence: Int, kind: Kind = .cardDivergence, source: Source? = nil,
                        fields: [String]) -> CardDivergenceRecord {
        CardDivergenceRecord(session: "s", sequence: sequence,
                             at: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
                             fields: fields, cardsBuilt: 20, stage: nil, kind: kind, source: source)
    }

    private func write(_ records: [CardDivergenceRecord], to url: URL) throws {
        let text = records.compactMap(CardDivergenceLog.line(for:)).joined(separator: "\n") + "\n"
        #expect(text.count > 1, "the fixture encoded nothing, so nothing below is measured")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // THE PLAN'S OWN TEST. A thousand no-op dirties, then one fact mismatch and one card divergence that
    // name THE SAME FIELD. Keyed on fields alone, the fact mismatch and the card divergence are one key, so
    // one of them is dropped; and the thousand no-op dirties share a key with nothing else, so they cannot
    // be told apart from each other either.
    @Test func aRareKindSurvivesCompactionAndPruneUnderAThousandCheapOnes() throws {
        let dir = try sandboxes.make(named: "d8-survive")
        let url = CardDivergenceLog.url(in: dir)
        let factMismatch = record(0, kind: .factMismatch, source: .reconcile, fields: ["venue"])
        let cardDivergence = record(1, kind: .cardDivergence, fields: ["venue"])
        let noOps = (2..<1002).map { record($0, kind: .noOpDirty, source: .reconcile, fields: []) }
        try write([factMismatch, cardDivergence] + noOps, to: url)

        let outcome = CardDivergenceLog.housekeeping(at: url, cap: CardDivergenceLog.fileCap)

        #expect(outcome.compaction == .archived(count: 1002 - CardDivergenceLog.fileCap))
        let live = CardDivergenceLog.read(at: url).records
        #expect(live.contains(factMismatch), "compaction dropped the only fact mismatch")
        #expect(live.contains(cardDivergence), "compaction dropped the only card divergence")
        #expect(live.count == CardDivergenceLog.fileCap)

        // The archive is bounded by key, so it keeps one no-op dirty (the oldest one dropped) and nothing
        // it received twice.
        let archived = CardDivergenceLog.read(at: CardDivergenceLog.archiveURL(besideLogAt: url)).records
        #expect(archived.count == 1)
        #expect(archived.first?.kind == .noOpDirty)
    }

    // The same pair straight into the archive prune, whose rule is ONE OF EACH KEY: before this, a fact
    // mismatch and a card divergence naming the same field were one key, and the younger was pruned.
    @Test func thePruneKeepsOneOfEachKindAndSourceNotOneOfEachFieldSet() throws {
        let kept = CardDivergenceLog.prunedArchive([
            record(0, kind: .cardDivergence, fields: ["venue"]),
            record(1, kind: .factMismatch, source: .reconcile, fields: ["venue"]),
            record(2, kind: .factMismatch, source: .scoutLanding, fields: ["venue"]),
            record(3, kind: .factMismatch, source: .reconcile, fields: ["venue"]),
            record(4, kind: .noOpDirty, source: .reconcile, fields: []),
            record(5, kind: .noOpDirty, source: .scoutLanding, fields: []),
        ]).records
        #expect(kept.map(\.sequence) == [0, 1, 2, 4, 5])
    }

    // A record written before `kind` existed reads as a card divergence, because the card check was its
    // only writer, and every line in Dan's file today is one (L133).
    @Test func aRecordWrittenBeforeKindExistedReadsAsACardDivergence() throws {
        let old = #"{"at":"2026-09-20T12:00:00Z","cardsBuilt":20,"fields":["venue"],"sequence":3,"session":"s","stage":"scout"}"#
        let read = CardDivergenceLog.read(old + "\n")
        #expect(read.unreadableLines == 0)
        let r = try #require(read.records.first)
        #expect(r.kind == .cardDivergence)
        #expect(r.source == nil)
        #expect(r.suppressedRepeats == 0)
    }

    // A kind or source this build does not know (a LATER build wrote it) reads as unrecognised rather than
    // failing the whole line, so an older build never counts a newer record as unreadable (L255).
    @Test func aKindOrSourceThisBuildDoesNotKnowIsKeptAsUnrecognised() throws {
        let newer = #"{"at":"2026-09-20T12:00:00Z","cardsBuilt":0,"fields":[],"kind":"someLaterKind","sequence":3,"session":"s","source":"someLaterSource","suppressedRepeats":2}"#
        let read = CardDivergenceLog.read(newer + "\n")
        #expect(read.unreadableLines == 0)
        let r = try #require(read.records.first)
        #expect(r.kind == .unrecognised)
        #expect(r.source == .unrecognised)
        #expect(r.suppressedRepeats == 2)
    }

    // A file holding a later build's record is never REWRITTEN by this one: the rewrite would re-encode the
    // spelling as "unrecognised" for good and key every such record as one (L650). Left untouched instead,
    // byte for byte, and said as a refusal rather than as nothing to do.
    @Test func aFileHoldingALaterBuildsRecordIsLeftUntouched() throws {
        let dir = try sandboxes.make(named: "d8-later-build")
        let url = CardDivergenceLog.url(in: dir)
        let newer = #"{"at":"2026-09-20T12:00:00Z","cardsBuilt":0,"fields":[],"kind":"someLaterKind","sequence":0,"session":"t","suppressedRepeats":0}"#
        let common = (1...12).compactMap { CardDivergenceLog.line(for: record($0, fields: ["venue"])) }
        let text = ([newer] + common).joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let archive = CardDivergenceLog.archiveURL(besideLogAt: url)
        try text.write(to: archive, atomically: true, encoding: .utf8)

        let done = CardDivergenceLog.housekeeping(at: url, cap: 10)

        #expect(done.compaction == .refusedUnrecognised(records: 1))
        #expect(done.prune == .refusedUnrecognised(records: 1))
        #expect(try String(contentsOf: url, encoding: .utf8) == text, "the live file was rewritten")
        #expect(try String(contentsOf: archive, encoding: .utf8) == text, "the archive was rewritten")
    }

    // EVERY NEW KIND HAS A COOLDOWN. The card divergence keeps today's none, because its reader counts
    // records as cards and a suppressed repeat would read as a card that was never built wrongly.
    @Test func everyKindButTheCardCheckHasATenMinuteCooldown() {
        for kind in Kind.allCases {
            switch kind {
            case .cardDivergence: #expect(kind.cooldown == 0)
            default: #expect(kind.cooldown == 600, "\(kind) has no ten minute cooldown")
            }
        }
    }

    // The first repeat is written; repeats inside the window are counted, not written; the next record
    // after the window carries the count. Per (kind, source): another source is its own window.
    @Test func repeatsInsideTheCooldownAreCountedOnTheNextRecordRatherThanWritten() {
        var cooldown = CardDivergenceLog.Cooldown()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0) == .write(suppressedRepeats: 0))
        for s in 1...9 {
            #expect(cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0 + Double(s * 60)) == .suppressed)
        }
        // Another source, and another kind from the same source, are windows of their own.
        #expect(cooldown.admit(kind: .noOpDirty, source: .scoutLanding, at: t0 + 30) == .write(suppressedRepeats: 0))
        #expect(cooldown.admit(kind: .factMismatch, source: .reconcile, at: t0 + 30) == .write(suppressedRepeats: 0))
        // The window ends at ten minutes, and the record written then carries the nine it held back.
        #expect(cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0 + 600) == .write(suppressedRepeats: 9))
        #expect(cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0 + 601) == .suppressed)
    }

    // A card divergence is never held back, which is today's behaviour exactly.
    @Test func theCardCheckIsNeverSuppressed() {
        var cooldown = CardDivergenceLog.Cooldown()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for s in 0..<5 {
            #expect(cooldown.admit(kind: .cardDivergence, source: nil, at: t0 + Double(s)) == .write(suppressedRepeats: 0))
        }
    }

    // A clock set BACKWARDS must not hold a window open for ever: a record whose instant is before its
    // window opened is written, never suppressed (L74).
    @Test func aClockThatWentBackwardsDoesNotSuppressForEver() {
        var cooldown = CardDivergenceLog.Cooldown()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0)
        #expect(cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0 - 3600) == .write(suppressedRepeats: 0))
    }

    // What a window held back when nothing else came along to carry it: drained once its window has
    // ended, so a count is never silently lost to a quiet period (L710).
    @Test func aWindowThatEndsQuietlyIsDrainedWithItsCount() {
        var cooldown = CardDivergenceLog.Cooldown()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0)
        _ = cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0 + 10)
        _ = cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0 + 20)
        _ = cooldown.admit(kind: .factMismatch, source: .reconcile, at: t0)
        #expect(cooldown.drainEnded(at: t0 + 599).isEmpty, "a window still open was drained")
        let drained = cooldown.drainEnded(at: t0 + 600)
        #expect(drained == [CardDivergenceLog.Cooldown.Held(kind: .noOpDirty, source: .reconcile, suppressedRepeats: 2)])
        // Drained once: the count is not carried again by the next record.
        #expect(cooldown.admit(kind: .noOpDirty, source: .reconcile, at: t0 + 700) == .write(suppressedRepeats: 0))
    }

    // THE BYPASS IS CLOSED (L621). A writer of a cooled kind that calls the plain append would skip its
    // cooldown, so the plain append refuses every kind that has one.
    @Test func thePlainAppendRefusesAKindThatHasACooldown() throws {
        let dir = try sandboxes.make(named: "d8-append")
        let url = CardDivergenceLog.url(in: dir)
        #expect(!CardDivergenceLog.append(record(1, kind: .noOpDirty, source: .reconcile, fields: []), to: url))
        #expect(CardDivergenceLog.read(at: url).fileWasAbsent)
        #expect(CardDivergenceLog.append(record(2, fields: ["venue"]), to: url))
    }

    // Through the cooldown: one line for the first, none for the repeats, one carrying the count after.
    @Test func appendingThroughTheCooldownWritesOneLinePerWindow() throws {
        let dir = try sandboxes.make(named: "d8-append-cooled")
        let url = CardDivergenceLog.url(in: dir)
        var cooldown = CardDivergenceLog.Cooldown()
        for s in 0..<11 {
            CardDivergenceLog.append(record(s, kind: .noOpDirty, source: .reconcile, fields: []),
                                     to: url, through: &cooldown)
        }
        let late = record(700, kind: .noOpDirty, source: .reconcile, fields: [])
        CardDivergenceLog.append(late, to: url, through: &cooldown)
        let lines = CardDivergenceLog.read(at: url).records
        #expect(lines.map(\.sequence) == [0, 700])
        #expect(lines.map(\.suppressedRepeats) == [0, 10])
    }

    // A write that FAILS must not consume the window: the record was never written, so marking its pair as
    // written would suppress every repeat for ten minutes and lose the count it carried (L368).
    @Test func aFailedWriteLeavesTheCooldownAsItFoundIt() throws {
        let dir = try sandboxes.make(named: "d8-append-fails")
        let unwritable = dir.appendingPathComponent("no-such-folder/card-divergence.ndjson")
        let url = CardDivergenceLog.url(in: dir)
        var cooldown = CardDivergenceLog.Cooldown()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Int) -> CardDivergenceRecord {
            CardDivergenceRecord(session: "s", sequence: s, at: t0 + Double(s), fields: [], cardsBuilt: 0,
                                 stage: nil, kind: .noOpDirty, source: .reconcile)
        }
        #expect(CardDivergenceLog.append(at(0), to: url, through: &cooldown))
        #expect(!CardDivergenceLog.append(at(1), to: url, through: &cooldown))
        #expect(!CardDivergenceLog.append(at(2), to: url, through: &cooldown))
        let before = cooldown
        // After the window: the write is attempted, fails, and the window and its count are kept.
        #expect(!CardDivergenceLog.append(at(700), to: unwritable, through: &cooldown))
        #expect(cooldown == before, "a failed write consumed the cooldown window")
        #expect(CardDivergenceLog.append(at(701), to: url, through: &cooldown))
        #expect(CardDivergenceLog.read(at: url).records.map(\.suppressedRepeats) == [0, 2])
    }

    // "The file proves the check ran" is a statement about the CARD check, so only a card divergence can
    // make it: a file holding the engine's records alone must not silence the never-ran notice (L11, L98).
    @Test func otherKindsDoNotProveTheCardCheckRan() throws {
        let dir = try sandboxes.make(named: "d8-never-ran")
        try write([record(1, kind: .noOpDirty, source: .reconcile, fields: [])], to: CardDivergenceLog.url(in: dir))
        let defaults = ScratchDefaults.make("d8-never-ran")
        #expect(CardDivergenceReport.newlyReported(in: dir, defaults: defaults) == CardDivergenceCopy.neverRan)
    }

    // THE READER. Dan is told about WRONG CARDS, and a no-op dirty is not one: counted as one, a thousand of
    // them would read as a thousand cards built wrongly (L11). The other kinds are the verifier's to say
    // (#4358); here they are never said as cards.
    @Test func onlyCardDivergencesAreSaidAsWrongCards() throws {
        let dir = try sandboxes.make(named: "d8-reader")
        let url = CardDivergenceLog.url(in: dir)
        try write([record(1, kind: .noOpDirty, source: .reconcile, fields: []),
                   record(2, kind: .factMismatch, source: .reconcile, fields: ["venue"])], to: url)
        let defaults = ScratchDefaults.make("d8-reader")
        defaults.set(Date(), forKey: CardDivergenceLog.lastRanKey)
        #expect(CardDivergenceReport.newlyReported(in: dir, defaults: defaults) == nil,
                "a record that is not a card divergence was said to Dan as a wrong card")

        try write([record(3, fields: ["venue"])], to: url)
        let said = CardDivergenceReport.newlyReported(in: dir, defaults: defaults)
        #expect(said == CardDivergenceCopy.report(count: 1, fields: ["venue"], unreadableLines: 0))
    }
}
