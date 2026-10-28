import SwiftUI

// MARK: - Send to session

/// What a Send to session sheet sends, and how to name it.
struct LogbookSendTarget: Identifiable {
    var selection: LogbookSelection
    var title: String
    var id: String { title }
}

/// Picks a session on any machine (the Shared Files picker's rows).
struct LogbookSendSheet: View {
    let target: LogbookSendTarget
    let machines: [MmMachine]
    let logbook: Logbook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text("A Markdown file goes to the session's machine. Its path is typed into the session, without Enter.")
                    .font(.caption).foregroundStyle(.secondary)
                SessionPickerRows(machines: machines) { machine, session in
                    logbook.send(target.selection, to: machine, session: session)
                    dismiss()
                }
            }
            .navigationTitle("Send \(target.title) to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}
