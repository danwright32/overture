import SwiftUI

// #337 / #901: a toolbar button. Icon by default, with its name shown as a hover TOOLTIP (the button's own
// `.help(...)`), not printed beside the icon.
//
// This went through three shapes as Dan walked the app 2026-07-14. It began (#337) as a hover-to-expand
// pill, which felt jumpy because animating a toolbar item's width does not reflow its neighbours in step,
// so mid-expand the buttons overlapped and the icon spilled out of its container. Making every label
// always-on removed the animation but overflowed the toolbar so hard that daily controls (Scout, Prep,
// Add a lead) were pushed into the macOS ">>" overflow menu. Dan's final call: plain icons, names on
// hover, which is compact, jank-free, and fits.
//
// The one exception is a button that must show text WITHOUT a hover: an attention count (Sources needs a
// look, Days off has no shoots) or a blocking call-to-action (Connect Gmail). Those pass `showsTitle:
// true` and their label renders statically. No animation, no hover state, so none of the failure modes
// above can come back.
struct ToolbarHoverLabel: View {
    let title: String
    let systemImage: String
    var showsTitle: Bool = false

    var body: some View {
        HStack(spacing: showsTitle ? 5 : 0) {
            Image(systemName: systemImage)
            if showsTitle {
                Text(title).fixedSize()
            }
        }
    }
}
