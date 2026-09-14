import Testing
import Foundation

// #3551, milestone 77. A per item override exists to BEAT a shared default at the point of use, so
// its writer and its reader are two halves of one thing. Where the write survives and the read does
// not, every control saving that field reports success and changes nothing, because the value lands
// somewhere nothing consults. That is the class #3549 was one instance of (L402, L46).
//
// TWO questions, because the answers mean different things:
//
//   WRITTEN AND NEVER READ is the defect. Something is still putting values in, and the purpose they
//   were put in for cannot happen. It fails outright.
//
//   NEITHER WRITTEN NOR READ is retired storage, which in this app is a deliberate state rather than
//   a defect: it carries no MigrationPlan or VersionedSchema, so dropping a stored property would be
//   its first subtractive migration against a live store whose only net is the launch backup (see
//   AppSchema). Those must be DECLARED, with a reason, in fixtures/test-only-reachable.txt, which is
//   the registry this repo already keeps for exactly this. Reused rather than duplicated, because a
//   second list beside the first is two things to keep in step (L41).
//
// Written after #3549 nearly deleted `Recipient.overrideBody`, a persisted column, as a side effect
// of removing its reader. #3558 is the general guard for that; this is the narrower one about the
// override family, whose whole point is a value that beats another.
@Suite("Every stored override is read, or declared retired (#3551)")
struct EveryOverrideHasAReaderTests {

    // Measured 2026-09-05: 8 stored properties match. Set below that, because a tight number fails on
    // an ordinary deletion and teaches the next person to lower it without reading (L63).
    private static let floor = 4

    private struct Declaration {
        let name: String
        let file: String
        let line: Int
    }

    private func declarations(in files: [AppSourceWalk.File]) -> [Declaration] {
        var found: [Declaration] = []
        for file in files {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() {
                let indented = line.hasPrefix("    ") && !line.hasPrefix("     ")
                guard indented, !line.contains("{") else { continue }
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.hasPrefix("var ") || code.hasPrefix("@Attribute") else { continue }
                guard let varRange = code.range(of: "var ") else { continue }
                let name = String(code[varRange.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard name.lowercased().contains("override"), code.contains(":") else { continue }
                found.append(Declaration(name: name, file: file.name, line: index + 1))
            }
        }
        return found
    }

    // A line that ASSIGNS to the name, as against one that merely mentions it. Deliberately generous:
    // over-reporting a write makes this guard demand a reader that is already there, which is a loud
    // and correctable failure, where under-reporting silently lets the real defect through.
    private func isWrite(_ code: String, _ name: String) -> Bool {
        guard let range = code.range(of: name) else { return false }
        let after = code[range.upperBound...].drop { $0 == " " }
        return after.hasPrefix("=") && !after.hasPrefix("==")
    }

    // The repo's existing registry of declarations only the tests reach. A line carrying a `#` reason
    // has been looked at; one without it is untriaged debt, by that file's own rule.
    private func declaredRetiredWithAReason() throws -> Set<String> {
        let url = RepoRoot.url.appendingPathComponent("fixtures/test-only-reachable.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var declared: Set<String> = []
        for line in text.components(separatedBy: "\n") {
            guard !line.hasPrefix("#"), line.contains("#") else { continue }
            let entry = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            declared.insert(entry)
        }
        return declared
    }

    @Test func anOverrideThatIsWrittenAndNeverReadIsTheDefect() throws {
        let files = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("Overture"))
        if let refusal = AppSourceWalk.refusal(found: files.count, floor: AppSourceWalk.appFloor,
                                               directory: "mac/Overture") {
            Issue.record(Comment(rawValue: refusal)); return
        }
        let declared = declarations(in: files)
        #expect(declared.count >= Self.floor, """
            Found \(declared.count) stored override properties, fewer than the \(Self.floor) this needs \
            to be checking anything. A broken scan, not a clean app (L98).
            """)

        var writtenNeverRead: [String] = []
        for declaration in declared {
            var reads = 0, writes = 0
            for file in files {
                for (index, line) in file.text.components(separatedBy: "\n").enumerated()
                where line.contains(declaration.name) {
                    if file.name == declaration.file && index + 1 == declaration.line { continue }
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if isWrite(code, declaration.name) { writes += 1 } else { reads += 1 }
                }
            }
            if writes > 0 && reads == 0 {
                writtenNeverRead.append("\(declaration.file):\(declaration.line)  \(declaration.name)  (\(writes) writes, 0 reads)")
            }
        }

        #expect(writtenNeverRead.isEmpty, """
            Something writes this override and nothing reads it, so every control saving it reports \
            success and changes nothing downstream (#3551, L402, L46). Either read it where the rule it \
            was meant to beat is applied, or delete the write and the control with it.
            \(writtenNeverRead.joined(separator: "\n"))
            """)
    }

    @Test func anOverrideNothingTouchesIsDeclaredRetiredWithAReason() throws {
        let files = AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("Overture"))
        if let refusal = AppSourceWalk.refusal(found: files.count, floor: AppSourceWalk.appFloor,
                                               directory: "mac/Overture") {
            Issue.record(Comment(rawValue: refusal)); return
        }
        let retired = try declaredRetiredWithAReason()
        #expect(!retired.isEmpty, """
            No declaration in fixtures/test-only-reachable.txt carries a reason, so this guard read \
            nothing and would pass over every undeclared field. Unmeasured, not clean (L98).
            """)

        var undeclared: [String] = []
        for declaration in declarations(in: files) {
            var touches = 0
            for file in files {
                for (index, line) in file.text.components(separatedBy: "\n").enumerated()
                where line.contains(declaration.name) {
                    if file.name == declaration.file && index + 1 == declaration.line { continue }
                    touches += 1
                }
            }
            guard touches == 0 else { continue }
            if !retired.contains("\(declaration.file):\(declaration.name)") {
                undeclared.append("\(declaration.file):\(declaration.line)  \(declaration.name)")
            }
        }

        #expect(undeclared.isEmpty, """
            A stored override nothing writes and nothing reads. In this app that is usually RETIRED \
            STORAGE kept on purpose, because dropping a stored property would be its first subtractive \
            migration against Dan's live store (see AppSchema, #3558). Say so: add it to \
            fixtures/test-only-reachable.txt WITH a `#` reason, so the next sweep reads a decision \
            rather than rediscovering it and proposing a column drop (L233, L346).
            \(undeclared.joined(separator: "\n"))
            """)
    }
}
