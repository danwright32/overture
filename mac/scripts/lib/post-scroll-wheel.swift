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

// #3588: WHY the tree could not be read, as three separate facts.
//
// The one message this replaced listed all three causes and named none, so the reader had to go and
// find out by hand which one it was. On 2026-09-14, the first time this tool was ever pointed at the
// running app, that is exactly what happened: it reported "no window, or no permission, or no scroll
// bar", and a probe written on the spot showed accessibility was granted, the read returned cleanly,
// and the app had zero windows. Every fact needed to say so was already available here (L11).
//
// The ORDER is load bearing and is asserted in the self test. An untrusted process reads ZERO windows,
// so asking about the window count first would report a permission problem as "no window open" and send
// somebody to open a window that is already open: one guard answering for another (L70).
enum TreeRefusal {
    case notTrusted
    case noWindow
    case noScrollBar
}

func diagnoseTree(trusted: Bool, windows: Int) -> TreeRefusal {
    if !trusted { return .notTrusted }
    if windows == 0 { return .noWindow }
    return .noScrollBar
}

func refusalMessage(_ refusal: TreeRefusal, pid: pid_t) -> String {
    switch refusal {
    case .notTrusted:
        return """
        UNMEASURED: this process has no accessibility permission, so it cannot read any app's window \
        tree and nothing about pid \(pid) was measured.
          Grant it in System Settings, Privacy and Security, Accessibility, to the terminal or tool \
        running this. Nothing was posted.
        """
    case .noWindow:
        return """
        UNMEASURED: pid \(pid) has accessibility permission granted and NO WINDOW OPEN, so there is \
        nothing to scroll.
          Overture can run with its window closed. Open it, put a list on screen, and run this again. \
        Nothing was posted.
        """
    case .noScrollBar:
        return """
        UNMEASURED: pid \(pid) has a window open and no VERTICAL SCROLL BAR anywhere in its tree.
          This is the reading about the SURFACE rather than about the setup: either the list is short \
        enough not to scroll, or it draws no scroll bar for the accessibility API to report. A scroll \
        whose landing cannot be checked is the reading #3480 spent a day being misled by, so nothing \
        was posted.
        """
    }
}

/// How many windows the app has, read through the same API the position read uses.
func windowCount(of pid: pid_t) -> Int {
    (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute as String) as? [AXUIElement])?.count ?? 0
}

// #3588: whether the surface COULD have scrolled, so a position that did not move is one finding rather
// than two folded together.
//
// `nil` is its own answer and is not folded into either: an extent that could not be read says nothing
// about the surface, and reporting it as "there was nothing to scroll" would turn a failed measurement
// into a reassuring one (L98).
func couldHaveScrolled(visible: Double?, content: Double?) -> Bool? {
    guard let visible, let content else { return nil }
    return content > visible
}

/// The scroll area's own height, and the tallest thing inside it, read off the same tree.
func scrollExtent(of pid: pid_t) -> (visible: Double?, content: Double?) {
    guard let area = firstScrollArea(under: AXUIElementCreateApplication(pid)) else { return (nil, nil) }
    func height(_ element: AXUIElement) -> Double? {
        guard let value = attribute(element, kAXSizeAttribute as String) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size.height
    }
    // The TALLEST child rather than the first: the content group sits among the headings and controls
    // the surface also puts in the scroll area, and which index it lands on is a layout detail (L237).
    let tallest = children(of: area).compactMap(height).max()
    return (height(area), tallest)
}

/// What the extent says about a position that did not move, in one line.
func extentLine(of pid: pid_t) -> String {
    let extent = scrollExtent(of: pid)
    switch couldHaveScrolled(visible: extent.visible, content: extent.content) {
    case true:
        return """
          Its content is \(Int(extent.content ?? 0))pt inside a \(Int(extent.visible ?? 0))pt viewport, so \
        it COULD have scrolled. A posted wheel event is not driving this surface.
        """
    case false:
        return """
          Its content is \(Int(extent.content ?? 0))pt inside a \(Int(extent.visible ?? 0))pt viewport, so \
        there was nothing to scroll. Put a longer list on screen and measure again.
        """
    case nil:
        return """
          Whether it COULD have scrolled could not be read, so this says nothing about the surface \
        either way.
        """
    }
}

func firstScrollArea(under element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 40 else { return nil }
    if let role = attribute(element, kAXRoleAttribute as String) as? String, role == kAXScrollAreaRole {
        return element
    }
    for child in children(of: element) {
        if let found = firstScrollArea(under: child, depth: depth + 1) { return found }
    }
    return nil
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

    // #3588: the three reasons the tree can be unreadable are three different facts with three
    // different remedies, and until now one message listed all three and named none (L11). Measured
    // 2026-09-14 against Dan's running Release app: the tool said UNMEASURED naming all three, and a
    // hand-written probe then showed accessibility WAS granted, the read SUCCEEDED, and the app had
    // zero windows. The tool had every fact it needed to say that and said none of them.
    check("no accessibility permission is its own answer",
          diagnoseTree(trusted: false, windows: 0) == .notTrusted)
    check("permission is checked BEFORE the window count, because an untrusted read reports zero windows",
          diagnoseTree(trusted: false, windows: 3) == .notTrusted)
    check("a trusted read of an app with no window is its own answer",
          diagnoseTree(trusted: true, windows: 0) == .noWindow)
    check("a window with no vertical scroll bar in it is the third, and the only one about the surface",
          diagnoseTree(trusted: true, windows: 1) == .noScrollBar)
    check("each answer names a different remedy",
          Set([TreeRefusal.notTrusted, .noWindow, .noScrollBar].map { refusalMessage($0, pid: 1) }).count == 3)

    // #3588: a surface that DID NOT MOVE is two different findings and the message used to be one.
    // Measured 2026-09-14 on Dan's running Release app: the scroll area's viewport is 875pt and its
    // content group is 2,600pt over 217 children, so the list could certainly have scrolled, and the
    // bar still read 0.0000 after 12 down turns. Told apart by the same rule as every other pair here,
    // because "the list was already at its end" and "the event did not drive the surface" call for
    // opposite next steps (L11).
    check("content taller than the viewport means the surface COULD have scrolled",
          couldHaveScrolled(visible: 875, content: 2600) == true)
    check("content that fits means there was nothing to scroll",
          couldHaveScrolled(visible: 875, content: 400) == false)
    check("content exactly the height of the viewport is nothing to scroll",
          couldHaveScrolled(visible: 875, content: 875) == false)
    check("an unreadable extent is neither, and says so rather than guessing",
          couldHaveScrolled(visible: nil, content: nil) == nil)

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
    // #3588: read BOTH facts and say which of the three it is, rather than listing all three.
    print(refusalMessage(diagnoseTree(trusted: AXIsProcessTrusted(), windows: windowCount(of: pid)),
                         pid: pid))
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
than a failure to measure.
\(extentLine(of: pid))
""")
exit(1)
