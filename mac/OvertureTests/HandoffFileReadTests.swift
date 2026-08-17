import Testing
import Foundation

// #2879: an unreadable file is not an absent one, at EVERY read site, not just the one that caused
// #2873.
//
// #2873 was a decoding bug worth one line. What made it cost a day was that its error was discarded by
// a `try?`, so a file the app could not read and a file that was not there were the same thing to every
// caller, and a completed, paid AI draft looked exactly like a run with nothing to do.
@Suite("Reading a handoff file")
struct HandoffFileReadTests {

    private struct Shape: Codable, Equatable { var value: String }

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func absentFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-absent-\(UUID().uuidString).json")
    }

    private func decodeShape(_ data: Data) throws -> Shape {
        try JSONDecoder().decode(Shape.self, from: data)
    }

    // MARK: - The three states

    @Test func aFileThatIsNotThereIsAbsent() {
        let register = HandoffReadFailures()
        #expect(HandoffFile.read(at: absentFile(), recorder: register, decode: decodeShape) == .absent)
        #expect(register.current().isEmpty)   // nothing to report: this is the ordinary idle state
    }

    @Test func aFileThatCannotBeDecodedIsUnreadableAndNamesTheField() throws {
        let register = HandoffReadFailures()
        let url = try temporaryFile(#"{"nope":1}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .unreadable(let reason) = HandoffFile.read(at: url, recorder: register,
                                                              decode: decodeShape) else {
            Issue.record("expected unreadable")
            return
        }
        #expect(reason.contains("value"))
        #expect(register.current().map(\.file) == [url.lastPathComponent])
        #expect(register.current().first?.reason.contains("value") == true)
    }

    @Test func aFileThatDecodesIsRead() throws {
        let register = HandoffReadFailures()
        let url = try temporaryFile(#"{"value":"here"}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(HandoffFile.read(at: url, recorder: register, decode: decodeShape)
                == .read(Shape(value: "here")))
        #expect(register.current().isEmpty)
    }

    // MARK: - The register

    // The condition ends when the file becomes readable, and nothing else is evidence of that. A timer
    // would clear a line while the fault was still true.
    @Test func aFileThatReadsCleanlyAgainClearsItsOwnLine() throws {
        let register = HandoffReadFailures()
        let url = try temporaryFile(#"{"nope":1}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = HandoffFile.read(at: url, recorder: register, decode: decodeShape)
        #expect(register.current().count == 1)

        try Data(#"{"value":"fixed"}"#.utf8).write(to: url)
        _ = HandoffFile.read(at: url, recorder: register, decode: decodeShape)

        #expect(register.current().isEmpty)
    }

    // A file that has been deleted is no longer one Overture cannot read. Left standing, its line could
    // never be cleared by anything.
    @Test func aFileThatGoesAwayClearsItsOwnLine() throws {
        let register = HandoffReadFailures()
        let url = try temporaryFile(#"{"nope":1}"#)
        _ = HandoffFile.read(at: url, recorder: register, decode: decodeShape)
        #expect(register.current().count == 1)

        try FileManager.default.removeItem(at: url)
        _ = HandoffFile.read(at: url, recorder: register, decode: decodeShape)

        #expect(register.current().isEmpty)
    }

    // These reads happen on a poll, so a repeat is COUNTED rather than appended. A list of two hundred
    // identical lines is a list nobody reads (L36).
    @Test func repeatedFailuresOnOneFileAreCountedNotDuplicated() throws {
        let register = HandoffReadFailures()
        let url = try temporaryFile("not json")
        defer { try? FileManager.default.removeItem(at: url) }

        for _ in 0..<5 { _ = HandoffFile.read(at: url, recorder: register, decode: decodeShape) }

        #expect(register.current().count == 1)
        #expect(register.current().first?.count == 5)
    }

    // MARK: - The two exemptions

    // Each is NAMED for its reason, so a read that stays quiet says why rather than looking like one
    // somebody forgot. Both must genuinely record nothing, or the name is decoration.
    @Test func theNamedExemptionsRecordNothing() throws {
        let url = try temporaryFile("not json")
        defer { try? FileManager.default.removeItem(at: url) }

        for exempt in [HandoffReadFailures.readWhileBeingWritten,
                       HandoffReadFailures.reportedByItsOwnSurface] {
            guard case .unreadable = HandoffFile.read(at: url, recorder: exempt, decode: decodeShape) else {
                Issue.record("an exempt read must still ANSWER unreadable; it only declines to report")
                return
            }
            #expect(exempt.current().isEmpty)
        }
    }

    // MARK: - What Dan is told

    @Test func oneUnreadableFileNamesIt() {
        let notice = AppNotices.couldNotRead([
            .init(file: "overture-prep-results.json", reason: "it is not valid JSON", count: 1),
        ])
        #expect(notice?.text.contains("overture-prep-results.json") == true)
        #expect(notice?.tone == .warning)
        // The reason belongs in the detail, not in a headline that has to be read at a glance.
        #expect(notice?.help?.contains("it is not valid JSON") == true)
    }

    @Test func severalUnreadableFilesBecomeOneLineWithAllOfThemInTheDetail() {
        let notice = AppNotices.couldNotRead([
            .init(file: "a.json", reason: "one", count: 1),
            .init(file: "b.json", reason: "two", count: 3),
        ])
        #expect(notice?.text.contains("2 of the files") == true)
        #expect(notice?.help?.contains("a.json: one") == true)
        #expect(notice?.help?.contains("b.json: two") == true)
    }

    @Test func nothingUnreadableIsNoLineAtAll() {
        #expect(AppNotices.couldNotRead([]) == nil)
        #expect(!AppNotices.current(omniFocusFailing: false, unreadableFiles: [], status: StatusLine())
            .contains { $0.text.contains("couldn't read") })
    }

    @Test func theNoticeListCarriesTheUnreadableLine() {
        let notices = AppNotices.current(
            omniFocusFailing: false,
            unreadableFiles: [.init(file: "overture-results.json", reason: "why", count: 1)],
            status: StatusLine())
        #expect(notices.contains { $0.text.contains("overture-results.json") && $0.tone == .warning })
    }

    // MARK: - The class, derived rather than remembered (L96)

    // Every read of a file written by something outside the app must go through the shared reader. A
    // `try?` around a file read or a decode is the exact shape that hid #2873, and it is invisible in
    // review because it reads as ordinary defensive code.
    //
    // Derived by scanning the app's own source, not from a list of the sites that were converted, so a
    // NEW site cannot arrive unnoticed, which is the only way a sweep like this stays true (L96).
    // Scoped to FILE reads and to the named contract decoders, not to every `try?` decode in the app.
    // A decode of a NETWORK response (Gmail's JSON, Algolia's, Squarespace's) is a different class with a
    // different remedy, it is not what #2879 swept, and it has its own issue (#2888) rather than being
    // quietly folded in here or quietly left out (L129).
    @Test func noAppSourceSwallowsAFileRead() throws {
        let contractDecoders = ["PrepResultsDecoder", "ScoutExtractResultsDecoder",
                                "ReplyClassifyResultsDecoder", "PrepProgressDecoder",
                                "ReplyClassifyProgressDecoder", "ScoutExtractProgressDecoder"]
        let offenders = AppSourceWalk.appFiles()
            .filter { $0.name != "HandoffFile.swift" }
            .flatMap { file -> [String] in
                // Comments stripped, so a guard cannot be satisfied (or tripped) by prose ABOUT the
                // construct, which several of these files now carry describing the defect (L103).
                SwiftSource.scannableLines(in: file.text).compactMap { line in
                    let code = line.code
                    let swallowsAFileRead = code.contains("try? Data(contentsOf:")
                    let swallowsAContract = contractDecoders.contains {
                        code.contains("try? \($0).decode(")
                    }
                    guard swallowsAFileRead || swallowsAContract else { return nil }
                    return "\(file.name):\(line.line): \(code.trimmingCharacters(in: .whitespaces))"
                }
            }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    // A plain `try Data(contentsOf:)` is deliberately NOT flagged: it propagates to a caller that has
    // to handle it, which is the other honest answer, and four sites (both importers, DownbeatExport,
    // DebugSeed) rely on exactly that. So the rule above is the whole rule, and it needs no list of
    // exceptions, which is what keeps it derived rather than remembered (L96).

}
