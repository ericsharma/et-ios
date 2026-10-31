import SwiftUI

/// The edit sheet's subject: a project to rename or move sessions into.
struct LogbookEdit: Identifiable {
    var project: LogbookReport.Project?
    var session: String?
    var id: String { (project?.id ?? "") + "|" + (session ?? "") }
}

/// Edit a grouping: rename a project, or move a session to another project.
struct LogbookEditSheet: View {
    let edit: LogbookEdit
    let logbook: Logbook
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.rename
    @State private var project = ""
    @State private var name = ""
    @State private var session = ""
    @State private var target = ""

    enum Mode: String, CaseIterable, Identifiable {
        case rename = "Rename project", move = "Move session"
        var id: String { rawValue }
    }

    private var projects: [LogbookReport.Project] { logbook.report?.projects ?? [] }

    /// Every session in the report, with the project it is in.
    private var members: [(key: String, project: String?)] {
        guard let report = logbook.report else { return [] }
        return report.projects.flatMap { p in p.sessions.map { ($0.key, Optional(p.id)) } } + report.unassigned.map { ($0, nil) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Change", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch mode {
                case .rename:
                    Picker("Project", selection: $project) {
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }
                    TextField("New name", text: $name)
                case .move:
                    Picker("Session", selection: $session) {
                        ForEach(members, id: \.key) { member in
                            Text(logbook.session(id: member.key)?.label ?? member.key).tag(member.key)
                        }
                    }
                    Picker("To", selection: $target) {
                        ForEach(projects) { Text($0.name).tag($0.id) }
                        Text("Not in a project").tag("")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit grouping")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        switch mode {
                        case .rename: logbook.rename(project: project, to: name)
                        case .move: logbook.move(session: session, to: target.isEmpty ? nil : target)
                        }
                        dismiss()
                    }
                    .disabled(mode == .rename ? project.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty : session.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
        .onAppear {
            project = edit.project?.id ?? projects.first?.id ?? ""
            name = edit.project?.name ?? ""
            session = edit.session ?? members.first?.key ?? ""
            target = projects.first?.id ?? ""
            if edit.session != nil { mode = .move }
        }
        .onChange(of: project) { _, id in name = projects.first { $0.id == id }?.name ?? "" }
    }
}
