import AppKit
import ApplicationServices

// #3503: post a real scroll wheel to ANOTHER process, and say whether it landed.
//
// `RealScrollInvalidationTests` can already drive a wheel event, but only into an `NSScrollView` its own
// process owns, which settles the SwiftUI mechanism question and nothing else. The measurement scripts
// still cannot scroll anything at all, and #3439 is the decision gate that has to record the cost of one
// scroll frame on the running app. `scripts/freeze-measure.sh` samples a live process and has no way to
// make it scroll; `cliclick` on this Mac has move, click and wait, with no wheel.
//
// TWO THINGS #3480 LEARNED THE HARD WAY, and both shape this.
//
// 1. A scroll that did nothing and a surface that does not rebuild on scroll produce IDENTICAL readings,
//    and the second is the thing being tested (L159). So this reads the target's scroll position through
//    the accessibility API before and after, and its three outcomes are LANDED, DID NOT MOVE, and
//    UNMEASURED, never two (L98, L11). UNMEASURED is what an unreadable tree produces, and it is kept
//    apart from "did not move" because they call for opposite next steps.
//
// 2. Overture is `LSUIElement`, so it NEVER becomes frontmost, which is what defeated the accessibility
//    route on #3480. So nothing here waits for focus or activates anything: the event is posted to the
//    process by pid, which does not require the app to be frontmost, and the position is read off the
//    window rather than off whatever is focused.
//
// It refuses rather than guessing, in every case it cannot settle, because a measurement script that
// reports a scroll it did not take is worse than one that reports nothing.

// --- arguments ----------------------------------------------------------------------------------------

struct Options {
    var pid: pid_t?
    var turns = 12
    var delta: Int32 = -60
    var requireMovement = true
}

func usage() -> String {
    """
    usage: post-scroll-wheel.swift --pid <pid> [--turns N] [--delta N] [--no-confirm]

      --pid N        the process to scroll. Required: this posts to a process, never to whatever
                     happens to be under the pointer, because a measurement aimed at the wrong window
                     is a reading about something nobody asked about.
      --turns N      wheel turns to post (default 12).
      --delta N      pixels per turn, negative for down (default -60).
      --no-confirm   post without reading the position back. Reports SENT rather than LANDED, and says
                     so, because an unconfirmed scroll and a confirmed one must not read alike.
    """
}

// A hand-rolled either rather than `Result`, because `Result`'s failure has to be an `Error`
// and the failure here is a sentence for a person to read.
enum Parsed { case success(Options); case failure(String) }

func parse(_ argv: [String]) -> Parsed {
    var o = Options()
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        func next() -> String? { i + 1 < argv.count ? argv[i + 1] : nil }
        switch arg {
        case "--pid":
            guard let v = next(), let n = Int32(v), n > 0 else { return .failure("--pid needs a positive number") }
            o.pid = n; i += 2
        case "--turns":
            guard let v = next(), let n = Int(v), n > 0 else { return .failure("--turns needs a positive number") }
            o.turns = n; i += 2
        case "--delta":
            guard let v = next(), let n = Int32(v), n != 0 else { return .failure("--delta needs a non-zero number") }
            o.delta = n; i += 2
        case "--no-confirm":
            o.requireMovement = false; i += 1
        case "--help", "-h":
            return .failure(usage())
        default:
            return .failure("unrecognised argument \(arg)\n\n\(usage())")
        }
    }
    guard o.pid != nil else { return .failure("--pid is required\n\n\(usage())") }
    return .success(o)
}

// --- reading the position -------------------------------------------------------------------------------
//
// The FIRST scroll area found anywhere in the app's window tree, and its vertical scroll bar's value,
// which is a Double from 0 to 1. Read through the accessibility API, which needs this Mac to have granted
// the running terminal accessibility permission; without it the tree comes back empty and the answer is
// UNMEASURED rather than a movement claim nobody measured.

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(of element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func firstScrollPosition(under element: AXUIElement, depth: Int = 0) -> Double? {
    guard depth < 40 else { return nil }
    if let role = attribute(element, kAXRoleAttribute as String) as? String, role == kAXScrollAreaRole {
        for child in children(of: element) {
            guard let childRole = attribute(child, kAXRoleAttribute as String) as? String,
                  childRole == kAXScrollBarRole else { continue }
            guard let orientation = attribute(child, kAXOrientationAttribute as String) as? String,
                  orientation == kAXVerticalOrientationValue else { continue }
            if let value = attribute(child, kAXValueAttribute as String) as? Double { return value }
        }
    }
    for child in children(of: element) {
        if let found = firstScrollPosition(under: child, depth: depth + 1) { return found }
    }
    return nil
}

func scrollPosition(of pid: pid_t) -> Double? {
    firstScrollPosition(under: AXUIElementCreateApplication(pid))
}

// --- posting ---------------------------------------------------------------------------------------------

func postWheel(to pid: pid_t, turns: Int, delta: Int32) -> Bool {
    var posted = 0
    for _ in 0..<turns {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { continue }
        // To the PROCESS, not to the session tap: a session-tap post lands wherever the pointer is,
        // which for a measurement is a reading about whatever window happened to be under it.
        event.postToPid(pid)
        posted += 1
        // A real wheel arrives as a series of turns rather than all at once, and a view that coalesces
        // them can otherwise treat the whole burst as one. 8ms is well inside one frame at 60Hz.
        usleep(8000)
    }
    return posted == turns
}

// --- the self test -------------------------------------------------------------------------------------
//
// `parse` is the whole of this file that can be exercised without a window on screen and without posting
// a real event into whatever is in front of Dan, so it is exercised HERE and driven from the shell
// fixture. What cannot be: `postWheel` needs a target process, and `scrollPosition` needs a window tree
// and accessibility permission. Those two are why `scripts/scroll-wheel.sh` refuses without `--yes` and
// why its own three outcomes are the thing the fixture drives, through a stubbed poster.
//
// Run by `scripts/scroll-wheel.test.sh` on every push. It replaces a bare `swiftc -parse`, which proved
// only that the file still compiled: a parse is not a test, and this way the same second of compiling
// buys an actual assertion (L1).

func selfTest() -> Int32 {
    var failures: [String] = []
    func check(_ what: String, _ holds: Bool) {
        if holds { print("ok - \(what)") } else { print("FAIL - \(what)"); failures.append(what) }
    }
    func parsed(_ argv: [String]) -> Options? {
        if case .success(let o) = parse(argv) { return o }
        return nil
    }
    func refused(_ argv: [String]) -> String? {
        if case .failure(let message) = parse(argv) { return message }
        return nil
    }

    // A target is REQUIRED. There is deliberately no default and no "whatever is under the pointer"
    // fallback: a measurement aimed at the wrong window is a reading about something nobody asked about.
    check("no --pid is refused", refused([])?.contains("--pid is required") == true)
    check("an unknown argument is refused", refused(["--nope"])?.contains("unrecognised") == true)
    check("--pid with no value is refused", refused(["--pid"]) != nil)
    check("--pid with a non-number is refused", refused(["--pid", "x"]) != nil)
    check("--pid 0 is refused", refused(["--pid", "0"]) != nil)

    // Zero turns and a zero delta are refused rather than accepted, because both post nothing and would
    // then report LANDED or DID NOT MOVE about a scroll that was never attempted (L98).
    check("--turns 0 is refused", refused(["--pid", "9", "--turns", "0"]) != nil)
    check("--delta 0 is refused", refused(["--pid", "9", "--delta", "0"]) != nil)

    let defaults = parsed(["--pid", "42"])
    check("a bare --pid parses", defaults?.pid == 42)
    check("and defaults to 12 turns", defaults?.turns == 12)
    check("and to -60px, which scrolls DOWN", defaults?.delta == -60)
    check("and confirms the landing by default", defaults?.requireMovement == true)

    let custom = parsed(["--pid", "7", "--turns", "3", "--delta", "25", "--no-confirm"])
    check("--turns is read", custom?.turns == 3)
    check("--delta is read, including a positive one for scrolling UP", custom?.delta == 25)
    check("--no-confirm turns the landing check off", custom?.requireMovement == false)

    // The usage text names every flag it accepts, so a flag that exists and is undocumented, or one
    // documented and removed, goes red here rather than being found by somebody typing it.
    let usageText = usage()
    for flag in ["--pid", "--turns", "--delta", "--no-confirm"] {
        check("usage names \(flag)", usageText.contains(flag))
    }

    if failures.isEmpty {
        print("All post-scroll-wheel.swift self-test assertions passed.")
        return 0
    }
    print("\(failures.count) post-scroll-wheel.swift self-test assertion(s) failed.")
    return 1
}

// --- the run -----------------------------------------------------------------------------------------------

let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "--self-test" { exit(selfTest()) }
let options: Options
switch parse(argv) {
case .success(let o): options = o
case .failure(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
guard let pid = options.pid else { exit(2) }

guard NSRunningApplication(processIdentifier: pid) != nil else {
    print("UNMEASURED: no running application with pid \(pid)")
    exit(2)
}

let before = options.requireMovement ? scrollPosition(of: pid) : nil
if options.requireMovement && before == nil {
    print("""
    UNMEASURED: could not read a vertical scroll bar anywhere in pid \(pid)'s window tree.
      Either the app has no window open, or this terminal has not been granted accessibility \
    permission, or the surface draws no scroll bar. Nothing was posted: a scroll whose landing cannot \
    be checked is the reading #3480 spent a day being misled by.
    """)
    exit(2)
}

guard postWheel(to: pid, turns: options.turns, delta: options.delta) else {
    print("UNMEASURED: the system refused to build a scroll wheel event")
    exit(2)
}

guard options.requireMovement else {
    print("SENT: \(options.turns) turns of \(options.delta)px posted to pid \(pid), landing NOT checked")
    exit(0)
}

// The position is read back on a short poll rather than once: the event is delivered asynchronously and
// the target redraws on its own schedule, so a single immediate read measures the delivery rather than
// the scroll.
var after = before
let deadline = Date().addingTimeInterval(2)
while Date() < deadline {
    after = scrollPosition(of: pid)
    if after != before { break }
    usleep(50000)
}

if let a = after, let b = before, a != b {
    print(String(format: "LANDED: scroll position moved %.4f to %.4f over %d turns", b, a, options.turns))
    exit(0)
}
print("""
DID NOT MOVE: the scroll position is still \(before.map { String(format: "%.4f", $0) } ?? "unknown") \
after \(options.turns) turns.
  The event was posted and the tree was readable, so this is a real finding about the surface rather \
than a failure to measure. It is what a list already scrolled to its end looks like too.
""")
exit(1)
