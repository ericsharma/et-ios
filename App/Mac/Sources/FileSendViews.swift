import AppKit
import SwiftUI

/// A session's sends in progress, at the top right of its terminal.
struct TerminalSends: View {
    @Environment(Fleet.self) private var fleet
    let ref: SessionRef

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(fleet.sends(to: ref.machine, session: ref.name)) { send in
                HStack(spacing: 8) {
                    SendProgressBar(send: send).frame(width: 220)
                    Button("Cancel") { fleet.dismiss(send) }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .environment(\.colorScheme, .dark)
    }
}

/// "Sending x", a bar, and bytes done of total.
struct SendProgressBar: View {
    let send: FileSend

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sending \(send.label)").font(.caption).lineLimit(1).truncationMode(.middle)
            if let fraction = send.fraction {
                ProgressView(value: fraction)
                Text("\(bytes(send.done)) of \(bytes(send.total))")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

/// A send to a machine, under it in the sidebar: progress with Cancel, then
/// the paths with Copy, or the error.
struct MachineSendRow: View {
    @Environment(Fleet.self) private var fleet
    let send: FileSend

    var body: some View {
        if let paths = send.paths {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Sent to \(send.machine)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                        fleet.flash(paths.count == 1 ? "Path copied" : "\(paths.count) paths copied")
                    }
                    .controlSize(.small)
                    .help("Copy the paths, one per line")
                    dismissButton
                }
                ForEach(paths, id: \.self) { path in
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            .padding(.vertical, 2)
        } else if let error = send.error {
            HStack(alignment: .top) {
                Text("Sending \(send.label) failed: \(error)").font(.caption).foregroundStyle(.red).lineLimit(3)
                Spacer()
                dismissButton
            }
        } else {
            HStack {
                SendProgressBar(send: send)
                Button("Cancel") { fleet.dismiss(send) }.controlSize(.small)
            }
        }
    }

    private var dismissButton: some View {
        Button { fleet.dismiss(send) } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Hide")
    }
}

/// File → Send File… and drops on the Dock icon: the files waiting in
/// `fleet.pendingSend`, and a machine to send them to.
struct SendFilesWindow: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    @State private var machine = ""

    var body: some View {
        @Bindable var fleet = fleet
        Form {
            Section {
                if fleet.pendingSend.isEmpty {
                    Text("Drop files here, or on the E.T. icon in the Dock.").foregroundStyle(.secondary)
                }
                ForEach(fleet.pendingSend, id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { fleet.pendingSend.removeAll { $0 == url } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add…") { add() }
            } header: {
                Text("Send to ~/etd-downloads")
            }
            Picker("Machine", selection: $machine) {
                ForEach(fleet.machines) { Text(Nicknames.shared.machine($0.name)).tag($0.name) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 260)
        .dropDestination(for: URL.self) { urls, _ in
            fleet.queueSend(urls.filter(\.isFileURL))
            return true
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    fleet.pendingSend = []
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    fleet.send(fleet.pendingSend, to: machine, session: nil)
                    fleet.pendingSend = []
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fleet.pendingSend.isEmpty || machine.isEmpty || fleet.phase != .ready)
            }
        }
        .onAppear {
            if machine.isEmpty { machine = fleet.hubName ?? fleet.machines.first?.name ?? "" }
        }
    }

    private func add() {
        if let urls = SendFilesWindow.pick() { fleet.queueSend(urls) }
    }

    /// A Finder picker for files and folders; nil if cancelled.
    static func pick() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }
}
