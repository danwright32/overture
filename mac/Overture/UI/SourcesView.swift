import SwiftUI
import SwiftData

// #800: the sources Overture re-checks on every scout. Read-only for now: Phase 4 is what adds a source
// and Phase 5 is what lets Dan stop watching one. It ships here so the migration that made Carnegie row
// one is visible in the app rather than only in a database.
//
// The sections are separate, and they are labelled in WORDS, because the one confusion Dan named is a
// broken source reading as an org that asked him to stop. SourceGrade is what decides which section a
// row lands in, and it is a tested domain rule, so this view has no logic of its own to get wrong.
struct SourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    @Query(sort: \WatchedSource.orgName) private var sources: [WatchedSource]
    // #794: read to compute each source's lifetime yield (found/kept/sent/booked). The tally and its
    // sentence both live in SourceYield, a tested pure function, so this view has no counting of its own.
    @Query private var prospects: [Prospect]

    // #802: the sheet is where the watchlist is MANAGED, because it was previously the only place it
    // could be seen and nowhere it could be changed: a calendar could only join by pasting a lead, and
    // unticking "keep watching" on that sheet was a dead end with no way back.
    @State private var showAdd = false
    @State private var newOrgName = ""
    @State private var newURL = ""
    @State private var addMessage: String?

    // #974: the section currently at the top of the scroll. Bound so the list HOLDS ITS PLACE while the
    // rows underneath it change. See the ScrollView below for why that is load-bearing rather than polish.
    @State private var topSection: SourceGrade?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)

            if showAdd { addForm; Divider().overlay(OVColor.line) }

            if sources.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: OVSpacing.lg) {
                        // Sectioning, ordering and the omit-empty rule all come from the tested domain
                        // function, so this view has no judgement of its own to get wrong.
                        ForEach(SourceGrade.sections(sources), id: \.grade) { section($0.grade, $0.sources) }
                    }
                    .scrollTargetLayout()
                    .padding(OVSpacing.lg)
                }
                // #974: hold the scroll where Dan put it. `sources` is a @Query, so ANY change to ANY
                // source rebuilds this content, and a scout pass changes many at once: each source it
                // checks gains a "new listings" line (#803) and can move to a different grade section.
                // A plain ScrollView drops its offset to the top on every one of those, so during a run
                // the sheet cannot be scrolled at all: it snaps back before he can read a row. Binding the
                // position to the top-visible section pins it across the rebuild. Only visible with a
                // watchlist long enough to scroll, which is why it surfaced when #359 took it from 3 to 38.
                .scrollPosition(id: $topSection, anchor: .top)
                // Sizes to its content rather than to a fixed height, so today's one-source watchlist
                // does not open as a mostly empty box, and a long one still scrolls instead of running
                // off the screen.
                .frame(maxHeight: 460)
            }
        }
        .frame(width: 560)
        .background(OVColor.canvas)
        // #845: its own banner. A sheet is a separate window on macOS, so the one on the main view cannot
        // cover it, and the Undo this sheet offers would have been drawn behind it (#285).
        .actionFeedbackBanner()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sources").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                Text("The calendars Overture re-checks on every scout.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button(WatchlistEditing.addButtonTitle(isOpen: showAdd)) { showAdd.toggle(); addMessage = nil }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(OVColor.forest)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(OVSpacing.lg)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            TextField("Organization", text: $newOrgName)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            TextField("Their events or season page", text: $newURL)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            Text("Their calendar, not one show: a single show's page never changes again, so watching it would watch nothing.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)

            if let addMessage {
                Text(addMessage).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Watch it") { addSource() }
            }
        }
        .padding(OVSpacing.md)
        .background(OVColor.surfaceSunk)
    }

    // #845: stopping says what it did AND offers the way back, in the same breath. The Undo is the
    // immediate correction (a mis-click Dan sees at once); the "Watch again" button on the row is the one
    // that never expires, because a banner he looked away from is a banner he did not read.
    private func stopWatching(_ source: WatchedSource) {
        WatchlistEditing.stopWatching(source, in: context)
        feedback.acknowledge(ActionAck.stoppedWatching(org: source.orgName),
                             action: .init(label: "Undo") { resumeWatching(source) })
    }

    private func resumeWatching(_ source: WatchedSource) {
        // The result is not ignored: a refusal must never pass silently as though it worked. The sheet
        // only draws these controls on a source Dan stopped himself, so this should be unreachable, and
        // "should be unreachable" is exactly the kind of claim that turns into a source quietly back on
        // the watchlist that asked not to be.
        switch WatchlistEditing.resumeWatching(source, in: context) {
        case .resumed, .alreadyWatching:
            feedback.acknowledge(ActionAck.resumedWatching(org: source.orgName))
        case .refused(let orgName):
            feedback.acknowledge(WatchlistEditing.resumeRefusedMessage(orgName: orgName),
                                 tone: .warning)
        case .added, .invalidURL, .needsName:
            break
        }
    }

    private func addSource() {
        switch WatchlistEditing.add(orgName: newOrgName, listingsURL: newURL, into: context) {
        case .added, .resumed:
            newOrgName = ""; newURL = ""; showAdd = false; addMessage = nil
        case .alreadyWatching(let orgName):
            addMessage = WatchlistEditing.alreadyWatchingMessage(orgName: orgName)
        case .refused(let orgName):
            // He must SEE this. Silently declining would look exactly like a bug, and this is the one
            // thing in the whole feature that must not be got wrong quietly. #885: the sentence itself
            // lives with the rule that produces it, and is now written once rather than three times.
            addMessage = WatchlistEditing.refusedMessage(orgName: orgName)
        case .invalidURL:
            addMessage = WatchlistEditing.invalidURLMessage
        case .needsName:
            addMessage = WatchlistEditing.needsNameMessage
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text("No sources yet.").font(.system(size: 13, weight: .medium)).foregroundStyle(OVColor.ink)
            Text("Carnegie Hall is added the first time Overture opens your store.")
                .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OVSpacing.lg)
    }

    private func section(_ grade: SourceGrade, _ rows: [WatchedSource]) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(spacing: OVSpacing.xxs) {
                Image(systemName: grade.systemImage).font(.system(size: 11))
                Text(grade.label).font(.system(size: 12, weight: .semibold))
                Text("(\(rows.count))").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
            }
            .foregroundStyle(grade.isBroken ? OVColor.rust : OVColor.ink)

            // #841: only where it says something the heading and the sheet's subtitle do not.
            if let explanation = grade.explanation {
                Text(explanation).font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(rows) { source in
                    row(source)
                    if source.persistentModelID != rows.last?.persistentModelID {
                        Divider().overlay(OVColor.line)
                    }
                }
            }
            .background(OVColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
        }
    }

    private func row(_ source: WatchedSource) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                Text(source.orgName).font(.system(size: 13, weight: .medium)).foregroundStyle(OVColor.ink)
                Spacer()
                Text(lastChecked(source)).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            }

            if let url = source.listingsURL {
                Text(url).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint).lineLimit(1)
            }

            // #803: CHECKED and READ are different things, and the sheet could not tell them apart. The
            // free daily run fetches and hashes every calendar and reads none of them, so a source can
            // report "checked an hour ago" for weeks while nobody has looked at what is on it. That is
            // the design, but invisible it becomes a leak: shows sitting unread on a calendar that
            // reports as perfectly healthy.
            //
            // #840: said only when it adds something. Read in the same run that checked it (a native
            // feed, or any source a scout just read) is one event, and Dan's Carnegie row described it
            // twice: "Checked 8 hours ago", then "Read 8 hours ago". Repetition teaches him to skim, and
            // the state this exists to surface is the one line here he must never skim past.
            // #843: the failure is passed in because a `notRead` run leaves this line and the failure line
            // below saying the same thing; the read-state decides, in one tested place, to step aside for
            // it rather than repeat it.
            let readState = SourceReadState.of(source)
            if readState.isWorthShowing(lastCheckedAt: source.lastCheckedAt, failure: source.lastFailure) {
                Text(readState.label)
                    .font(.system(size: 11))
                    .foregroundStyle(readState.needsAScout ? OVColor.gold : OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #794: what this source has actually earned over its lifetime, kept-first: "3 of 12 kept",
            // with sent/booked appended when present. A source that extracts perfectly and produces
            // nothing Dan keeps is dead weight ("0 of 12 kept"), and that has to be visible, or a source
            // sits generating junk forever. Nothing here removes it: only a refusal (or Dan's own removal)
            // takes a source off the list. Silent when the source has found nothing yet.
            if let yield = SourceYield.line(SourceYield.tally(sourceId: source.sourceId, in: prospects)) {
                Text(yield).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A named failure, never a bare "broken". A source Dan cannot act on is a source he will
            // learn to ignore.
            if let failure = source.lastFailure {
                Text(failure.message).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #891: shows on this calendar whose own page Overture could not open. A source quietly
            // returning half its shows unreadable is BROKEN, not quiet, and those two looked identical
            // here. Past the tolerance it has also stopped being able to mark anything gone (#887), and
            // the sentence says so, because that consequence is the part Dan can act on.
            //
            // Gold, not rust: this is a source degrading, not a source that failed. The wording is decided
            // in SourceReadability, never here (#863/#885).
            if let readability = source.readabilityNote {
                Text(readability).font(.system(size: 11)).foregroundStyle(OVColor.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #875: the RUN'S OWN account of this source, which until now was decoded and thrown away
            // while Dan was shown only the generic sentence for the verdict. The generic line says WHAT
            // happened ("The run ended before reading this page"); this one says WHY, and why is the only
            // part he can act on.
            //
            // The sentence goes in the row and the raw log tail goes on hover (Dan's call, 2026-07-13):
            // a failing source would otherwise unroll six lines of shell output into the sheet and make
            // every row around it unreadable. Both halves are decided in SourceNote, never here (#863).
            if let note = source.runNote {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(source.runNoteDetail ?? note)
            }

            // A permanently dead source needs a way out that is DAN'S choice, or a failing source would
            // be reported at him every run forever with nothing he could do about it. Recorded as his
            // decision, never as a refusal: Carnegie is excluded because it has no page to watch.
            //
            // #842: it has to LOOK like something he can do. Styled as an 11pt plain line under three
            // other 11pt lines, it read as a fourth statement of fact, and it is the only way a source
            // ever leaves the watchlist: #802 rests on a failing source never auto-deactivating, so Dan
            // removing it himself is the deliberate escape hatch. An escape hatch he cannot see is not
            // one. Same bordered-capsule idiom the queue's own secondary action (Dismiss) uses, so
            // "you can do this" looks the same everywhere in the app, and sitting on its own trailing
            // line rather than in the metadata stack.
            if source.isActive, source.kind != .algolia {
                HStack {
                    Spacer()
                    Button {
                        stopWatching(source)
                    } label: {
                        Text("Stop watching")
                            .font(.system(size: 11))
                            .foregroundStyle(OVColor.inkSoft)
                            .padding(.horizontal, OVSpacing.sm)
                            .padding(.vertical, 4)
                            .background(Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }

            // #845: the way back, on the row itself.
            //
            // Stopping was always reversible (the row, its feed history and the source id stamped on every
            // prospect it ever surfaced all survive), but the only route back was to retype the org name
            // and the URL into the add form, and nothing on this sheet said even that. So a reversible
            // action read as a permanent one, and #802 rests on Dan being willing to take it: a failing
            // source is never auto-deactivated, precisely so that removing it stays his deliberate choice.
            //
            // ONLY on a source Dan stopped himself. An org that asked him to stop is a different section
            // and a different state, and it never gets this button. WatchlistEditing.resumeWatching
            // enforces that too, because a guarantee that lives in a view lasts until the next view.
            if SourceGrade(source) == .removed {
                HStack {
                    Spacer()
                    Button {
                        resumeWatching(source)
                    } label: {
                        Text("Watch again")
                            .font(.system(size: 11))
                            .foregroundStyle(OVColor.forest)
                            .padding(.horizontal, OVSpacing.sm)
                            .padding(.vertical, 4)
                            .background(Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, OVSpacing.sm)
        .padding(.vertical, OVSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "Never" is a real answer and is said out loud, rather than being left as a blank cell that reads
    // like a rendering bug.
    private func lastChecked(_ source: WatchedSource) -> String {
        SourceReadState.lastCheckedLine(at: source.lastCheckedAt, now: Date())   // #885
    }
}
