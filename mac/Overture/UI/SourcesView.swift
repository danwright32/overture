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
    @Query(sort: \WatchedSource.orgName) private var sources: [WatchedSource]

    // #802: the sheet is where the watchlist is MANAGED, because it was previously the only place it
    // could be seen and nowhere it could be changed: a calendar could only join by pasting a lead, and
    // unticking "keep watching" on that sheet was a dead end with no way back.
    @State private var showAdd = false
    @State private var newOrgName = ""
    @State private var newURL = ""
    @State private var addMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)

            if showAdd { addForm; Divider().overlay(OVColor.line) }

            if sources.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: OVSpacing.lg) {
                        // Sectioning, ordering and the omit-empty rule all come from the tested domain
                        // function, so this view has no judgement of its own to get wrong.
                        ForEach(SourceGrade.sections(sources), id: \.grade) { section($0.grade, $0.sources) }
                    }
                    .padding(OVSpacing.lg)
                }
                // Sizes to its content rather than to a fixed height, so today's one-source watchlist
                // does not open as a mostly empty box, and a long one still scrolls instead of running
                // off the screen.
                .frame(maxHeight: 460)
            }
        }
        .frame(width: 560)
        .background(OVColor.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sources").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                Text("The calendars Overture re-checks on every scout.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button(showAdd ? "Cancel" : "Watch a calendar") { showAdd.toggle(); addMessage = nil }
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

    private func addSource() {
        switch WatchlistEditing.add(orgName: newOrgName, listingsURL: newURL, into: context) {
        case .added, .resumed:
            newOrgName = ""; newURL = ""; showAdd = false; addMessage = nil
        case .alreadyWatching(let orgName):
            addMessage = "Already watching \(orgName)'s calendar."
        case .refused(let orgName):
            // He must SEE this. Silently declining would look exactly like a bug, and this is the one
            // thing in the whole feature that must not be got wrong quietly.
            addMessage = "\(orgName) asked not to be contacted, so Overture won't watch their calendar."
        case .invalidURL:
            addMessage = "That doesn't look like a web address."
        case .needsName:
            addMessage = "Give the organization a name so you can recognize it here."
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
            let readState = SourceReadState.of(source)
            if readState.isWorthShowing(lastCheckedAt: source.lastCheckedAt) {
                Text(readState.label)
                    .font(.system(size: 11))
                    .foregroundStyle(readState.needsAScout ? OVColor.gold : OVColor.inkFaint)
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
                        WatchlistEditing.stopWatching(source, in: context)
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
        }
        .padding(.horizontal, OVSpacing.sm)
        .padding(.vertical, OVSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "Never" is a real answer and is said out loud, rather than being left as a blank cell that reads
    // like a rendering bug.
    private func lastChecked(_ source: WatchedSource) -> String {
        guard let at = source.lastCheckedAt else { return "Never checked" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Checked \(f.localizedString(for: at, relativeTo: Date()))"
    }
}
