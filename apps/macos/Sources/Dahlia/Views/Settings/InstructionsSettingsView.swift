import SwiftUI

private enum InstructionsEditorLayout {
    static let editorPadding = EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
}

struct InstructionsSettingsView: View {
    var sidebarViewModel: SidebarViewModel

    @ObservedObject private var appSettings = AppSettings.shared
    @State private var selectedInstructionID: UUID?
    @State private var draftName = ""
    @State private var draftContent = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var instructionPendingDeletion: InstructionRecord?
    @State private var isShowingDeleteConfirmation = false
    @FocusState private var isNameFieldFocused: Bool

    private let listWidth: CGFloat = 280

    var body: some View {
        Group {
            if sidebarViewModel.allInstructions.isEmpty {
                emptyInstructionsView
            } else {
                HStack(spacing: 0) {
                    instructionsList
                        .frame(minWidth: 220, idealWidth: listWidth, maxWidth: 320)

                    Divider()

                    instructionEditor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 440)
        .onAppear(perform: selectInitialInstructionIfNeeded)
        .onChange(of: selectedInstructionID) { oldInstructionID, _ in
            persistDraftsIfNeeded(for: oldInstructionID)
            syncDraftsFromSelection()
        }
        .onChange(of: draftName) { _, _ in
            scheduleSave()
        }
        .onChange(of: draftContent) { _, _ in
            scheduleSave()
        }
        .onDisappear {
            saveTask?.cancel()
            persistDraftsIfNeeded()
        }
        .onDeleteCommand(perform: requestSelectedInstructionDeletion)
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.delete, role: .destructive, action: confirmInstructionDeletion)
            Button(L10n.cancel, role: .cancel) {
                instructionPendingDeletion = nil
            }
        } message: {
            Text(L10n.deleteInstructionWarning)
        }
    }

    private var selectedInstruction: InstructionRecord? {
        instruction(for: selectedInstructionID)
    }

    private var instructionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.instructions)
                    .font(.title2.weight(.semibold))

                Spacer(minLength: 0)

                Button(L10n.create, systemImage: "plus") {
                    createInstruction()
                }
                .labelStyle(.iconOnly)
                .help(L10n.addInstruction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            List(selection: $selectedInstructionID) {
                ForEach(sidebarViewModel.allInstructions) { instruction in
                    instructionRow(instruction)
                        .tag(instruction.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                requestInstructionDeletion(instruction)
                            } label: {
                                Label(L10n.delete, systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var instructionEditor: some View {
        if let selectedInstruction {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(L10n.title, text: $draftName)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.weight(.semibold))
                            .focused($isNameFieldFocused)

                        Text(editorStatusText(for: selectedInstruction))
                            .font(.callout)
                            .foregroundStyle(isInstructionTitleValid ? Color.secondary : Color.red)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        if appSettings.selectedInstructionID == selectedInstruction.id {
                            Button(L10n.useAutoInstructions) {
                                sidebarViewModel.useInstructionForSummary(nil)
                            }
                        } else {
                            Button(L10n.useForSummary) {
                                sidebarViewModel.useInstructionForSummary(selectedInstruction.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button(L10n.delete, role: .destructive) {
                            requestSelectedInstructionDeletion()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

                Divider()

                TextEditor(text: $draftContent)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(InstructionsEditorLayout.editorPadding)
                    .background(Color(nsColor: .textBackgroundColor))
                    .padding(12)
            }
        } else {
            ContentUnavailableView {
                Label(L10n.instructions, systemImage: "list.bullet.clipboard")
            } description: {
                Text(L10n.selectInstructionDescription)
            } actions: {
                if let firstInstruction = sidebarViewModel.allInstructions.first {
                    Button(L10n.selectInstruction) {
                        selectedInstructionID = firstInstruction.id
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyInstructionsView: some View {
        ContentUnavailableView {
            Label(L10n.noInstructionsYet, systemImage: "list.bullet.clipboard")
        } description: {
            Text(L10n.addInstructionDescription)
        } actions: {
            Button(L10n.addInstruction, action: createInstruction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func instructionRow(_ instruction: InstructionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(instruction.displayName)
                        .lineLimit(1)

                    if appSettings.selectedInstructionID == instruction.id {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel(L10n.summaryInstructionSelected)
                    }
                }

                Text(preview(for: instruction.content))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    private func preview(for content: String) -> String {
        let compact = content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? L10n.instructionsEmptyContent : compact
    }

    private func activeInstructionStatusText(for instruction: InstructionRecord) -> String {
        if appSettings.selectedInstructionID == instruction.id {
            return L10n.summaryInstructionSelected
        }
        return L10n.summaryInstructionNotSelected
    }

    private var isInstructionTitleValid: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func editorStatusText(for instruction: InstructionRecord) -> String {
        guard isInstructionTitleValid else { return L10n.instructionTitleRequired }
        if isSaving {
            return L10n.saving
        }
        return "\(activeInstructionStatusText(for: instruction)) \(L10n.changesSaveAutomatically)"
    }

    private func instruction(for id: UUID?) -> InstructionRecord? {
        guard let id else { return nil }
        return sidebarViewModel.allInstructions.first(where: { $0.id == id })
    }

    private func selectInitialInstructionIfNeeded() {
        guard selectedInstructionID == nil else { return }
        selectedInstructionID = appSettings.selectedInstructionID ?? sidebarViewModel.allInstructions.first?.id
        syncDraftsFromSelection()
    }

    private func syncDraftsFromSelection() {
        saveTask?.cancel()
        isSaving = false
        draftName = selectedInstruction?.name ?? ""
        draftContent = selectedInstruction?.content ?? ""
    }

    private func scheduleSave() {
        guard let selectedInstruction else { return }
        saveTask?.cancel()
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            isSaving = false
            return
        }
        guard trimmedName != selectedInstruction.name || draftContent != selectedInstruction.content else {
            isSaving = false
            return
        }
        isSaving = true
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            persistDraftsIfNeeded()
            isSaving = false
        }
    }

    private func persistDraftsIfNeeded() {
        persistDraftsIfNeeded(for: selectedInstructionID)
    }

    private func persistDraftsIfNeeded(for instructionID: UUID?) {
        guard let selectedInstruction = instruction(for: instructionID) else { return }

        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        guard trimmedName != selectedInstruction.name || draftContent != selectedInstruction.content else { return }
        sidebarViewModel.updateInstruction(id: selectedInstruction.id, name: trimmedName, content: draftContent)
    }

    private func createInstruction() {
        guard let instruction = sidebarViewModel.createInstruction() else { return }
        selectedInstructionID = instruction.id
        isNameFieldFocused = true
    }

    private var deleteConfirmationTitle: String {
        guard let instructionPendingDeletion else { return L10n.delete }
        return L10n.deleteInstructionConfirmation(instructionPendingDeletion.displayName)
    }

    private func requestSelectedInstructionDeletion() {
        guard let selectedInstruction else { return }
        requestInstructionDeletion(selectedInstruction)
    }

    private func requestInstructionDeletion(_ instruction: InstructionRecord) {
        instructionPendingDeletion = instruction
        isShowingDeleteConfirmation = true
    }

    private func confirmInstructionDeletion() {
        guard let instructionPendingDeletion else { return }
        sidebarViewModel.deleteInstruction(id: instructionPendingDeletion.id)
        if selectedInstructionID == instructionPendingDeletion.id {
            selectedInstructionID = sidebarViewModel.allInstructions.first(where: { $0.id != instructionPendingDeletion.id })?.id
        }
        self.instructionPendingDeletion = nil
    }
}
