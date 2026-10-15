import SwiftUI

/// A saved recipe for a new window (SPEC §6.4): a window name and command
/// lines typed into its shell, for example `ssh gmktec` then `claude`.
struct WindowTemplate: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String
    var windowName: String
    var commands: [String]
}

struct NewWindowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionController

    @State private var name = ""
    @State private var commands = ""
    @State private var saveAsTemplate = false
    @State private var templateLabel = ""
    @State private var editing: WindowTemplate?

    private var templates: [WindowTemplate] { model.templates(for: session.server.id) }

    var body: some View {
        Form {
            if !templates.isEmpty {
                Section("Templates") {
                    ForEach(templates) { template in
                        Button {
                            create(name: template.windowName, commands: template.commands)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.label)
                                Text(([template.windowName] + template.commands).joined(separator: " · "))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.deleteTemplate(template, server: session.server.id) }
                            Button("Edit") { load(template) }
                        }
                    }
                }
            }
            Section {
                TextField("Window name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                TextField("Commands, one per line (optional)", text: $commands, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text(editing == nil ? "New window" : "Edit template")
            } footer: {
                Text("Each line is typed into the new window's shell, followed by Enter. Example: ssh gmktec, then claude.")
            }
            Section {
                Toggle("Save as template", isOn: $saveAsTemplate)
                if saveAsTemplate {
                    TextField("Template name (e.g. Claude on gmktec)", text: $templateLabel)
                }
            }
            Section {
                Button(editing == nil ? "Create window" : "Save and create") {
                    if saveAsTemplate || editing != nil { saveTemplate() }
                    create(name: name, commands: commandLines)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("New window")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }

    private var commandLines: [String] {
        commands.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func load(_ template: WindowTemplate) {
        editing = template
        name = template.windowName
        commands = template.commands.joined(separator: "\n")
        templateLabel = template.label
        saveAsTemplate = true
    }

    private func saveTemplate() {
        var template = editing ?? WindowTemplate(label: "", windowName: "", commands: [])
        template.label = templateLabel.isEmpty ? name : templateLabel
        template.windowName = name.trimmingCharacters(in: .whitespaces)
        template.commands = commandLines
        model.saveTemplate(template, server: session.server.id)
    }

    private func create(name: String, commands: [String]) {
        session.createWindow(name: name.trimmingCharacters(in: .whitespaces), commands: commands)
        dismiss()
    }
}
