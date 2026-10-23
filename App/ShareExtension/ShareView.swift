import SwiftUI

/// The share sheet: the files, a machine, then optionally a session.
struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send to a machine")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.phase == .queued ? "Done" : "Cancel") { model.close() }
                    }
                    if model.phase == .picking {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") { model.send() }
                                .disabled(model.machine == nil || model.files.isEmpty)
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading…")
        case .picking:
            picker
        case .sending:
            VStack(spacing: 12) {
                Text("Sending \(model.label) to \(model.machine?.name ?? "")…")
                if let fraction = model.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .padding(32)
        case .sent(let paths):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text(model.session == nil ? "Sent" : "Sent, path typed into \(model.session ?? "")")
                Text(paths).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
        case .queued:
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.up.fill").font(.largeTitle).foregroundStyle(.tint)
                Text("Open E.T. to finish sending")
                    .font(.headline)
                Text("\(model.label) (\(bytes(model.totalBytes))) is too big to send from the share sheet. E.T. sends it to \(model.machine?.name ?? "the machine") when you open it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") { model.send() }
            }
            .padding(32)
        }
    }

    private var picker: some View {
        List {
            Section {
                ForEach(model.files, id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                }
                if model.skipped > 0 {
                    Text("\(model.skipped) item(s) aren't files and are skipped.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("\(model.label) · \(bytes(model.totalBytes))")
            } footer: {
                if model.isLarge {
                    Text("Large: E.T. sends it when you next open the app.")
                }
            }

            Section("Machine") {
                if model.machines.isEmpty {
                    Text("Open E.T. once and connect, so it can list your machines here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.machines) { machine in
                    choice(machine.name, selected: model.machine == machine) { model.machine = machine }
                }
            }

            if let machine = model.machine {
                Section {
                    choice("No session", detail: "Only ~/etd-downloads", selected: model.session == nil) { model.session = nil }
                    ForEach(model.sessions, id: \.name) { session in
                        choice(session.name, detail: session.title.isEmpty ? nil : session.title,
                               selected: model.session == session.name) { model.session = session.name }
                    }
                } header: {
                    HStack {
                        Text("Session on \(machine.name)")
                        if model.connecting { ProgressView().controlSize(.mini) }
                    }
                } footer: {
                    if let error = model.connectError {
                        Text(error).foregroundStyle(.orange)
                    } else {
                        Text("In a session, the path is typed at the prompt (no Enter).")
                    }
                }
            }
        }
    }

    private func choice(_ title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
