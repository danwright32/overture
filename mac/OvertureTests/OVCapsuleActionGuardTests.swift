import Testing

// #1460: the secondary-action capsule ("you can do this") existed at two sizes. OVCapsuleButton drew 11pt
// regular at 12x4; the queue's Dismiss menu drew 11pt SEMIBOLD at 16x6, so it was bolder and chunkier,
// while a comment claimed the two matched. They match only if both wear ONE shared modifier, so this guards
// that neither hand-draws the capsule chrome any more and both go through ovCapsuleAction().
@Suite("The secondary-action capsule is one shared modifier (#1460)")
struct OVCapsuleActionGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    // Dismiss is a Menu, not a Button, so it can't adopt OVCapsuleButton itself; it wears the modifier. The
    // guard is that it no longer spells the chrome out (the drifted semibold/md-6 form is gone) and instead
    // calls the shared modifier.
    @Test func theDismissMenuWearsTheSharedCapsuleModifier() {
        let row = source("Overture/UI/ProspectRowView.swift")
        #expect(row.contains("Text(\"Dismiss\").foregroundStyle(OVColor.inkSoft)"))
        #expect(row.contains(".ovCapsuleAction()"))
        // The hand-drawn border it used to carry must be gone from the row, or the two could drift again.
        #expect(!row.contains("Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1)"))
    }

    // OVCapsuleButton is the other wearer: its own chrome now comes from the modifier, not spelled inline,
    // so a change to the shared metrics reaches every caller at once. The chrome is defined ONCE (in the
    // modifier), so each of its pieces appears exactly once in the file, never also duplicated in the struct
    // body.
    @Test func ovCapsuleButtonDrawsThroughTheSharedModifier() {
        let button = source("Overture/UI/OVCapsuleButton.swift")
        #expect(button.contains(".ovCapsuleAction()"))
        #expect(occurrences(of: ".padding(.vertical, 4)", in: button) == 1)
        #expect(occurrences(of: "Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1)", in: button) == 1)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
