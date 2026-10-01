import Testing
import Foundation

// #4398: a compaction must never destroy a line it could not parse.
//
// Both of this app's ndjson compactions, `CardDivergenceLog.compact` and `FreezeLog.compact`, rewrote the
// live file from its DECODED records only. So a line the read could not decode, a torn append from a
// process killed mid-write or a record a later build wrote in a shape this one cannot parse, was in
// neither the rewritten live file nor the archive: it was simply gone, and nothing counted it. Meanwhile
// each log's own archive prune REFUSED to rewrite a file holding such a line, for exactly that reason, so
// the two halves of one bookkeeping step disagreed about the same condition and the compaction was the
// half that lost the evidence (L211, L5).
//
// The rule now: an unreadable line is carried through a compaction VERBATIM, kept in the live file at its
// head, and the compaction's outcome says how many it carried. It stays in the live file rather than going
// to the archive because the archive's prune refuses on unreadable lines, so moving one there would stop
// the archive ever being bounded again.
@Suite("A compaction keeps the lines it could not read (#4398)")
struct ACompactionKeepsLinesItCannotReadTests {
    private let sandboxes = TemporarySandboxes()

    private func divergence(_ sequence: Int, fields: [String] = ["venue"], kind: CardDivergenceRecord.Kind = .cardDivergence)
        -> CardDivergenceRecord {
        CardDivergenceRecord(session: "s", sequence: sequence,
                             at: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
                             fields: fields, cardsBuilt: 20, stage: nil, kind: kind)
    }

    private func stall(_ seconds: Double, sequence: Int) -> StallRecord {
        StallRecord(session: "s", sequence: sequence,
                    at: Date(timeIntervalSince1970: 1_785_000_000 + Double(sequence)), seconds: seconds,
                    surface: .queue, load: .baseline, loadAverage: 1.0, passes: nil)
    }

    // A TORN append, made the way one really happens: a writer killed part way through a line leaves its
    // first bytes with no newline, and the next append lands on the end of them, so one physical line holds
    // a fragment and a whole record and decodes as neither (L48: the shape comes from `append`, not from a
    // string this test agreed with in advance).
    private static let tornFragment = "{\"at\":\"2026-09-30T10:00:00Z\",\"cardsB"

    // A record a LATER build wrote whose shape this build cannot decode at all, which is a different
    // thing from a later build's unknown KIND: `fields` changed type, so the whole line fails rather than
    // reading as `.unrecognised`.
    private static let laterShape =
        "{\"at\":\"2026-09-30T11:00:00Z\",\"cardsBuilt\":3,\"fields\":{\"venue\":2},\"sequence\":900,\"session\":\"later\"}"

    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // THE FINDING. Over its cap, holding a torn line and a later build's unreadable line, the divergence
    // log compacts, and both lines are still in the live file byte for byte afterwards.
    @Test func theDivergenceLogCarriesUnreadableLinesThroughACompactionVerbatim() throws {
        let dir = try sandboxes.make(named: "4398-divergence")
        let url = CardDivergenceLog.url(in: dir)
        for n in 0..<6 { #expect(CardDivergenceLog.append(divergence(n), to: url)) }
        try appendRaw(Self.tornFragment, to: url)
        for n in 6..<13 { #expect(CardDivergenceLog.append(divergence(n), to: url)) }
        try appendRaw(Self.laterShape + "\n", to: url)
        let before = CardDivergenceLog.read(at: url)
        #expect(before.unreadableLines == 2, "the fixture did not produce the two unreadable lines it is about")
        let tornLine = try #require(before.unreadable.first)
        #expect(tornLine.hasPrefix(Self.tornFragment))

        let outcome = CardDivergenceLog.compact(at: url, cap: 10)

        // 13 appends, one of which fused with the torn fragment, leave 12 readable records; cap 10 drops 2.
        #expect(outcome == .archived(count: 2, keptUnreadable: 2),
                "the compaction did not report the unreadable lines it carried")
        let after = try String(contentsOf: url, encoding: .utf8)
        let lines = after.split(separator: "\n").map(String.init)
        #expect(lines.contains(tornLine), "the torn line is gone from the live file after a compaction")
        #expect(lines.contains(Self.laterShape), "a later build's record is gone from the live file after a compaction")
        let live = CardDivergenceLog.read(at: url)
        #expect(live.records.count == 10)
        #expect(live.unreadableLines == 2)
    }

    // A later build's UNKNOWN KIND beside a torn line still refuses the rewrite, and the file is untouched
    // byte for byte, so neither the spelling nor the torn line is lost (#4354's refusal, unchanged).
    @Test func aTornLineBesideALaterKindLeavesTheDivergenceLogUntouched() throws {
        let dir = try sandboxes.make(named: "4398-divergence-later-kind")
        let url = CardDivergenceLog.url(in: dir)
        for n in 0..<12 { #expect(CardDivergenceLog.append(divergence(n), to: url)) }
        try appendRaw(Self.tornFragment + "\n", to: url)
        let laterKind = "{\"at\":\"2026-09-30T12:00:00Z\",\"cardsBuilt\":3,\"fields\":[],\"kind\":\"aKindFromLater\","
            + "\"sequence\":901,\"session\":\"later\",\"suppressedRepeats\":0}"
        try appendRaw(laterKind + "\n", to: url)
        let before = try String(contentsOf: url, encoding: .utf8)

        let outcome = CardDivergenceLog.compact(at: url, cap: 10)

        #expect(outcome == .refusedUnrecognised(records: 1))
        #expect(try String(contentsOf: url, encoding: .utf8) == before, "a refused compaction changed the file")
    }

    // THE SIBLING. The freeze log's compaction rewrote from decoded records the same way.
    @Test func theFreezeLogCarriesUnreadableLinesThroughACompactionVerbatim() throws {
        let dir = try sandboxes.make(named: "4398-freeze")
        let url = FreezeLog.url(in: dir)
        for n in 0..<5 { #expect(FreezeLog.append(stall(0.2 + Double(n) * 0.1, sequence: n + 1), to: url)) }
        try appendRaw("{\"at\":\"2026-09-30T10:00:00Z\",\"seco", to: url)
        for n in 5..<11 { #expect(FreezeLog.append(stall(0.2 + Double(n) * 0.1, sequence: n + 1), to: url)) }
        let before = FreezeLog.read(at: url)
        #expect(before.unreadableLines == 1, "the fixture did not produce the torn line it is about")
        let tornLine = try #require(before.unreadable.first)

        let outcome = FreezeLog.compact(at: url, cap: 4, now: Date(timeIntervalSince1970: 1_790_000_000))

        #expect(outcome == .archived(count: 6, keptUnreadable: 1),
                "the freeze compaction did not report the unreadable line it carried")
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.split(separator: "\n").map(String.init).contains(tornLine),
                "the torn line is gone from the freeze log after a compaction")
        // And the note the compaction writes into the file says so, for whoever reads the file itself.
        let live = FreezeLog.read(at: url)
        #expect(live.notes.count == 1)
        #expect(live.notes.first?.keptUnreadable == 1, "the compaction note does not say it carried an unreadable line")
        #expect(live.records.count == 4)
        #expect(live.unreadableLines == 1)
    }

    // A clean file reports zero carried, so the count is a measurement rather than a constant.
    @Test func aCleanCompactionCarriesNothing() throws {
        let dir = try sandboxes.make(named: "4398-clean")
        let url = CardDivergenceLog.url(in: dir)
        for n in 0..<13 { #expect(CardDivergenceLog.append(divergence(n), to: url)) }
        #expect(CardDivergenceLog.compact(at: url, cap: 10) == .archived(count: 3, keptUnreadable: 0))
    }

    // #4398's sibling inside the divergence compaction: the same record identity written twice. The kept
    // list holds one copy, and the dropped list was worked out by IDENTITY, so the other copy was excluded
    // from the archive too and went nowhere. `FreezeLog.compacted` already works in positions for this
    // reason (#3763); this one now does as well.
    @Test func aRepeatedIdentityIsNeitherKeptTwiceNorLost() throws {
        // The older copy falls outside the newest window and its twin is inside it, which is the case the
        // identity filter could not tell apart.
        let twin = divergence(1)
        let records = (0..<12).map { divergence($0) } + [twin]
        let result = CardDivergenceLog.compacted(records, cap: 10)
        #expect(result.records.count + result.dropped == records.count, """
        a compaction of \(records.count) records kept \(result.records.count) and dropped \(result.dropped), \
        so a copy of a repeated identity went nowhere
        """)
    }
}
