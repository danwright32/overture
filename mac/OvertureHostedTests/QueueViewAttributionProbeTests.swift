import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4106, the VIEW workstream's first step: WHERE the queue's draw time goes (attribution only, no fix).
//
// Probe 0c.8 (`QueueViewBodyCostProbeTests`, #4299) timed the queue drawing a SERVED RenderData and put
// the first draw at 16 to 18 ms per realised row in Debug. Gate 0c failed on that (#4106 comment
// 5861367299) and Dan added a view workstream (comment 5861374913). Nothing said where the time went, so
// this probe asks two questions of the same three readings 0c.8 takes (a first draw, one row dismissed and
// its undo, a stage focus change):
//
//   1. WHICH FRAMES own the main thread while the reading runs. `/usr/bin/sample` is pointed at this test
//      process for a round of back to back readings (the sampler ScoutLandingAttributionProbeTests uses,
//      now shared in TestSupport), and every main thread sample is classified by the frame that owns it.
//      A counter only sees what somebody instrumented; a sampler sees every frame (L63).
//   2. HOW MANY things each reading touched: card bodies evaluated, rows realised, date groups realised
//      and the rows inside them, cards built and contacts reached inside the body (WorkTally), and the
//      ForEach identities the list hands SwiftUI to diff.
//
// #4311 added a fourth kind, the Reached out stage (one of its shows closed and back), which the stage
// change skips because that list is its own branch of the view: the window is put on the stage by a deep
// link first, the production route. Its count line says how many stage list rows and calendar tables the
// BODY derived per reading, which is the cost that issue moved into the pass.
//
// And a third reading that neither of those can give on its own: the first draw at three WINDOW HEIGHTS
// on one corpus. Going from the live clone to the 4x corpus multiplies the stage's rows AND the rows
// realised by four at once, so a cost proportional to either reads identically (L209). Holding the
// corpus fixed and moving only the viewport separates them: what grows with the window is per realised
// row, what stays is per stage.
//
// SCOPING THE SAMPLES. Only samples with `Phase0cView.settle` on the stack count, which is the same window
// 0c.8 times. Inside it, three things are held apart rather than mixed into the shares: the rig's own
// bookkeeping (its dirty view walk and counter reads, which 0c.8 subtracts from its numbers too), the
// main thread IDLE in `mach_msg` waiting for the run loop, and everything else, which is the busy time
// the shares are of. Samples outside any reading (closing a window, the loop itself) are counted and
// printed, never classified.
//
// WHAT A SHARE IS. Each busy sample is given ONE kind by walking its stack from the leaf toward the root
// and taking the first frame that says what the work is (text, an image, a store read, observation, the
// app's own Swift, Debug's main thread checker). Only when none of those is on the stack does it fall to
// the machinery it was in (the lazy stack's layout, other layout, display, AttributeGraph, other SwiftUI,
// AppKit). Generic runtime frames (retain, release, malloc, objc_msgSend, metadata) are transparent, so
// they are charged to whatever called them; how much of the time they are at the leaf is printed apart.
// Beside the exclusive kinds, INCLUSIVE shares say how much of the busy time had a given frame anywhere
// on the stack (a card's body, a date heading, the lazy stack, the hosting view's construction).
//
// DEBUG ONLY, and said on every line: the hosted host crashes under -O (#4299), and the main thread
// checker Debug links in is in the stacks, so it has its own kind rather than being spread over the rest.
// `sample` suspends the process to take each sample, so the CPU printed beside the shares is the reading
// UNDER the sampler and is there to turn a share into milliseconds, not to replace 0c.8's timing.
//
// OPT IN, for L224's reason:
//
//   TEST_RUNNER_MEASURE_4106_VIEW_ATTRIBUTION=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureHostedTests/QueueViewAttributionProbeTests
//
// optionally with `TEST_RUNNER_MEASURE_4106_VIEW_ATTRIBUTION_OUT=<dir>` to keep the raw sample files,
// `_ROUNDS` (default 5) and `_SECONDS` (per round, default 3). What rides along on every push is the
// PARSER and the CLASSIFIER, asserted on a committed synthetic call tree with no sampler and no clock.
//
// PRIVACY. Counts, durations and code symbols only, never a show name, venue, address or key (L222).

// MARK: - The sample file, parsed

enum SampleTree {
    struct Frame: Equatable {
        let symbol: String
        let module: String
    }

    // One leaf of the call tree: `count` samples whose whole stack, root first, is `stack`.
    struct Leaf: Equatable {
        let count: Int
        let stack: [Frame]
    }

    // The main thread's call tree from a `sample` report, as leaves. A node's SELF count (its count minus
    // its children's) is what becomes a leaf, so every sample is counted exactly once (L517). Returns nil
    // when the report has no main thread section, which is an unreadable file, never an idle one (L98).
    static func mainThreadLeaves(_ text: String) -> [Leaf]? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else { return nil }
        lines = lines[(start + 1)...]
        // Two spellings, both measured: "DispatchQueue_1: com.apple.main-thread" when the main thread ran one
        // queue in the window, and "Main Thread   DispatchQueue_<multiple>" when it ran several. Every first
        // draw round of the first full run was the second and was dropped as unreadable.
        guard let thread = lines.firstIndex(where: {
            $0.contains("com.apple.main-thread") || $0.contains(": Main Thread")
        }) else { return nil }
        let threadDepth = depth(of: lines[thread]) ?? 4
        var nodes: [(depth: Int, count: Int, childSum: Int, frame: Frame)] = []
        var leaves: [Leaf] = []

        func pop(downTo d: Int) {
            while let last = nodes.last, last.depth >= d {
                nodes.removeLast()
                let own = last.count - last.childSum
                if own > 0 {
                    leaves.append(Leaf(count: own, stack: nodes.map(\.frame) + [last.frame]))
                }
            }
        }

        for raw in lines[(thread + 1)...] {
            guard let d = depth(of: raw) else {
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { break }
                continue
            }
            if d <= threadDepth { break }          // the next thread's section
            let body = raw.dropFirst(d)
            let digits = body.prefix { $0.isNumber }
            guard let count = Int(digits) else { continue }
            let frame = parseFrame(String(body.dropFirst(digits.count)).trimmingCharacters(in: .whitespaces))
            pop(downTo: d)
            if !nodes.isEmpty { nodes[nodes.count - 1].childSum += count }
            nodes.append((d, count, 0, frame))
        }
        pop(downTo: 0)
        return leaves
    }

    // The column where the count starts: every character before it is tree drawing (`+ ! : |` and spaces).
    private static func depth(of line: Substring) -> Int? {
        var i = 0
        for ch in line {
            if ch.isNumber { return i }
            guard ch == " " || ch == "+" || ch == "!" || ch == ":" || ch == "|" else { return nil }
            i += 1
        }
        return nil
    }

    // "symbol  (in Module) + 12  [0x...]  File.swift:40" into its symbol and module.
    static func parseFrame(_ text: String) -> Frame {
        guard let open = text.range(of: "  (in ") else { return Frame(symbol: text, module: "") }
        let symbol = String(text[..<open.lowerBound])
        let rest = text[open.upperBound...]
        let module = rest.prefix { $0 != ")" }
        return Frame(symbol: symbol, module: String(module))
    }
}

// MARK: - The classifier

enum ViewAttribution {
    enum Scope: Equatable { case outside, rig, idle, busy }

    // Which pass of the reading a sample fell in, from the frame directly beneath the innermost `settle`.
    static let phases = ["the change itself (the swap, or building the window)", "layout pass",
                         "display pass", "run loop (SwiftUI's observers, CA commit)"]

    static func innermostSettle(_ stack: [SampleTree.Frame]) -> Int? {
        stack.lastIndex { $0.symbol.contains("Phase0cView.settle(") }
    }

    static func isIdleLeaf(_ f: SampleTree.Frame) -> Bool {
        f.symbol.hasPrefix("mach_msg") || f.symbol.hasPrefix("__psynch") || f.symbol.hasPrefix("__ulock_wait")
            || f.symbol.hasPrefix("__semwait") || f.symbol.hasPrefix("__workq_kernreturn")
    }

    // The phase, or nil when the sample is the rig's own bookkeeping.
    static func phase(_ stack: [SampleTree.Frame]) -> String? {
        guard let s = innermostSettle(stack) else { return nil }
        guard s + 1 < stack.count else { return nil }            // self time in settle: bookkeeping
        let child = stack[s + 1].symbol
        if child.contains("layoutSubtreeIfNeeded") { return phases[1] }
        if child.contains("displayIfNeeded") { return phases[2] }
        if child.contains("CFRunLoopRunInMode") { return phases[3] }
        if child.contains("collectDirty") || child.contains("renderCount") || child.contains("threadCPU")
            || child.contains("Phase0.now") || child.contains("Phase0cView.finish") { return nil }
        if child.contains("closure") { return phases[0] }
        return nil
    }

    static func scope(_ stack: [SampleTree.Frame]) -> Scope {
        guard innermostSettle(stack) != nil else { return .outside }
        guard phase(stack) != nil else { return .rig }
        if let leaf = stack.last, isIdleLeaf(leaf) { return .idle }
        return .busy
    }

    // Frames that are charged to their caller rather than being a kind of their own.
    static let transparentModules: Set<String> = [
        "libswiftCore.dylib", "libobjc.A.dylib", "libsystem_malloc.dylib", "libsystem_platform.dylib",
        "libsystem_pthread.dylib", "libsystem_c.dylib", "libsystem_blocks.dylib", "libdyld.dylib",
        "libswift_Concurrency.dylib", "libc++.1.dylib", "libc++abi.dylib", "libsystem_kernel.dylib",
        "OvertureHostedTests", "Testing", "libswiftDispatch.dylib", "libdispatch.dylib",
    ]

    static let swiftUIModules: Set<String> = ["SwiftUI", "SwiftUICore"]

    // The kinds, most specific first. The first five are what the WORK is; `app` is the app's own Swift.
    static let debugChecker = "Debug main thread checker"
    static let store = "store reads (SwiftData, Core Data)"
    static let observation = "observation registration and tracking"
    static let text = "text layout and shaping"
    static let image = "image and symbol lookup or decoding"
    static let app = "app's own Swift (view bodies and what they call)"
    static let lazy = "lazy stack layout (LazyVStack machinery)"
    static let layout = "other layout (stacks, sizing, placement)"
    static let display = "display and render (display lists, Core Animation, drawing)"
    static let graph = "SwiftUI graph update (AttributeGraph)"
    static let swiftUI = "SwiftUI other"
    static let appKit = "AppKit, Foundation, CoreFoundation"
    static let runtimeOnly = "Swift and ObjC runtime only"

    static let textSymbols = ["CTLine", "CTTypesetter", "CTRun", "CTFont", "CTFrame", "TextLayout",
                              "StyledText", "ResolvedText", "Text.Resolved", "NSStringDrawing", "NSTextLine",
                              "TextLine", "TypesetterRun", "AttributedString", "FontBox", "Font.Resolved",
                              "TextRenderer", "TextStorage", "NSTypesetter", "GlyphRun", "TextShape"]
    static let imageSymbols = ["NamedImage", "SymbolImage", "CGImage", "CUICatalog", "Image.Resolved",
                               "ImageProvider", "NSImage", "SFSymbol", "VectorImage", "ImageLayer"]
    static let textModules: Set<String> = ["CoreText", "libFontParser.dylib", "UIFoundation", "FontServices"]
    static let imageModules: Set<String> = ["ImageIO", "CoreUI", "SFSymbols", "libPng.dylib", "AppleJPEG",
                                            "CoreSVG"]
    static let displayModules: Set<String> = ["QuartzCore", "RenderBox", "CoreGraphics", "Metal", "IOSurface",
                                              "CoreImage"]

    private static func specific(_ f: SampleTree.Frame) -> String? {
        if f.module == "libMainThreadChecker.dylib" { return debugChecker }
        if f.module == "SwiftData" || f.module == "CoreData" || f.symbol.contains("NSManagedObject") {
            return store
        }
        if f.module == "libswiftObservation.dylib" || f.module == "Observation"
            || f.symbol.contains("ObservationRegistrar") || f.symbol.contains("ObservationTracking") {
            return observation
        }
        if textModules.contains(f.module) || textSymbols.contains(where: { f.symbol.contains($0) }) { return text }
        if imageModules.contains(f.module) || imageSymbols.contains(where: { f.symbol.contains($0) }) { return image }
        if f.module.hasPrefix("Overture") && !f.module.hasPrefix("OvertureHostedTests") { return app }
        return nil
    }

    private static func generic(_ f: SampleTree.Frame) -> String {
        if swiftUIModules.contains(f.module) {
            if f.symbol.contains("Lazy") { return lazy }
            if ["Layout", "sizeThatFits", "placeSubviews", "ViewGeometry", "Spacing", "Placement",
                "ProposedViewSize", "Stack", "ViewDimensions"].contains(where: { f.symbol.contains($0) }) {
                return layout
            }
            if ["DisplayList", "RenderBox", "RB::", "render", "Render", "draw", "Draw"]
                .contains(where: { f.symbol.contains($0) }) { return display }
            return swiftUI
        }
        if displayModules.contains(f.module) || f.module.hasPrefix("AGX") { return display }
        if f.module == "AttributeGraph" { return graph }
        if ["AppKit", "Foundation", "CoreFoundation", "HIToolbox", "SkyLight", "UpdateCycle"].contains(f.module) {
            return appKit
        }
        return "other: " + (f.module.isEmpty ? "unsymbolicated" : f.module)
    }

    // ONE kind per sample, from the frames beneath the innermost settle.
    static func kind(_ stack: [SampleTree.Frame]) -> String {
        let below = innermostSettle(stack).map { Array(stack[($0 + 1)...]) } ?? stack
        let meaningful = below.reversed().filter { !transparentModules.contains($0.module) }
        for f in meaningful { if let k = specific(f) { return k } }
        guard let leaf = meaningful.first else { return runtimeOnly }
        return generic(leaf)
    }

    static func isApp(_ f: SampleTree.Frame) -> Bool {
        f.module.hasPrefix("Overture") && !f.module.hasPrefix("OvertureHostedTests")
    }

    // Only the frames beneath the innermost settle: the probe's own frames above it (WorkTally.measure, which
    // is app code, wraps every reading) would otherwise own every sample. The pilot run printed exactly that.
    static func belowSettle(_ stack: [SampleTree.Frame]) -> ArraySlice<SampleTree.Frame> {
        innermostSettle(stack).map { stack[($0 + 1)...] } ?? stack[...]
    }

    // The innermost frame of the app's own code, shortened to Type.member so a table can group by it.
    static func owner(_ stack: [SampleTree.Frame]) -> String? {
        belowSettle(stack).last(where: isApp).map { shortSymbol($0.symbol) }
    }

    // The OUTERMOST app frame: the view body (or closure) SwiftUI called that the app work happened inside.
    static func entry(_ stack: [SampleTree.Frame]) -> String? {
        belowSettle(stack).first(where: isApp).map { shortSymbol($0.symbol) }
    }

    static func shortSymbol(_ raw: String) -> String {
        var s = raw
        for prefix in ["specialized ", "partial apply for ", "thunk for ", "reabstraction thunk helper from ",
                       "implicit closure #1 in ", "static ", "merged "] {
            while s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        while let r = s.range(of: #"^closure #\d+ (\(.*?\) )?in "#, options: .regularExpression) {
            s.removeSubrange(r)
            for prefix in ["specialized ", "static ", "implicit closure #1 in "] {
                while s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            }
        }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        if let angle = s.firstIndex(of: "<") { s = String(s[..<angle]) }
        return String(s.prefix(90))
    }

    // Inclusive markers: busy samples with a given frame ANYWHERE beneath the settle.
    static let markers: [(name: String, test: @Sendable (SampleTree.Frame) -> Bool)] = [
        ("inside a card's body (ProspectRowView, DraftReviewView)",
         { $0.symbol.contains("ProspectRowView") || $0.symbol.contains("DraftReviewView") }),
        ("inside a row's wrapper (prospectRow, QueueSendAwareRow, ProspectRowFactory)",
         { $0.symbol.contains("prospectRow") || $0.symbol.contains("QueueSendAwareRow")
             || $0.symbol.contains("ProspectRowFactory") }),
        ("inside a date heading (dateSection, ReachabilityProbeControl, ProbeDateCheckbox)",
         { $0.symbol.contains("dateSection") || $0.symbol.contains("ReachabilityProbeControl")
             || $0.symbol.contains("ProbeDateCheckbox") }),
        ("inside QueueView's own body, masthead and scroll closures",
         { $0.symbol.contains("QueueView.body") || $0.symbol.contains("QueueView.masthead")
             || $0.symbol.contains("QueueView.queueScroll") || $0.symbol.contains("QueueView.focusedSection") }),
        ("inside QueueDateGroups (the lazy stack's owner)", { $0.symbol.contains("QueueDateGroups") }),
        ("under the lazy stack (any SwiftUI Lazy frame)",
         { swiftUIModules.contains($0.module) && $0.symbol.contains("Lazy") }),
        ("under NSHostingView construction", { $0.symbol.contains("NSHostingView.init")
             || $0.symbol.contains("NSHostingView(rootView") }),
        ("text anywhere on the stack", { specific($0) == text }),
        ("store read anywhere on the stack", { specific($0) == store }),
        // Named after the pilot and the first full run showed where the app's own Swift went: a geography
        // verdict per row, mostly reached from the masthead's missed-by-a-check offer over every queue row.
        ("inside QueueModel.keysMissedByACheck (the masthead's missed-by-a-check offer)",
         { $0.symbol.contains("keysMissedByACheck") }),
        ("inside QueueModel.probeIsWorthOffering, from any caller", { $0.symbol.contains("probeIsWorthOffering") }),
        ("a geography verdict anywhere (GeoRefusals.resolveVerdict, EventPlace)",
         { $0.symbol.contains("GeoRefusals.resolveVerdict") || $0.symbol.contains("EventPlace.") }),
        ("observation anywhere on the stack", { specific($0) == observation }),
        ("image anywhere on the stack", { specific($0) == image }),
    ]

    struct Round {
        var outside = 0, rig = 0, idle = 0, busy = 0
        var kinds: [String: Int] = [:]
        var owners: [String: Int] = [:]
        var entries: [String: Int] = [:]
        var marks: [String: Int] = [:]
        var phases: [String: Int] = [:]
        var leaves: [String: Int] = [:]
        var runtimeLeaf = 0
        func share(_ n: Int) -> Double { busy == 0 ? .nan : 100 * Double(n) / Double(busy) }
    }

    static func summarise(_ leaves: [SampleTree.Leaf]) -> Round {
        var r = Round()
        for leaf in leaves {
            switch scope(leaf.stack) {
            case .outside: r.outside += leaf.count; continue
            case .rig: r.rig += leaf.count; continue
            case .idle: r.idle += leaf.count; continue
            case .busy: r.busy += leaf.count
            }
            r.kinds[kind(leaf.stack), default: 0] += leaf.count
            if let o = owner(leaf.stack) { r.owners[o, default: 0] += leaf.count }
            if let e = entry(leaf.stack) { r.entries[e, default: 0] += leaf.count }
            if let p = phase(leaf.stack) { r.phases[p, default: 0] += leaf.count }
            let below = innermostSettle(leaf.stack).map { Array(leaf.stack[($0 + 1)...]) } ?? leaf.stack
            for m in markers where below.contains(where: m.test) { r.marks[m.name, default: 0] += leaf.count }
            if let last = leaf.stack.last {
                r.leaves[shortSymbol(last.symbol) + " (" + last.module + ")", default: 0] += leaf.count
                if transparentModules.contains(last.module) { r.runtimeLeaf += leaf.count }
            }
        }
        return r
    }
}

// MARK: - The probe

enum ViewAttributionProbe {
    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated static var enabled: Bool { env["MEASURE_4106_VIEW_ATTRIBUTION"] != nil }
    nonisolated static var rounds: Int { Int(env["MEASURE_4106_VIEW_ATTRIBUTION_ROUNDS"] ?? "") ?? 5 }
    nonisolated static var seconds: Int { Int(env["MEASURE_4106_VIEW_ATTRIBUTION_SECONDS"] ?? "") ?? 3 }
    nonisolated static var outDir: URL? {
        env["MEASURE_4106_VIEW_ATTRIBUTION_OUT"].map { URL(fileURLWithPath: $0) }
    }
    static func say(_ line: String) { print("va " + line) }
    static func f(_ v: Double) -> String { v.isNaN ? "n/a" : String(format: "%.1f", v) }
    static func median(_ v: [Double]) -> Double { // probe-reading-exempt: shares and per round figures; the timings this reports print their lines through Phase0.reading beside them
        let s = v.filter { !$0.isNaN }.sorted()
        return s.isEmpty ? .nan : s[s.count / 2] // probe-reading-exempt: shares and per round figures; the timings this reports print their lines through Phase0.reading beside them
    }
    static func spread(_ v: [Double]) -> String {
        let s = v.filter { !$0.isNaN }
        guard let lo = s.min(), let hi = s.max() else { return "n/a" }
        return "\(f(lo)) to \(f(hi))"
    }
}

@MainActor
@Suite("#4106 view workstream: where the queue's draw time goes (opt in)")
struct QueueViewAttributionProbeTests {
    private let sandboxes = TemporarySandboxes()

    // MARK: - On every push: the parser and the classifier, over a committed synthetic call tree

    // A call tree shaped like `sample`'s own, invented, with every scope and several kinds in it. The
    // counts are chosen so each total below is a distinct number, and a leaf double counted or dropped
    // moves one of them (L517).
    static let syntheticReport = """
    Analysis of sampling Overture (pid 1) every 1 millisecond
    Call graph:
        100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        + 100 static QueueRenderPass.WorkTally.measure(_:)  (in Overture.debug.dylib) + 1  [0x1]
        +   97 static Phase0cView.settle(_:bodyMustRun:seconds:change:)  (in OvertureHostedTests) + 1  [0x2]
        +   ! 97 static Phase0cView.settle(bodyMustRun:seconds:making:)  (in OvertureHostedTests) + 1  [0x3]
        +   !   40 -[NSView layoutSubtreeIfNeeded]  (in AppKit) + 1  [0x4]
        +   !   : 25 ProspectRowView.body.getter  (in Overture.debug.dylib) + 1  [0x5]
        +   !   : | 15 ProspectRowView.header.getter  (in Overture.debug.dylib) + 1  [0x6]
        +   !   : | + 15 swift_retain  (in libswiftCore.dylib) + 1  [0x7]
        +   !   : | 6 swift_getGenericMetadata  (in libswiftCore.dylib) + 1  [0x8]
        +   !   : 11 LazyStackLayout.placeSubviews  (in SwiftUICore) + 1  [0x9]
        +   !   : + 11 CTLineCreateWithAttributedString  (in CoreText) + 1  [0xa]
        +   !   : 4 AG::Graph::update_attribute  (in AttributeGraph) + 1  [0xb]
        +   !   30 CFRunLoopRunInMode  (in CoreFoundation) + 1  [0xc]
        +   !   | 20 mach_msg2_trap  (in libsystem_kernel.dylib) + 1  [0xd]
        +   !   | 8 SwiftData.PersistentModel.getValue  (in SwiftData) + 1  [0xe]
        +   !   | 2 AG::Graph::update_attribute  (in AttributeGraph) + 1  [0xb]
        +   !   |   2 swift_release  (in libswiftCore.dylib) + 1  [0x13]
        +   !   9 static Phase0cView.collectDirty(_:into:)  (in OvertureHostedTests) + 1  [0xf]
        +   !   18 -[NSView displayIfNeeded]  (in AppKit) + 1  [0x10]
        +   !     18 RB::DisplayList::draw  (in RenderBox) + 1  [0x11]
        +   3 -[NSWindow close]  (in AppKit) + 1  [0x12]

        7 Thread_2   DispatchQueue_2: com.apple.other  (serial)
        + 7 mach_msg2_trap  (in libsystem_kernel.dylib) + 1  [0xd]
    """

    @Test func theParserCountsEveryMainThreadSampleOnce() throws {
        let leaves = try #require(SampleTree.mainThreadLeaves(Self.syntheticReport))
        #expect(leaves.reduce(0) { $0 + $1.count } == 100, "main thread leaves must sum to its 100 samples")
        #expect(SampleTree.mainThreadLeaves("no call graph here") == nil)
        let multiple = Self.syntheticReport.replacingOccurrences(
            of: "Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)",
            with: "Thread_1: Main Thread   DispatchQueue_<multiple>")
        #expect(SampleTree.mainThreadLeaves(multiple)?.reduce(0) { $0 + $1.count } == 100,
                "the main thread's other spelling, when it ran several queues, must parse too")
        let frame = SampleTree.parseFrame("ProspectRowView.body.getter  (in Overture.debug.dylib) + 1  [0x5]  F.swift:3")
        #expect(frame == SampleTree.Frame(symbol: "ProspectRowView.body.getter", module: "Overture.debug.dylib"))
    }

    @Test func theClassifierSeparatesScopePhaseAndKind() throws {
        let leaves = try #require(SampleTree.mainThreadLeaves(Self.syntheticReport))
        let r = ViewAttribution.summarise(leaves)
        // outside: the window close (3). rig: collectDirty (9). idle: mach_msg (20). busy: the rest.
        #expect(r.outside == 3)
        #expect(r.rig == 9)
        #expect(r.idle == 20)
        #expect(r.busy == 68)
        // The retain and the metadata call under the card body are charged to the app's own code (15+6+4
        // self time in the body getter), the CoreText leaf under the lazy stack to text, and so on.
        #expect(r.kinds[ViewAttribution.app] == 25)
        #expect(r.kinds[ViewAttribution.text] == 11)
        #expect(r.kinds[ViewAttribution.store] == 8)
        #expect(r.kinds[ViewAttribution.graph] == 6)
        #expect(r.kinds[ViewAttribution.display] == 18)
        #expect(r.phases[ViewAttribution.phases[1]] == 40)
        #expect(r.phases[ViewAttribution.phases[2]] == 18)
        #expect(r.phases[ViewAttribution.phases[3]] == 10)
        #expect(r.owners["ProspectRowView.header.getter"] == 15)
        #expect(r.entries["ProspectRowView.body.getter"] == 25)
        // The app frame ABOVE the settle (the tally every reading runs under) owns nothing.
        #expect(r.owners.values.reduce(0, +) == 25)
        #expect(r.owners["QueueRenderPass.WorkTally.measure"] == nil)
        #expect(r.marks["inside a card's body (ProspectRowView, DraftReviewView)"] == 25)
        #expect(r.marks["under the lazy stack (any SwiftUI Lazy frame)"] == 11)
        // Two of them sit under nothing but AttributeGraph, so only transparency charges them to the graph
        // (the six graph samples above include them); without it they would read as "other: libswiftCore".
        #expect(r.kinds.keys.allSatisfy { !$0.hasPrefix("other") })
        #expect(r.runtimeLeaf == 23)
    }

    @Test func aShortSymbolIsTypeAndMember() {
        #expect(ViewAttribution.shortSymbol("closure #1 in closure #2 in QueueView.dateSection(_:data:departing:departingCards:)")
                == "QueueView.dateSection")
        #expect(ViewAttribution.shortSymbol("specialized ProspectRowView.body.getter") == "ProspectRowView.body.getter")
    }

    // MARK: - The probe, opt in

    private struct Counts {
        var bodies = 0              // QueueView body evaluations
        var cardBodies = 0          // card body evaluations, summed
        var cardsEvaluated = 0      // distinct cards whose body ran
        var realised = 0            // rows that asked the card store for a card
        var groupsRealised = 0      // distinct date groups those rows sit in
        var rowsInRealisedGroups = 0
        var cardsBuiltInBody = 0    // WorkTally.queueItems during the reading
        var recipientReaches = 0    // WorkTally.recipientReaches during the reading
        var stageRows = 0
        var dateGroups = 0          // the outer ForEach's identities
        var queueRows = 0           // every row of the queue, which the masthead folds over
        var missedRows = 0          // rows a check missed: the cheap half of keysMissedByACheck's test
        // #4311: what a stage list's own derivation did during the reading (WorkTally), which is zero
        // once the pass takes it, and the Reached out list's rows for scale.
        var stageListRows = 0
        var calendarTables = 0
        var reachedOutRows = 0
    }

    private struct Reading {
        let settled: Phase0cView.Settled
        let counts: Counts
    }

    private final class Rig {
        let registry: QueueModel.CardKeyRegistry
        init(registry: QueueModel.CardKeyRegistry) { self.registry = registry }

        // One reading, counted. `data` is the pass on screen at the END of the reading, which is the one
        // the realised rows belong to.
        @MainActor
        func read(data: QueueView.RenderData, _ settle: () -> Phase0cView.Settled) -> Reading {
            _ = registry.takeKeys()
            let cards0 = QueueRenderCounter.cardBodyCounts()
            var s: Phase0cView.Settled?
            let tally = QueueRenderPass.WorkTally.measure { s = settle() }
            let cards1 = QueueRenderCounter.cardBodyCounts()
            let keys = registry.takeKeys()
            var c = Counts()
            c.bodies = s!.bodies
            for (k, n) in cards1 {
                let d = n - (cards0[k] ?? 0)
                if d > 0 { c.cardBodies += d; c.cardsEvaluated += 1 }
            }
            c.realised = keys.count
            var groupOf: [String: Int] = [:]
            for (i, g) in data.dateGroups.enumerated() { for row in g.items { groupOf[row.id] = i } }
            let groups = Set(keys.compactMap { groupOf[$0] })
            c.groupsRealised = groups.count
            c.rowsInRealisedGroups = groups.reduce(0) { $0 + data.dateGroups[$1].items.count }
            c.cardsBuiltInBody = tally.queueItems
            c.stageListRows = tally.stageListRows
            c.calendarTables = tally.sourceCalendarIndexBuilds
            c.reachedOutRows = data.reachedOut.count
            c.recipientReaches = tally.recipientReaches
            c.stageRows = data.focusedRows.count
            c.dateGroups = data.dateGroups.count
            c.queueRows = data.rows.count
            let now = Date()
            c.missedRows = data.rows.filter {
                Reachability.wasMissedByACheck(probedAt: $0.reachabilityProbedAt,
                                               unansweredAt: $0.reachabilityUnansweredAt, now: now)
            }.count
            return Reading(settled: s!, counts: c)
        }
    }

    private struct KindResult {
        let name: String
        var rounds: [ViewAttribution.Round] = []
        var roundCPU: [Double] = []       // median reading cpu under the sampler, per round
        var readings: [Reading] = []
        var failures: [String] = []
    }

    // Rounds of back to back readings, each round under its own sampler window.
    private func sampled(_ name: String, label: String, dir: URL,
                         reading: (Int) -> Reading) async -> KindResult {
        var out = KindResult(name: name)
        let seconds = ViewAttributionProbe.seconds
        for round in 0..<ViewAttributionProbe.rounds {
            let slug = "\(label)-\(name)".lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let file = dir.appendingPathComponent("\(slug)-r\(round).sample.txt")
            let sampler = LandingSelfSampler(seconds: seconds, file: file)
            do { try await sampler.start() } catch {
                out.failures.append("round \(round): sampler never began sampling (\(String(describing: error).suffix(160)))")
                continue
            }
            let t0 = Phase0.now()
            var mine: [Reading] = []
            var i = 0
            // `start` returned once sampling really began (#4307), so the first reading is sampled. Readings
            // then run until the sampler says its window is OVER, never for its nominal duration: the pilot
            // run timed that from the attach line, and every sample in every file was the main thread idle
            // after the readings had finished (the attach line can precede the first sample by seconds). A
            // bound of the window plus 60 s, so a sampler that never reports cannot hang this.
            while !sampler.samplingFinished && Phase0.ms(since: t0) < Double(seconds + 60) * 1000 {
                mine.append(reading(i)); i += 1
            }
            let ok = await sampler.finish()
            out.readings += mine
            // The file is judged on its own: the pilot's first round reported a failed exit and still wrote a
            // complete report, so a failed exit is printed, and only an unreadable file loses the round.
            if !ok {
                out.failures.append("round \(round): sampler reported failure (\(sampler.output.suffix(160)))")
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let leaves = SampleTree.mainThreadLeaves(text) else {
                out.failures.append("round \(round): SAMPLER FILE unreadable, round dropped")
                continue
            }
            // Appended together, so a share and the cpu it is turned into milliseconds by are one round's.
            out.rounds.append(ViewAttribution.summarise(leaves))
            out.roundCPU.append(ViewAttributionProbe.median(mine.filter(\.settled.completed).map(\.settled.cpuMs)))
        }
        return out
    }

    private func report(_ k: KindResult, label: String) {
        let P = ViewAttributionProbe.self
        let settled = k.readings.filter(\.settled.completed)
        let c = k.readings.map(\.counts)
        // #4617: the median of round medians as the line the before and after comparison reads.
        _ = Phase0.reading("va-\(label)-\(k.name)-roundCPU", runs: k.roundCPU.filter { !$0.isNaN })
        P.say("\(label) \(k.name): Debug build | rounds \(k.rounds.count) of \(ViewAttributionProbe.rounds), "
              + "readings \(k.readings.count) (\(k.readings.count - settled.count) never settled) | cpu per reading "
              + "UNDER the sampler, median of round medians \(P.f(P.median(k.roundCPU))) ms, rounds "
              + "\(P.spread(k.roundCPU)) | \(Phase0.load())"
              + (k.failures.isEmpty ? "" : " | FAILURES: " + k.failures.joined(separator: "; ")))
        P.say("\(label) \(k.name) counts per reading (median, max): queue bodies \(Phase0.medianCount(c.map(\.bodies))), "
              + "card bodies \(Phase0.medianCount(c.map(\.cardBodies))) (\(c.map(\.cardBodies).max() ?? 0)) over "
              + "\(Phase0.medianCount(c.map(\.cardsEvaluated))) distinct cards, rows realised "
              + "\(Phase0.medianCount(c.map(\.realised))) (\(c.map(\.realised).max() ?? 0)), date groups realised "
              + "\(Phase0.medianCount(c.map(\.groupsRealised))) holding \(Phase0.medianCount(c.map(\.rowsInRealisedGroups))) rows, "
              + "cards built in the body \(Phase0.medianCount(c.map(\.cardsBuiltInBody))), contacts reached "
              + "\(Phase0.medianCount(c.map(\.recipientReaches))), stage rows \(Phase0.medianCount(c.map(\.stageRows))) "
              + "(\(c.map(\.stageRows).max() ?? 0)), outer ForEach identities (date groups) "
              + "\(Phase0.medianCount(c.map(\.dateGroups))) (\(c.map(\.dateGroups).max() ?? 0)), queue rows the masthead "
              + "folds over \(Phase0.medianCount(c.map(\.queueRows))), of which a check missed "
              + "\(Phase0.medianCount(c.map(\.missedRows))), stage list rows derived in the body "
              + "\(Phase0.medianCount(c.map(\.stageListRows))), calendar tables built in the body "
              + "\(Phase0.medianCount(c.map(\.calendarTables))), Reached out rows \(Phase0.medianCount(c.map(\.reachedOutRows)))")
        guard !k.rounds.isEmpty else { return }
        let busy = k.rounds.map { Double($0.busy) }
        P.say("\(label) \(k.name) samples per round (median): busy \(P.f(P.median(busy))), idle "
              + "\(P.f(P.median(k.rounds.map { Double($0.idle) }))), rig \(P.f(P.median(k.rounds.map { Double($0.rig) }))), "
              + "outside readings \(P.f(P.median(k.rounds.map { Double($0.outside) }))); runtime frame at the leaf "
              + "\(P.f(P.median(k.rounds.map { $0.share($0.runtimeLeaf) })))% of busy")
        // ms per reading = share of busy time x the round's median reading cpu.
        func table(_ title: String, _ pick: (ViewAttribution.Round) -> [String: Int], top: Int) {
            var names = Set<String>()
            for r in k.rounds { names.formUnion(pick(r).keys) }
            let rows = names.map { n -> (String, Double, String, Double) in
                let shares = k.rounds.map { $0.share(pick($0)[n] ?? 0) }
                let ms = zip(k.rounds, k.roundCPU).map { r, cpu in r.share(pick(r)[n] ?? 0) / 100 * cpu }
                return (n, P.median(shares), P.spread(shares), P.median(ms))
            }.sorted { $0.1 > $1.1 }
            P.say("\(label) \(k.name) \(title):")
            for (n, share, spread, ms) in rows.prefix(top) {
                P.say("  \(P.f(share))% (rounds \(spread)) ~\(P.f(ms)) ms/reading  \(n)")
            }
        }
        table("KIND (exclusive, sums to 100)", { $0.kinds }, top: 20)
        table("PHASE", { $0.phases }, top: 4)
        table("INCLUSIVE (frame anywhere on the stack)", { $0.marks }, top: 20)
        table("ENTRY (outermost app frame: the body or closure SwiftUI called)", { $0.entries }, top: 15)
        table("OWNER (innermost app frame)", { $0.owners }, top: 15)
        table("LEAF (top of stack)", { $0.leaves }, top: 12)
    }

    private func dir(_ label: String) throws -> URL {
        if let out = ViewAttributionProbe.outDir {
            let d = out.appendingPathComponent(label.replacingOccurrences(of: " ", with: "-"))
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        return try sandboxes.make(named: "view-attribution-\(label.replacingOccurrences(of: " ", with: "-"))")
    }

    private func run(label: String, factor: Int) async throws {
        guard ViewAttributionProbe.enabled else {
            print("va: not measured. Set TEST_RUNNER_MEASURE_4106_VIEW_ATTRIBUTION=1 to run it.")
            return
        }
        let (size, source) = Phase0cView.dansWindow()
        ViewAttributionProbe.say("\(label) window: \(source)")
        let work = try sandboxes.make(named: "view-attribution-store")
        guard let base = try LiveStoreClone.makeClone(in: work) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let url = factor == 1 ? base : try Phase0.scaledCopy(of: base, factor: factor, in: work)
        let export = try Phase0cViewRig.scratchExport(sandboxes)
        let container = try Phase0.openContainer(at: url)
        container.mainContext.autosaveEnabled = false
        let t = try Phase0cViewRig.tables(container.mainContext, export: export)
        let now = Date()
        ViewAttributionProbe.say("\(label) corpus: \(Phase0.shape(t.rows)) | \(Phase0.load())")
        let registry = QueueModel.CardKeyRegistry()
        let rig = Rig(registry: registry)
        let a = Phase0cViewRig.servedPass(t, now: now, stage: .scout, registry: registry)
        let out = try dir(label)

        // Warm the host once, untimed and unsampled, exactly as 0c.8 does.
        let warm = Phase0cViewRig.host(container, feed: Phase0cServedFeed(a), size: size)
        _ = Phase0cView.settle(warm, bodyMustRun: true) {}
        HostedPassCounting.unmountAndClose(warm)
        _ = registry.takeKeys()

        // MARK: the window height sweep, unsampled: the only reading that moves realised rows alone.
        for height in [size.height / 2, size.height, size.height * 2] {
            let h = NSSize(width: size.width, height: height)
            var rs: [Reading] = []
            for _ in 0..<5 {
                var w: NSWindow?
                rs.append(rig.read(data: a) {
                    Phase0cView.settle(bodyMustRun: true) {
                        let made = Phase0cViewRig.host(container, feed: Phase0cServedFeed(a), size: h)
                        w = made
                        return made
                    }
                })
                HostedPassCounting.unmountAndClose(w)
            }
            let cpu = rs.filter(\.settled.completed).map(\.settled.cpuMs)
            let realised = Phase0.medianCount(rs.map(\.counts.realised))
            let med = ViewAttributionProbe.median(cpu)
            _ = Phase0.reading("va-\(label)-heightSweep-\(Int(h.width))x\(Int(h.height))", runs: cpu) // #4617
            ViewAttributionProbe.say("\(label) height sweep \(Int(h.width))x\(Int(h.height)): first draw cpu median "
                + "\(ViewAttributionProbe.f(med)) ms (\(ViewAttributionProbe.spread(cpu))), rows realised \(realised), "
                + "card bodies \(Phase0.medianCount(rs.map(\.counts.cardBodies))), date groups realised "
                + "\(Phase0.medianCount(rs.map(\.counts.groupsRealised))), stage rows "
                + "\(a.focusedRows.count), ms per realised row "
                + "\(ViewAttributionProbe.f(realised == 0 ? .nan : med / Double(realised))) | \(Phase0.load())")
        }

        // MARK: first draw, cards prebuilt: a fresh window per reading, the hosting view built inside it.
        let first = await sampled("first draw", label: label, dir: out) { _ in
            var w: NSWindow?
            let r = rig.read(data: a) {
                Phase0cView.settle(bodyMustRun: true) {
                    let made = Phase0cViewRig.host(container, feed: Phase0cServedFeed(a), size: size)
                    w = made
                    return made
                }
            }
            HostedPassCounting.unmountAndClose(w)
            return r
        }

        // One window for the per-change kinds, drawn and settled before anything is sampled.
        let feed = Phase0cServedFeed(a)
        let window = Phase0cViewRig.host(container, feed: feed, size: size)
        defer { HostedPassCounting.unmountAndClose(window) }
        _ = Phase0cView.settle(window, bodyMustRun: true) {}
        let drawnOnA = registry.takeKeys()

        // MARK: one row dismissed and its undo, over every row the viewport draws. Passes built first.
        let byKey = Dictionary(t.rows.map { ($0.naturalKey, $0) }, uniquingKeysWith: { x, _ in x })
        var dismissed: [QueueView.RenderData] = []
        for key in a.focusedRows.map(\.id) where drawnOnA.contains(key) {
            guard let show = byKey[key] else { continue }
            let was = show.status
            show.status = .dismissed
            dismissed.append(Phase0cViewRig.servedPass(t, now: now, stage: .scout, registry: registry))
            show.status = was
        }
        _ = registry.takeKeys()
        var dismissKind = KindResult(name: "one row dismissed and its undo")
        if dismissed.isEmpty {
            dismissKind.failures.append("UNMEASURED: the first draw realised no rows to dismiss")
        } else {
            dismissKind = await sampled("one row dismissed and its undo", label: label, dir: out) { i in
                let next = i % 2 == 0 ? dismissed[(i / 2) % dismissed.count] : a
                return rig.read(data: next) { Phase0cView.settle(window, bodyMustRun: true) { feed.data = next } }
            }
        }

        // MARK: a stage focus change, to every stage the queue list draws, and back. Passes built first.
        var stages: [QueueView.RenderData] = []
        var stageNames: [String] = []
        for stage in StageFocus.allCases where stage != .scout && stage != .followUps && stage != .reachedOut {
            let s = Phase0cViewRig.servedPass(t, now: now, stage: stage, registry: registry)
            stages.append(s)
            stageNames.append("\(stage.rawValue) \(s.focusedRows.count)")
        }
        _ = registry.takeKeys()
        var stageKind = KindResult(name: "stage focus change and back")
        if stages.isEmpty {
            stageKind.failures.append("UNMEASURED: no stage other than Scout to change to")
        } else {
            stageKind = await sampled("stage focus change and back", label: label, dir: out) { i in
                let next = i % 2 == 0 ? stages[(i / 2) % stages.count] : a
                return rig.read(data: next) { Phase0cView.settle(window, bodyMustRun: true) { feed.data = next } }
            }
        }
        ViewAttributionProbe.say("\(label) stages served (rows): \(stageNames.joined(separator: ", "))")

        // MARK: #4311, the Reached out stage: one of its shows closed and back, drawn ON that stage.
        //
        // The stage change above skips Reached out because it is its own branch of the view, taken only
        // when the view's own stage says so, and a served pass cannot move that. A deep link can, the same
        // way an OmniFocus link does, so this window is put on the stage by one before anything is sampled.
        // The change is a dismissal of one Reached out show, so the list really changes under the body.
        let reachedA = Phase0cViewRig.servedPass(t, now: now, stage: .reachedOut, registry: registry)
        var reachedKind = KindResult(name: "Reached out: one show closed and back")
        // #4357 step 5: the pass publishes the show's identity, so the model is found among the fixture's rows.
        if let first = reachedA.reachedOut.first?.show.showID,
           let closing = t.rows.first(where: { $0.persistentModelID == first }) {
            let was = closing.status
            closing.status = .dismissed
            let reachedB = Phase0cViewRig.servedPass(t, now: now, stage: .reachedOut, registry: registry)
            closing.status = was
            let link = Phase0cViewRig.DeepLinkChannel()
            let reachedFeed = Phase0cServedFeed(reachedA)
            let reachedWindow = Phase0cViewRig.host(container, feed: reachedFeed, size: size,
                                                    link: link)
            defer { HostedPassCounting.unmountAndClose(reachedWindow) }
            _ = Phase0cView.settle(reachedWindow, bodyMustRun: true) {}
            let listed = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList)
            _ = Phase0cView.settle(reachedWindow, bodyMustRun: true) {
                link.key = LeadDeepLink(key: closing.naturalKey)
            }
            _ = registry.takeKeys()
            if QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList) == listed {
                reachedKind.failures.append("UNMEASURED: the deep link did not bring the window onto Reached out")
            } else {
                reachedKind = await sampled("Reached out: one show closed and back", label: label, dir: out) { i in
                    let next = i % 2 == 0 ? reachedB : reachedA
                    return rig.read(data: next) {
                        Phase0cView.settle(reachedWindow, bodyMustRun: true) { reachedFeed.data = next }
                    }
                }
            }
        } else {
            reachedKind.failures.append("UNMEASURED: the corpus has no show on Reached out")
        }
        ViewAttributionProbe.say("\(label) Reached out served rows: \(reachedA.reachedOut.count)")

        for k in [first, dismissKind, stageKind, reachedKind] { report(k, label: label) }
        ViewAttributionProbe.say("\(label) raw samples in \(out.path)")
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func attributionOnTheLiveClone() async throws { try await run(label: "live clone", factor: 1) }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func attributionOnThe4xCorpus() async throws { try await run(label: "4x", factor: 4) }
}
