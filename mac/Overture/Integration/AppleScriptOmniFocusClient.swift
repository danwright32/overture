import Foundation

// The real OmniFocus link (#176/#230). Talks to OmniFocus via NSAppleScript using the commands
// validated live against OmniFocus 4.8.12. This is the one piece that cannot be unit-tested; the
// pure decisions (what to create/complete) live in OmniFocusSync and ARE tested. Scoped strictly
// to Dan's "Outreach" project plus the "Overture" tag + a lead-key note, so it never touches his
// own tasks. Degrades by throwing (callers run it best-effort and swallow) if OmniFocus is absent
// or Automation permission is denied.
struct AppleScriptOmniFocusClient: OmniFocusClient {
    // Dan's existing "Outreach" project, targeted by id so a rename can't break it.
    private let projectId = "bAdQ9GQXfWn"
    private let tagNames = ["Overture", "1Important", "B. Medium Time Commitment"]
    private let ownerTag = "Overture"
    private let notePrefix = OmniFocusSync.notePrefix      // "Overture lead: "  (paragraph 1)
    private let duePrefix = OmniFocusSync.dueNotePrefix    // "Due: "            (paragraph 2)
    private let fieldSep = "|||"
    private let recordSep = "@@@"

    enum OmniFocusError: Error { case scriptFailed(String), notPermitted }

    // Incomplete Overture-tagged tasks, each as (naturalKey, due day rebuilt to the canonical 6pm
    // Eastern) so the due compares exactly against OmniFocusSync.desired. Reads the key and due day
    // from the note's first two paragraphs (text reads are reliable; AppleScript date-component
    // reads are not). Records are separated by a token, not newlines, since notes contain newlines.
    func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] {
        let src = """
        tell application "OmniFocus" to tell default document
          set ovt to first flattened tag whose name is "\(ownerTag)"
          set out to ""
          repeat with t in (tasks of ovt whose completed is false)
            set nt to note of t
            if (count of paragraphs of nt) is greater than or equal to 2 and (paragraph 1 of nt) starts with "\(esc(notePrefix))" then
              set out to out & (paragraph 1 of nt) & "\(fieldSep)" & (paragraph 2 of nt) & "\(recordSep)"
            end if
          end repeat
          return out
        end tell
        """
        let raw = try run(src)
        return raw.components(separatedBy: recordSep).compactMap { record in
            let fields = record.components(separatedBy: fieldSep)
            guard fields.count == 2 else { return nil }
            let line1 = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let line2 = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line1.hasPrefix(notePrefix), line2.hasPrefix(duePrefix) else { return nil }
            let key = String(line1.dropFirst(notePrefix.count))
            let ymd = line2.dropFirst(duePrefix.count).split(separator: "-").compactMap { Int($0) }
            guard ymd.count == 3, let due = easternDue(year: ymd[0], month: ymd[1], day: ymd[2]) else { return nil }
            return OmniFocusSync.ExistingTask(naturalKey: key, dueDate: due)
        }
    }

    func create(_ task: OmniFocusSync.DesiredTask) throws {
        // Build the note as linefeed-joined escaped lines so its paragraphs survive (esc collapses
        // newlines, so the note can't go into one quoted literal).
        let noteLiteral = task.note
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\"\(esc(String($0)))\"" }
            .joined(separator: " & linefeed & ")
        let src = """
        tell application "OmniFocus" to tell default document
          set p to first flattened project whose id is "\(projectId)"
          set t to make new task at end of tasks of p with properties {name:"\(esc(task.title))", note:\(noteLiteral)}
        \(dateExpr("dfr", task.deferDate))
          set defer date of t to dfr
        \(dateExpr("du", task.dueDate))
          set due date of t to du
        \(tagNames.map { "  add (first flattened tag whose name is \"\(esc($0))\") to tags of t" }.joined(separator: "\n"))
        end tell
        """
        _ = try run(src)
    }

    func complete(naturalKey: String) throws {
        let src = """
        tell application "OmniFocus" to tell default document
          set ovt to first flattened tag whose name is "\(ownerTag)"
          repeat with t in (tasks of ovt whose note contains "\(esc(notePrefix + naturalKey))")
            mark complete t
          end repeat
        end tell
        """
        _ = try run(src)
    }

    // MARK: - AppleScript plumbing

    private func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw OmniFocusError.scriptFailed("compile") }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 || code == -1744 { throw OmniFocusError.notPermitted }  // Automation not allowed
            throw OmniFocusError.scriptFailed((err[NSAppleScript.errorMessage] as? String) ?? "code \(code)")
        }
        return result.stringValue ?? ""
    }

    // Escape a string for embedding inside an AppleScript double-quoted literal.
    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }

    // Build an AppleScript date at the given Date's Eastern wall-clock. Sets day to 1 first to avoid
    // the classic month-overflow gotcha. The Mac runs in Eastern, so local AppleScript dates match.
    private func dateExpr(_ name: String, _ date: Date) -> String {
        let c = EasternDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return """
          set \(name) to (current date)
          set day of \(name) to 1
          set year of \(name) to \(c.year!)
          set month of \(name) to \(c.month!)
          set day of \(name) to \(c.day!)
          set hours of \(name) to \(c.hour!)
          set minutes of \(name) to \(c.minute!)
          set seconds of \(name) to 0
        """
    }

    private func easternDue(year: Int, month: Int, day: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = OmniFocusSync.dueHour; comps.minute = 0; comps.second = 0
        return EasternDate.calendar.date(from: comps)
    }
}
