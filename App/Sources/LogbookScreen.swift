import SwiftUI

/// ⋯ → Logbook (PLAN-logbook-v2 B4): the Mac's Logbook window. An iPad
/// shows its 3 columns; an iPhone a stack, places → cards → transcript.
struct LogbookScreen: View {
    let session: SessionController
    let done: () -> Void
    @State private var logbook: Logbook

    init(session: SessionController, done: @escaping () -> Void) {
        self.session = session
        self.done = done
        _logbook = State(initialValue: Logbook(archive: { session.archiveHost() }, hosts: { session.directHosts() }, log: { session.log.add($0) }))
    }

    var body: some View {
        LogbookWindow(logbook: logbook, machines: session.machines, showTerminal: { entry in
            session.openMm(machine: entry.key.machine, name: entry.mmSession)
            done()
        }, done: done)
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
}
