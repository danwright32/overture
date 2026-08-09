import Testing
import Foundation

// #1689: the nudge is only as honest as the classification under it, and the classification only holds
// if EVERY line the app writes on purpose goes through it. One raw `NSLog` added later is a line nobody
// called a note or a problem, and it lands back in the undifferentiated pile this issue is about.
//
// So the rule is structural rather than a habit: `AgentLog` is the only place in the app allowed to
// call NSLog, and everywhere else states which kind of line it is writing. Whoever adds the next one is
// forced to answer the question at the moment they know the answer (L30: fix the class, not the
// instance).
@Suite("Every line the app logs says what kind it is (#1689)")
struct EveryLoggedLineIsClassifiedGuardTests {
    // Every Swift file under Overture/, with its own name.
    //
    // #2311: through the shared walk, which refuses out loud when it comes back empty. A guard that
    // walks an empty list passes over every file it was meant to check, reporting a clean app rather
    // than a broken path, and the floor lives in the walk so this one cannot forget it.
    private func appSources() -> [(path: String, text: String)] {
        AppSourceWalk.appFiles().map { (path: $0.name, text: $0.text) }
    }

    @Test func onlyAgentLogMayCallNSLogDirectly() {
        let sources = appSources()
        // The walk itself has to be real: an empty list would make every assertion below vacuous.
        #expect(sources.count > 100, "expected to walk the app's sources, found \(sources.count)")

        let offenders = sources
            .filter { $0.path != "AgentLog.swift" }
            .filter { source in
                SwiftSource.scannableLines(in: source.text, skipping: .scaffolding)
                    .contains { $0.code.contains("NSLog(") }
            }
            .map(\.path)
            .sorted()

        #expect(offenders.isEmpty,
                "these log without saying whether it is a note or a problem: \(offenders.joined(separator: ", "))")
    }

    // And the classification is a real fork, not two names for one behaviour: a note must not be able to
    // reach the ledger the nudge reads. Proven behaviourally in AgentLogTests; asserted here as the
    // shape, so the fork cannot be quietly flattened into "record everything".
    @Test func theTwoKindsAreDistinctAtTheCallSite() {
        let sources = appSources()
        let usesAgentLog = sources.filter {
            $0.text.contains("AgentLog.note(") || $0.text.contains("AgentLog.problem(")
        }
        #expect(usesAgentLog.count >= 8,
                "expected the app's deliberate log lines to be classified, found \(usesAgentLog.count) files")
        #expect(sources.contains { $0.text.contains("AgentLog.note(") },
                "no routine report is recorded as a note")
        #expect(sources.contains { $0.text.contains("AgentLog.problem(") },
                "no failure is recorded as a problem")
    }
}
