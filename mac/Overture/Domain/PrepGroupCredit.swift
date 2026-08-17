import Foundation

// #1804: one paid lookup answers for every show the app grouped under it.
//
// A reachability check costs about $1.36 a show, so when several shows share one producer the app puts a
// single item on the work-list carrying `alsoAnswersFor`, the other shows it stands for (#1597). The runbook
// then tells the run to write a result entry for its own key AND for every key in that list.
//
// Nothing enforced that, and it is a rule that lives only in a prompt (L27). A run that wrote one entry for
// a group of eight broke three things at once: the seven covered shows were left unstamped, so they were
// selected and PAID FOR again; they never received the contact the lookup found; and #1769's shortfall
// sentence counted them as never answered, telling Dan seven shows went unanswered when the lookup that
// covers them came home fine. An alert that cries wolf gets ignored (L36), and that one would have cried
// wolf on exactly the runs the grouping was built to make cheap.
//
// The app wrote the grouping, so the app credits it. That is structure rather than instructions: a
// compliant run and a terse one now settle identically, and neither depends on the model restating what
// the app already knows.
//
// WHAT IS CREDITED, and what deliberately is not (Dan's call, 2026-07-31). A covered show inherits the
// CONTACTS the lookup found, and nothing else. It never inherits a "we looked and there is nobody" verdict,
// and never a draft.
//
// The asymmetry is the point. The grouping rule is a judgment about names and venues (`ProducerGate`) and it
// has been wrong before: it read Carnegie Hall Presents as a well travelled producer for a day, across 25
// rows, until #1620. If a group is ever wrong again, spreading a found contact puts a wrong address on a few
// shows, which the next check corrects and which Dan sees on the card. Spreading a NEGATIVE would stamp
// those shows "no email found" and the badge's 90 day trust would lock them out of a re-check for three
// months, with nothing on screen saying why. So the cheap failure is allowed to spread and the expensive one
// is not, and a group whose lead found nobody simply leaves its covered shows unchecked to be offered again.
enum PrepGroupCredit {

    // The grouping the app wrote, read back off the queue, as lead key to the keys it answers for.
    //
    // Returns nothing at all unless these results can actually BE an answer to this queue. startPrep writes
    // a fresh queue but leaves the PREVIOUS run's results file on disk, so a results file older than its
    // queue is not an answer to it. HandoffShortfall already had to decide exactly this and settled on the
    // results FILE's modification time against the queue's `generatedAt`, trusting the filesystem's clock
    // over anything a model wrote inside the file. Reused rather than restated, because crediting across a
    // mismatched pair is far worse than the miscounted warning that rule was written for: it would fan one
    // producer's contact onto another producer's shows.
    static func groups(queueURL: URL, resultsURL: URL) -> [String: [String]] {
        // Best-effort on purpose, matching HandoffShortfall: an unreadable queue means the app has no record
        // of what it grouped, and no record is never a licence to spread an answer.
        // #2879: unchanged behaviour, recorded read. No record of what was grouped is still never a
        // licence to spread an answer.
        guard let queue = HandoffFile.read(at: queueURL,
                                           decode: { try JSONDecoder().decode(PrepQueue.self, from: $0) }).value
        else { return [:] }
        let modified = (try? FileManager.default.attributesOfItem(atPath: resultsURL.path))?[.modificationDate] as? Date
        return groups(in: queue, resultsModifiedAt: modified)
    }

    static func groups(in queue: PrepQueue, resultsModifiedAt: Date?) -> [String: [String]] {
        guard let resultsModifiedAt,
              let generatedAt = ISO8601DateFormatter().date(from: queue.generatedAt),
              resultsModifiedAt >= generatedAt else { return [:] }
        var out: [String: [String]] = [:]
        for item in queue.items {
            guard let covered = item.alsoAnswersFor, !covered.isEmpty else { continue }
            out[item.naturalKey] = covered
        }
        return out
    }

    // The run's results, plus an entry for every show a lead answered for that the run did not write itself.
    //
    // A synthesized entry carries the lead's contacts and NOTHING else, which is what makes it safe to hand
    // to the ordinary import path: `PrepImporter` treats it exactly like an entry the run wrote, so there is
    // no second contact-copying code path to keep in step with the first.
    static func credited(_ results: [PrepResult], groups: [String: [String]]) -> [PrepResult] {
        guard !groups.isEmpty else { return results }
        // A key the run answered ITSELF is never replaced. A compliant run researched that show
        // specifically, so its own entry is better evidence than the lead's and must win.
        var answered = Set(results.map(\.naturalKey))
        var out = results
        for result in results {
            guard let covered = groups[result.naturalKey] else { continue }
            // The lead came back having found nobody. Credit nothing: see the note above on why a negative
            // never spreads. The lead itself keeps its own honest answer.
            guard let contacts = result.contacts, !contacts.isEmpty else { continue }
            for key in covered where !answered.contains(key) {
                // Contacts only. A draft names one show, its date and its material, so copying one onto a
                // sibling would put another show's pitch in front of Dan under this show's name. Only a
                // check carries a grouping today and a check never drafts, so this is the belt to that
                // braces. `emptyReason`, `showSummary` and `alreadyCoveredNote` are all statements about the
                // lead's own page and research, and none of them is true of a different show.
                out.append(PrepResult(naturalKey: key, contacts: contacts))
                answered.insert(key)
            }
        }
        return out
    }
}
