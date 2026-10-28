import SwiftUI

/// ⋯ → Logbook (PLAN-logbook §4.6): the projects (or repos before the
/// first report) with their Claude sessions → a session's live transcript;
/// the report; Send to session. The views are the Mac's (App/LogbookUI).
struct LogbookScreen: View {
    let session: SessionController
    let done: () -> Void
    @State private var logbook: Logbook
    @State private var path: [LogbookRoute] = []

    enum LogbookRoute: Hashable {
        case session(LogbookKey)
        case report
    }

    init(session: SessionController, done: @escaping () -> Void) {
        self.session = session
        self.done = done
        _logbook = State(initialValue: Logbook(archive: { session.archiveHost() }, log: { session.log.add($0) }))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: LogbookRoute.report) { reportRow }
                }
                if let error = logbook.error, logbook.sessions.isEmpty {
                    Text(error).foregroundStyle(.secondary)
                } else if logbook.loaded && logbook.groups.isEmpty {
                    Text("No Claude sessions yet").foregroundStyle(.secondary)
                }
                ForEach(logbook.groups) { group in
                    Section {
                        ForEach(group.sessions) { entry in
                            NavigationLink(value: LogbookRoute.session(entry.key)) {
                                LogbookSessionRow(session: entry, role: group.project?.sessions.first { $0.key == entry.id }?.role)
                            }
                            .swipeActions {
                                if !entry.mmSession.isEmpty {
                                    Button(entry.paused ? "Record" : "Do not record") { logbook.setPaused(entry, !entry.paused) }
                                        .tint(.orange)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            if group.live > 0 { Text("●\(group.live)").foregroundStyle(group.busy > 0 ? .green : .secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Logbook")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: LogbookRoute.self) { route in
                switch route {
                case .session(let key):
                    LogbookTranscriptView(key: key, logbook: logbook, machines: session.machines)
                        .navigationTitle(logbook.session(key)?.label ?? key.id)
                        .navigationBarTitleDisplayMode(.inline)
                case .report:
                    LogbookReportView(logbook: logbook, machines: session.machines) { key in
                        path.append(.session(key))
                    }
                    .navigationTitle("Report")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
            .refreshable { await logbook.reload() }
        }
        .overlay(alignment: .bottom) {
            if let notice = logbook.notice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if logbook.notice == notice { logbook.notice = nil }
                    }
            }
        }
        .task { await logbook.watch() }
    }

    private var reportRow: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let report = logbook.report {
                        Text("Report (\(report.takenDate.formatted(.relative(presentation: .named))))")
                        if !report.proposals.isEmpty {
                            Text("⚠ \(report.proposals.count) suggestion\(report.proposals.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("Report")
                    }
                }
            } icon: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            Spacer()
            if logbook.run != nil { ProgressView() }
        }
    }
}
