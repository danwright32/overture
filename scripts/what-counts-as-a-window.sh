#!/usr/bin/env bash
set -uo pipefail

# #3788: what AppKit puts in an app's window list, measured rather than assumed.
#
# WHY THIS EXISTS. `WindowCensus` decides whether anybody could have been looking at Overture by asking
# which of `NSApplication.shared.windows` is a window a person can read, and a stall record carries the
# answer. That question was answered wrongly for the whole life of the field it feeds, because
# `MenuBarExtra` is backed by an `NSStatusItem` whose window is IN that list and reports itself visible, so
# a resident app could never report no window open. Every record written by the first build carrying the
# field said `windows: open` while System Events reported zero.
#
# The predicate that fixes it turns on three facts about real AppKit: a status item is visible, cannot
# become main and is not titled, while a window Dan reads is all three. Those facts are not something the
# Swift suite can assert. A hosted test cannot make a window visible (ordering one front crashes the shared
# app host, #3480) and must not create a real status item (one that macOS removes takes the whole process
# down with it, which once blocked every Swift test, see OvertureApp.swift). So the premise lives here, as
# a command that RE-TAKES it, rather than as a dated sentence in a comment that rots silently (L316, L52).
#
# OPT IN. It compiles and runs a tiny AppKit process, so it is not on the push path. It needs a logged in
# GUI session; run it from a terminal on the Mac rather than from a build machine.
#
#   0  measured: the menu bar item is not a content window, and an ordinary window is
#   1  measured: it is NOT, so WindowCensus is filtering on something that is no longer true
#   2  UNMEASURED: could not build or run the probe, which is not a verdict either way

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scratch.sh
. "${SCRIPT_DIR}/lib/scratch.sh"

WORK="$(overture_scratch_dir what-counts-as-a-window)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/probe.swift" <<'SWIFT'
import AppKit

// Prints, for each window in the list, exactly the three properties WindowCensus.isContentWindow reads.
// Nothing is judged here: this reports what AppKit did, and the reader below decides what it means.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func dump(_ tag: String) {
    print("\(tag) count=\(app.windows.count)")
    for w in app.windows {
        print("  \(tag) window visible=\(w.isVisible) canBecomeMain=\(w.canBecomeMain) "
              + "titled=\(w.styleMask.contains(.titled))")
    }
}

dump("before")

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "probe"
dump("menubar")

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.makeKeyAndOrderFront(nil)
dump("content")
SWIFT

if ! xcrun swiftc -o "${WORK}/probe" "${WORK}/probe.swift" > "${WORK}/build.log" 2>&1; then
  echo "what-counts-as-a-window: UNMEASURED. The probe did not build."
  sed 's/^/  /' "${WORK}/build.log"
  exit 2
fi

# Into a FILE rather than a variable interpolated into the reader below. A reading is the probe's own
# bytes, and splicing them through a shell expansion into a Python string literal makes a quote or a
# backslash in them rewrite the reader rather than be read by it.
if ! "${WORK}/probe" > "${WORK}/reading.txt" 2>&1; then
  echo "what-counts-as-a-window: UNMEASURED. The probe did not run."
  sed 's/^/  /' "${WORK}/reading.txt"
  exit 2
fi

sed 's/^/  /' "${WORK}/reading.txt"

python3 - "${WORK}/reading.txt" <<'PY'
import re, sys

out = open(sys.argv[1]).read()


def windows(tag):
    found = re.findall(
        tag + r" window visible=(\w+) canBecomeMain=(\w+) titled=(\w+)", out)
    return [tuple(v == "true" for v in row) for row in found]


def counted(rows):
    # The predicate under test, spelled once: visible AND can become main AND titled.
    return [r for r in rows if r[0] and r[1] and r[2]]


if "before count=" not in out or "content count=" not in out:
    print()
    print("what-counts-as-a-window: UNMEASURED. The probe printed nothing this reader understands.")
    sys.exit(2)

before, menubar, content = windows("before"), windows("menubar"), windows("content")

print()
if len(menubar) - len(before) != 1:
    print("what-counts-as-a-window: UNMEASURED. A status item did not add exactly one window,")
    print("  so this reading cannot say anything about which window is which.")
    sys.exit(2)

added_by_status_item = [w for w in menubar if w not in before] or menubar
status_item_counts = bool(counted(added_by_status_item))
content_counts = len(counted(content)) == 1

if not status_item_counts and content_counts:
    print("what-counts-as-a-window: the menu bar item is NOT a content window, and an ordinary")
    print("  window IS. WindowCensus.isContentWindow is filtering on something still true.")
    sys.exit(0)

print("what-counts-as-a-window: AppKit no longer behaves the way WindowCensus filters (#3788).")
if status_item_counts:
    print("  The menu bar item now satisfies the predicate, so a resident app can never report")
    print("  no window open, which is the exact defect this was written to end.")
if not content_counts:
    print("  An ordinary titled window does NOT satisfy it, so the census would report no window")
    print("  open while Dan is looking at one, which is worse than the defect it replaced.")
sys.exit(1)
PY
