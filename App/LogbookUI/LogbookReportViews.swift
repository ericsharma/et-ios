import SwiftUI

// MARK: - Report

/// The watcher's report: Refresh, the suggestions, then a card per project.
struct LogbookReportView: View {
    let logbook: Logbook
    let machines: [MmMachine]
    let openSession: (LogbookKey) -> Void
    @State private var editing: LogbookEdit?
    @State private var sending: LogbookSendTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = logbook.reportError {
                    Label("Refresh failed: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let report = logbook.report {
                    if !report.proposals.isEmpty { proposals(report) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(report.projects) { project in
                            ProjectCard(project: project, logbook: logbook, openSession: openSession,
                                        send: { sending = LogbookSendTarget(selection: .reportSection(reportId: report.id, projectId: project.id),
                                                                            title: "the report on \(project.name)") },
                                        edit: { editing = LogbookEdit(project: project, session: nil) })
                        }
                    }
                    if !report.unassigned.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Not in a project").font(.headline)
                            ForEach(report.unassigned, id: \.self) { key in
                                memberRow(key: key, role: nil)
                            }
                        }
                    }
                } else if logbook.run == nil {
                    ContentUnavailableView("No report yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Refresh reads every session and groups them by goal. It takes 1–3 minutes."))
                }
            }
            .padding(16)
        }
        .sheet(item: $sending) { target in
            LogbookSendSheet(target: target, machines: machines, logbook: logbook)
        }
        .sheet(item: $editing) { edit in
            LogbookEditSheet(edit: edit, logbook: logbook)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Report").font(.title2.weight(.semibold))
                if let report = logbook.report {
                    Text("Made \(report.takenDate.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let run = logbook.run {
                VStack(alignment: .trailing, spacing: 2) {
                    if let fraction = run.fraction {
                        ProgressView(value: fraction).frame(width: 160)
                    } else {
                        ProgressView().progressViewStyle(.linear).frame(width: 160)
                    }
                    Text(run.total > 0 ? "\(run.stage) \(run.done)/\(run.total)" : run.stage)
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Button {
                logbook.refreshReport()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(logbook.run != nil)
            .help("Read every session again and make a new report (1–3 min)")
        }
    }

    private func proposals(_ report: LogbookReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(report.proposals.count) suggestion\(report.proposals.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.orange)
            ForEach(report.proposals, id: \.self) { proposal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(proposal.kind.capitalized).font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                        Text(proposal.detail).fontWeight(.medium)
                    }
                    Text(proposal.why).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Accept") { logbook.accept(proposal) }.buttonStyle(.borderedProminent)
                        Button("Reject") { logbook.reject(proposal) }
                        Button("Edit…") { editing = LogbookEdit(project: report.projects.first, session: nil) }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder private func memberRow(key: String, role: String?) -> some View {
        if let session = logbook.session(id: key) {
            Button { openSession(session.key) } label: { LogbookSessionRow(session: session, role: role) }
                .buttonStyle(.plain)
        } else {
            Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

/// A project: goal, its sessions with their roles, progress, next steps.
struct ProjectCard: View {
    let project: LogbookReport.Project
    let logbook: Logbook
    let openSession: (LogbookKey) -> Void
    /// Send to session (L4); nil hides it.
    let send: (() -> Void)?
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name).font(.headline)
                Text(project.status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(statusColor)
                Spacer()
                Menu {
                    if let send { Button("Send to session…", systemImage: "paperplane", action: send) }
                    Button("Rename or move sessions…", systemImage: "pencil", action: edit)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text(project.goal).font(.callout)
            if !project.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(project.sessions, id: \.key) { member in
                        if let session = logbook.session(id: member.key) {
                            Button { openSession(session.key) } label: { LogbookSessionRow(session: session, role: member.role) }
                                .buttonStyle(.plain)
                        } else {
                            VStack(alignment: .leading) {
                                Text(member.key).font(.caption.monospaced())
                                Text(member.role).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            section("Progress") { Text(project.progress).font(.callout) }
            if !project.next.isEmpty {
                section("Next") {
                    ForEach(Array(project.next.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step)").font(.callout)
                    }
                }
            }
            if let send {
                Button(action: send) { Label("Send to session…", systemImage: "paperplane") }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch project.status {
        case "blocked": .red
        case "done": .secondary
        default: .green
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

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
        }
        .onChange(of: project) { _, id in name = projects.first { $0.id == id }?.name ?? "" }
    }
}
