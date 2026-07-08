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
    private let notePrefix = OmniFocusSync.notePrefix          // "Overture lead: "     (paragraph 1)
    private let contactPrefix = OmniFocusSync.contactNotePrefix // "Overture contact: "  (paragraph 2, #653)
    private let duePrefix = OmniFocusSync.dueNotePrefix         // "Due: "               (paragraph 3)
    private let fieldSep = "|||"
    private let recordSep = "@@@"
    // #653: a pre-existing task written before this shipped has no contact line at all (the old
    // 2-paragraph format). Tag it with a recipientId that can never match a real desired task, so
    // reconcile always treats it as stale -- the one-time transition: it completes and the correct
    // new per-recipient task gets created fresh on the first sync after this ships.
    private static let legacyRecipientId = "__legacy-pre-653__"

    enum OmniFocusError: Error { case scriptFailed(String), notPermitted }

    // Incomplete Overture-tagged tasks, each as (naturalKey, recipientId, due day rebuilt to the
    // canonical 6pm Eastern) so the due compares exactly against OmniFocusSync.desired. Reads the key,
    // contact, and due day from the note's paragraphs (text reads are reliable; AppleScript
    // date-component reads are not). Records are separated by a token, not newlines, since notes
    // contain newlines. A legacy 2-paragraph note (pre-#653) has no contact line; it's tagged with
    // legacyRecipientId instead of failing to parse.
    func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] {
        let src = """
        tell application "OmniFocus" to tell default document
          set ovt to first flattened tag whose name is "\(ownerTag)"
          set out to ""
          repeat with t in (tasks of ovt whose completed is false)
            set nt to note of t
            set pCount to count of paragraphs of nt
            if pCount >= 2 and (paragraph 1 of nt) starts with "\(esc(notePrefix))" then
              if pCount >= 3 then
                set out to out & (paragraph 1 of nt) & "\(fieldSep)" & (paragraph 2 of nt) & "\(fieldSep)" & (paragraph 3 of nt) & "\(recordSep)"
              else
                set out to out & (paragraph 1 of nt) & "\(fieldSep)" & "\(Self.legacyRecipientId)" & "\(fieldSep)" & (paragraph 2 of nt) & "\(recordSep)"
              end if
            end if
          end repeat
          return out
        end tell
        """
        let raw = try run(src)
        return raw.components(separatedBy: recordSep).compactMap { record in
            let fields = record.components(separatedBy: fieldSep)
            guard fields.count == 3 else { return nil }
            let line1 = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let contactField = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let line3 = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line1.hasPrefix(notePrefix), line3.hasPrefix(duePrefix) else { return nil }
            let key = String(line1.dropFirst(notePrefix.count))
            let recipientId: String
            if contactField == Self.legacyRecipientId {
                recipientId = Self.legacyRecipientId
            } else if contactField.hasPrefix(contactPrefix) {
                recipientId = String(contactField.dropFirst(contactPrefix.count))
            } else {
                return nil   // unrecognized shape: skip rather than guess
            }
            let ymd = line3.dropFirst(duePrefix.count).split(separator: "-").compactMap { Int($0) }
            guard ymd.count == 3, let due = easternDue(year: ymd[0], month: ymd[1], day: ymd[2]) else { return nil }
            return OmniFocusSync.ExistingTask(naturalKey: key, recipientId: recipientId, dueDate: due)
        }
    }

    func create(_ task: OmniFocusSync.DesiredTask) throws {
        // Build the note as linefeed-joined escaped lines so its paragraphs survive (esc collapses
        // newlines, so the note can't go into one quoted literal).
        let noteLiteral = task.note
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\"\(esc(String($0)))\"" }
            .joined(separator: " & linefeed & ")
        // Build the dates in plain AppleScript context FIRST. Inside a `tell application "OmniFocus"`
        // block, OmniFocus's dictionary shadows the date terms day/month/year and setting them throws
        // "Can't get day. Access not allowed." So construct dfr/du out here, then pass them in.
        let src = """
        \(dateExpr("dfr", task.deferDate))
        \(dateExpr("du", task.dueDate))
        tell application "OmniFocus" to tell default document
          set p to first flattened project whose id is "\(projectId)"
          set t to make new task at end of tasks of p with properties {name:"\(esc(task.title))", note:\(noteLiteral)}
          set defer date of t to dfr
          set due date of t to du
        \(tagNames.map { "  add (first flattened tag whose name is \"\(esc($0))\") to tags of t" }.joined(separator: "\n"))
        end tell
        """
        _ = try run(src)
    }

    // #653: scoped to the specific recipient's task, not every task on the show. A legacy (pre-#653)
    // task carries no contact line at all; matched by its ABSENCE rather than a literal sentinel
    // string, since the sentinel never actually appears in a real note.
    func complete(naturalKey: String, recipientId: String) throws {
        let matchClause = recipientId == Self.legacyRecipientId
            ? "note of t does not contain \"\(esc(contactPrefix))\""
            : "note of t contains \"\(esc(contactPrefix + recipientId))\""
        let src = """
        tell application "OmniFocus" to tell default document
          set ovt to first flattened tag whose name is "\(ownerTag)"
          repeat with t in (tasks of ovt whose completed is false and note contains "\(esc(notePrefix + naturalKey))")
            if \(matchClause) then
              mark complete t
            end if
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
