import SwiftUI

struct HotkeySettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var recordingTarget: RecordingTarget?
    @State private var conflictAlert: ConflictAlert?
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hotkey Bindings")
                    .font(.headline)
                Spacer()
                Button("Reset to Defaults") {
                    settings.resetHotkeysToDefaults()
                    controller.updateHotkeyBindings(settings.hotkeyBindings)
                }
                .buttonStyle(.link)
            }
            .padding(.bottom, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search hotkeys...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(HotkeyCategory.allCases, id: \.self) { category in
                        let actions = actionsForCategory(category)
                        if !actions.isEmpty {
                            HotkeyCategorySection(
                                category: category,
                                bindings: actions,
                                recordingTarget: $recordingTarget,
                                registrationFailures: controller.hotkeyRegistrationFailures,
                                onBindingCaptured: handleBindingCaptured,
                                onAddBinding: startRecordingForAdd,
                                onRemoveBinding: removeBinding,
                                onResetBindings: resetBindings
                            )
                        }
                    }
                }
            }
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("Hotkey Conflict"),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Replace")) {
                    applyBinding(alert.newBinding, to: alert.target, clearingConflicts: true)
                },
                secondaryButton: .cancel {
                    recordingTarget = nil
                }
            )
        }
    }

    private func actionsForCategory(_ category: HotkeyCategory) -> [HotkeyBinding] {
        settings.hotkeyBindings.filter { binding in
            binding.category == category && ActionCatalog.matchesSearch(searchText, binding: binding)
        }
    }

    private func startRecordingForAdd(actionId: String) {
        recordingTarget = .add(actionId: actionId)
    }

    private func handleBindingCaptured(target: RecordingTarget, newBinding: KeyBinding) {
        let conflicts = settings.findConflicts(for: newBinding, excluding: target.actionId)
        if !conflicts.isEmpty {
            conflictAlert = ConflictAlert(
                target: target,
                newBinding: newBinding,
                conflictingCommands: conflicts.map(\.command.displayName)
            )
            recordingTarget = nil
        } else {
            applyBinding(newBinding, to: target, clearingConflicts: false)
        }
    }

    private func applyBinding(_ binding: KeyBinding, to target: RecordingTarget, clearingConflicts: Bool) {
        if clearingConflicts {
            let conflicts = settings.findConflicts(for: binding, excluding: target.actionId)
            for conflict in conflicts {
                settings.removeBinding(binding, from: conflict.id)
            }
        }

        switch target {
        case let .add(actionId):
            settings.addBinding(for: actionId, newBinding: binding)
        case let .replace(actionId, index):
            settings.replaceBinding(for: actionId, at: index, with: binding)
        }

        controller.updateHotkeyBindings(settings.hotkeyBindings)
        recordingTarget = nil
    }

    private func removeBinding(actionId: String, index: Int) {
        settings.removeBinding(for: actionId, at: index)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        recordingTarget = nil
    }

    private func resetBindings(actionId: String) {
        settings.resetBindings(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        recordingTarget = nil
    }
}

enum RecordingTarget: Equatable, Identifiable {
    case add(actionId: String)
    case replace(actionId: String, bindingIndex: Int)

    var id: String {
        switch self {
        case let .add(actionId):
            return "add:\(actionId)"
        case let .replace(actionId, bindingIndex):
            return "replace:\(actionId):\(bindingIndex)"
        }
    }

    var actionId: String {
        switch self {
        case let .add(actionId):
            return actionId
        case let .replace(actionId, _):
            return actionId
        }
    }
}

struct ConflictAlert: Identifiable {
    let id = UUID()
    let target: RecordingTarget
    let newBinding: KeyBinding
    let conflictingCommands: [String]

    var message: String {
        if conflictingCommands.count == 1 {
            return "This key combination is already used by \"\(conflictingCommands[0])\". Do you want to replace it?"
        } else {
            let commandList = conflictingCommands.joined(separator: ", ")
            return "This key combination is used by: \(commandList). Do you want to replace all?"
        }
    }
}

struct HotkeyCategorySection: View {
    let category: HotkeyCategory
    let bindings: [HotkeyBinding]
    @Binding var recordingTarget: RecordingTarget?
    let registrationFailures: Set<HotkeyCommand>
    let onBindingCaptured: (RecordingTarget, KeyBinding) -> Void
    let onAddBinding: (String) -> Void
    let onRemoveBinding: (String, Int) -> Void
    let onResetBindings: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.rawValue)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)

            ForEach(bindings) { binding in
                HotkeyBindingRow(
                    binding: binding,
                    recordingTarget: $recordingTarget,
                    hasFailed: registrationFailures.contains(binding.command),
                    onBindingCaptured: onBindingCaptured,
                    onAddBinding: onAddBinding,
                    onRemoveBinding: onRemoveBinding,
                    onResetBindings: onResetBindings
                )
            }
        }
    }
}

struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    @Binding var recordingTarget: RecordingTarget?
    let hasFailed: Bool
    let onBindingCaptured: (RecordingTarget, KeyBinding) -> Void
    let onAddBinding: (String) -> Void
    let onRemoveBinding: (String, Int) -> Void
    let onResetBindings: (String) -> Void

    @State private var showHotkeyHelp = false
    @State private var hotkeyHelpTask: Task<Void, Never>?

    private let hoverHelpDelayNs: UInt64 = 120_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 6) {
                    Text(binding.command.displayName)
                    if binding.command.layoutCompatibility != .shared {
                        Text(binding.command.layoutCompatibility.rawValue)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(binding.command.layoutCompatibility == .niri ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                            .foregroundColor(binding.command.layoutCompatibility == .niri ? .blue : .purple)
                            .cornerRadius(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if hasFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .help("Failed to register: this key combination may be reserved by the system")
                }

                Button("Reset") {
                    hideHotkeyHelp()
                    recordingTarget = nil
                    onResetBindings(binding.id)
                }
                .buttonStyle(.link)
            }

            VStack(alignment: .leading, spacing: 6) {
                if binding.bindings.isEmpty {
                    HStack {
                        Text("Unassigned")
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        Button("Add Binding") {
                            hideHotkeyHelp()
                            recordingTarget = nil
                            onAddBinding(binding.id)
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    ForEach(Array(binding.bindings.enumerated()), id: \.offset) { index, currentBinding in
                        HotkeyBindingChip(
                            binding: currentBinding,
                            isRecording: recordingTarget == .replace(actionId: binding.id, bindingIndex: index),
                            onStartRecording: {
                                hideHotkeyHelp()
                                recordingTarget = .replace(actionId: binding.id, bindingIndex: index)
                            },
                            onCaptured: { newBinding in
                                onBindingCaptured(.replace(actionId: binding.id, bindingIndex: index), newBinding)
                            },
                            onCancel: {
                                recordingTarget = nil
                            },
                            onRemove: {
                                hideHotkeyHelp()
                                onRemoveBinding(binding.id, index)
                            },
                            showHotkeyHelp: $showHotkeyHelp,
                            hoverHelpDelayNs: hoverHelpDelayNs
                        )
                    }
                }

                Button {
                    hideHotkeyHelp()
                    recordingTarget = nil
                    onAddBinding(binding.id)
                } label: {
                    Label("Add Binding", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, 2)
        .zIndex(showHotkeyHelp ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: showHotkeyHelp)
        .onDisappear {
            cancelHotkeyHelpTask()
        }
    }

    private func hideHotkeyHelp() {
        cancelHotkeyHelpTask()
        showHotkeyHelp = false
    }

    private func cancelHotkeyHelpTask() {
        hotkeyHelpTask?.cancel()
        hotkeyHelpTask = nil
    }
}

struct HotkeyBindingChip: View {
    let binding: KeyBinding
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onCaptured: (KeyBinding) -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    @Binding var showHotkeyHelp: Bool
    let hoverHelpDelayNs: UInt64

    @State private var hotkeyHelpTask: Task<Void, Never>?

    var body: some View {
        let helpText = binding.humanReadableString

        HStack(spacing: 6) {
            if isRecording {
                KeyRecorderView(onCapture: onCaptured, onCancel: onCancel)
                    .frame(width: 100, height: 24)
            } else {
                Button(action: {
                    hideHotkeyHelp()
                    onStartRecording()
                }) {
                    Text(binding.displayString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    if showHotkeyHelp {
                        HotkeyHoverTooltip(text: helpText)
                            .offset(y: -34)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                    }
                }
                .onHover(perform: updateHotkeyHover)

                if !binding.isUnassigned {
                    Button(action: {
                        hideHotkeyHelp()
                        onRemove()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this hotkey")
                }
            }
        }
        .onDisappear {
            cancelHotkeyHelpTask()
        }
    }

    private func updateHotkeyHover(_ hovering: Bool) {
        cancelHotkeyHelpTask()

        guard hovering else {
            showHotkeyHelp = false
            return
        }

        hotkeyHelpTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hoverHelpDelayNs)
            guard !Task.isCancelled else { return }
            showHotkeyHelp = true
        }
    }

    private func hideHotkeyHelp() {
        cancelHotkeyHelpTask()
        showHotkeyHelp = false
    }

    private func cancelHotkeyHelpTask() {
        hotkeyHelpTask?.cancel()
        hotkeyHelpTask = nil
    }
}

private struct HotkeyHoverTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .allowsHitTesting(false)
    }
}
