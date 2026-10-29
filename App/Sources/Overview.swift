import SwiftUI

/// All windows as live thumbnails (SPEC §5.5). Tap to open; long-press for
/// Rename / Close / New window; the + tile makes a new window.
struct OverviewView: View {
    @Bindable var session: SessionController
    @Environment(\.dismiss) private var dismiss
    @State private var tick = Date()
    @State private var renaming: WindowPage?
    @State private var newName = ""
    @State private var closing: WindowPage?
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    ForEach(session.windows) { page in
                        WindowTile(page: page, isCurrent: page.id == session.currentWindowID,
                                   agent: session.preset(for: page).profile, tick: tick)
                            .onTapGesture {
                                session.currentWindowID = page.id
                                dismiss()
                            }
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") { newName = page.name; renaming = page }
                                Button("New window…", systemImage: "plus") { newWindow() }
                                Button("Close window…", systemImage: "xmark", role: .destructive) { closing = page }
                            }
                    }
                    Button(action: newWindow) {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.title2)
                            Text("New window").font(.footnote)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .foregroundStyle(Theme.accent)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
            }
            .background(Color(Theme.background))
            .navigationTitle("\(session.server.displayName) · \(session.sessionName ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onReceive(refresh) { tick = $0 }
        .alert("Rename window", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") { if let page = renaming { session.renameWindow(page, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Close \(closing?.name ?? "")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button("Close window", role: .destructive) { if let page = closing { session.closeWindow(page) } }
        } message: {
            Text("This kills the window and everything running in it, on the server.")
        }
    }

    private func newWindow() {
        dismiss()
        session.showNewWindow = true
    }
}

struct WindowTile: View {
    let page: WindowPage
    let isCurrent: Bool
    let agent: AgentProfile?
    /// Changes every second so the snapshot is re-read.
    let tick: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let _ = tick
            Text(page.terminal.snapshot(lines: 14).joined(separator: "\n"))
                .font(.system(size: 6.5, design: .monospaced))
                .foregroundStyle(Color(Theme.foreground))
                .lineLimit(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
                .clipped()
            HStack(spacing: 6) {
                if page.hasBell {
                    Circle().fill(.red).frame(width: 7, height: 7)
                } else if page.hasActivity {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                }
                Text(page.name).font(.caption.monospaced().weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let agent { AgentMark(profile: agent, size: 13) }
                Text(page.currentCommand).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.surface)
        }
        .frame(height: 150)
        .background(Color(Theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Theme.accent : Color.white.opacity(0.12), lineWidth: isCurrent ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
