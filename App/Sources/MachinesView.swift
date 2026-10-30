import EtLink
import ETCore
import SwiftUI

/// The main screen for an iroh server (PLAN-manymux B3): the manymux
/// sessions of every machine, the hub first. Tap opens a session page;
/// long-press renames (on this device or on the machine), ends, or opens
/// view-only. Long-press a machine's header to rename it on this device.
struct MachinesView: View {
    @Bindable var session: SessionController
    @State private var renaming: Target?
    @State private var newName = ""
    @State private var ending: Target?
    @State private var nicknaming: NicknameTarget?

    struct Target: Identifiable {
        let machine: String
        let name: String
        var id: String { machine + "/" + name }
    }

    var body: some View {
        List {
            if let missing = session.mmMissing {
                Section {
                    ForEach(missing.targets, id: \.self) { target in
                        Text(target).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Button { session.restoreCheckpoint() } label: {
                        HStack {
                            Label("Restore", systemImage: "arrow.counterclockwise")
                            if session.mmRestoring { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(session.mmRestoring)
                } header: {
                    Text("\(missing.targets.count) session\(missing.targets.count == 1 ? "" : "s") not running (saved \(missing.checkpoint.savedAgo) ago)")
                } footer: {
                    Text("From the checkpoint \(session.hubName ?? "the hub") saves every 15 minutes. Running sessions are left alone.")
                }
            }
            ForEach(session.machines) { machine in
                Section {
                    if let error = machine.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    } else if machine.sessions.isEmpty {
                        Text("No sessions").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(machine.sessions) { info in
                        Button { session.openMm(machine: machine.name, name: info.name) } label: {
                            MmSessionRow(info: info, nickname: Nicknames.shared.nickname(for: .session(machine: machine.name, name: info.name)))
                        }
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                nicknaming = .session(machine: machine.name, name: info.name)
                            }
                            Button("Rename on Machine…", systemImage: "server.rack") {
                                newName = info.name
                                renaming = Target(machine: machine.name, name: info.name)
                            }
                            Button("Open view-only", systemImage: "eye") {
                                session.openMm(machine: machine.name, name: info.name, readOnly: true)
                            }
                            Button("End…", systemImage: "xmark.circle", role: .destructive) {
                                ending = Target(machine: machine.name, name: info.name)
                            }
                        }
                    }
                } header: {
                    Text(Nicknames.shared.machine(machine.name))
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") { nicknaming = .machine(machine.name) }
                        }
                }
            }
            Section {
                Button { session.setMode(.tmux) } label: {
                    Label("tmux", systemImage: "rectangle.split.3x1")
                }
            } footer: {
                Text("The tmux sessions on \(session.hubName ?? session.server.displayName), as before.")
            }
        }
        // The controller also refreshes every 5 s while connected.
        .refreshable { await session.refreshMachines() }
        .overlay {
            if session.machines.isEmpty, session.state == .connected {
                ProgressView()
            }
        }
        .alert("Restore", isPresented: Binding(get: { session.mmRestoreOutput != nil }, set: { if !$0 { session.mmRestoreOutput = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.mmRestoreOutput ?? "")
        }
        .nicknameAlert($nicknaming)
        .alert("Rename on \(renaming?.machine ?? "machine")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") { if let t = renaming { session.renameMm(machine: t.machine, name: t.name, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device sees the new name.")
        }
        .confirmationDialog("End \(ending?.name ?? "")?", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                            titleVisibility: .visible) {
            Button("End session", role: .destructive) { if let t = ending { session.endMm(machine: t.machine, name: t.name) } }
        } message: {
            Text("This stops the program in \(ending?.name ?? "the session") on \(ending?.machine ?? "its machine").")
        }
    }
}

/// Nickname or title (the main line), then name · idle · attached; a red
/// dot for bells; the agent's mark (PLAN-multi-agent).
struct MmSessionRow: View {
    let info: MmSessionInfo
    var nickname: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(info.bells > 0 ? Color.red : Color.clear).frame(width: 8, height: 8)
            if let agent = AgentProfile.matching(command: info.command, name: info.name, title: info.title) {
                AgentMark(profile: agent, size: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(nickname ?? (info.title.isEmpty ? info.name : info.title))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(info.name).font(.caption.monospaced())
                    Text("· \(Manymux.idleLabel(seconds: info.idleSecs))").font(.caption).monospacedDigit()
                    if info.attached > 0 {
                        Label("\(info.attached)", systemImage: "person.fill").font(.caption).labelStyle(.titleAndIcon)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// "+": machine, then Shell / an installed agent / a command, and an
/// optional name (PLAN-multi-agent §4.2).
struct MmSpawnSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SessionController
    let agents: Agents?
    @State private var machine = ""
    @State private var choice: SpawnChoice = .shell
    @State private var command = ""
    @State private var name = ""

    private var arguments: [String] {
        choice.launch ?? Manymux.splitCommand(command)
    }

    var body: some View {
        Form {
            Section("Machine") {
                Picker("Machine", selection: $machine) {
                    ForEach(session.machines) { Text(Nicknames.shared.machine($0.name)).tag($0.name) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Run") {
                SpawnChoices(agents: agents, machine: machine, choice: $choice)
                if choice == .command {
                    TextField("Command, e.g. htop", text: $command)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                }
            }
            Section {
                TextField("Name (optional)", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
            } footer: {
                Text("Without a name, manymux names it after the command.")
            }
        }
        .navigationTitle("New session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    session.spawnMm(machine: machine, name: trimmed.isEmpty ? nil : trimmed, command: arguments)
                    dismiss()
                }
                .disabled(machine.isEmpty || (choice == .command && arguments.isEmpty))
            }
        }
        .onAppear {
            if machine.isEmpty { machine = session.mmMachineName ?? session.machines.first?.name ?? "" }
        }
    }
}
