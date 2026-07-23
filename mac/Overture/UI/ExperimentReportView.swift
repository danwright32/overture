import SwiftUI
import SwiftData

// #5 Phase 4: the opener A/B report and its start/stop controls. Sibling of OutcomePatternsView. ALL of
// the rate, threshold, exclusion, and compliance logic lives in ExperimentReport (tested), and the
// create/end rules live in ExperimentEditing (tested); this view only renders and wires the two buttons.
// It never declares a winner (that is #4): the bar only gates the "too few to tell" line.
struct ExperimentReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Experiment.startedAt, order: .reverse)]) private var experiments: [Experiment]
    @Query private var prospects: [Prospect]

    @State private var selectedId: String?
    @State private var newVariantA: OpenerArchetype = .reasonFirst
    @State private var newVariantB: OpenerArchetype = .credentialFirst
    @State private var showStartForm = false

    private var activeExperiment: Experiment? { experiments.first(where: \.isActive) }
    private var selected: Experiment? {
        experiments.first { $0.experimentId == selectedId } ?? activeExperiment ?? experiments.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Opener A/B").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)
            Divider()

            if experiments.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(width: 480, height: 560)
        .background(OVColor.canvas)
        .onAppear { if selectedId == nil { selectedId = selected?.experimentId } }
    }

    private var emptyState: some View {
        VStack(spacing: OVSpacing.md) {
            Text("No experiment running. Start one to test two opener styles against each other and see which earns more replies. Nothing changes until you start it.")
                .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .multilineTextAlignment(.center)
            startForm
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OVSpacing.xl)
    }

    @ViewBuilder private var content: some View {
        Picker("Experiment", selection: Binding(
            get: { selected?.experimentId ?? "" },
            set: { selectedId = $0 }
        )) {
            ForEach(experiments) { e in Text(experimentLabel(e)).tag(e.experimentId) }
        }
        .labelsHidden()
        .padding(.horizontal, OVSpacing.lg).padding(.vertical, OVSpacing.sm)
        Divider()

        if let exp = selected {
            let report = ExperimentReport.report(for: exp, allProspects: prospects)
            ScrollView {
                VStack(alignment: .leading, spacing: OVSpacing.md) {
                    if report.tooFewToTell {
                        Text(ExperimentReport.tooFewToTellLine())
                            .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                    }
                    ForEach(report.arms, id: \.arm) { arm in
                        armRow(arm, tooFewToTell: report.tooFewToTell)
                        Divider()
                    }
                    management(for: exp)
                }
                .padding(OVSpacing.lg)
            }
        }
    }

    private func armRow(_ arm: ExperimentReport.ArmReport, tooFewToTell: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(OpenerArchetype(rawValue: arm.arm)?.label ?? arm.arm)
                .font(OVType.groupName).foregroundStyle(OVColor.ink)
            Text(ExperimentReport.replyLine(arm, tooFewToTell: tooFewToTell))
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            if let compliance = ExperimentReport.complianceLine(arm) {
                Text(compliance).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
            }
            if let edited = ExperimentReport.editedExcludedLine(arm) {
                Text(edited).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
            }
        }
    }

    @ViewBuilder private func management(for exp: Experiment) -> some View {
        if exp.isActive {
            Button("End this experiment") {
                try? ExperimentEditing.end(exp, at: Date(), in: context)
            }
        }
        DisclosureGroup("Start a new experiment", isExpanded: $showStartForm) { startForm }
            .font(OVType.meta)
    }

    private var startForm: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            stylerow("Style A", selection: $newVariantA)
            stylerow("Style B", selection: $newVariantB)
            if newVariantA == newVariantB {
                Text("Pick two different styles to compare.")
                    .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
            }
            Button("Start experiment") {
                if let started = try? ExperimentEditing.start(
                    variantA: newVariantA, variantB: newVariantB, startedAt: Date(), in: context) {
                    selectedId = started.experimentId
                    showStartForm = false
                }
            }
            .disabled(newVariantA == newVariantB)
        }
    }

    private func stylerow(_ label: String, selection: Binding<OpenerArchetype>) -> some View {
        HStack {
            Text(label).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            Picker(label, selection: selection) {
                ForEach(OpenerArchetype.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func experimentLabel(_ e: Experiment) -> String {
        let a = OpenerArchetype(rawValue: e.variantA)?.label ?? e.variantA
        let b = OpenerArchetype(rawValue: e.variantB)?.label ?? e.variantB
        return "\(a) vs \(b) " + (e.isActive ? "(active)" : "(ended)")
    }
}
