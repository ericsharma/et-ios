import ETCore
import ETSSH
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session {
            SessionView(session: session)
        } else {
            NavigationStack { ServerListView() }
        }
    }
}

// MARK: - Servers

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ServerConfig?
    @State private var adding = false

    var body: some View {
        List {
            if model.servers.isEmpty {
                Section {
                    Text("Add the server that runs tmux. E.T. connects over SSH with its own key.")
                        .foregroundStyle(.secondary)
                    Button("Add server") { adding = true }
                }
            }
            Section("Servers") {
                ForEach(model.servers) { server in
                    Button { model.connect(server) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName).font(.headline)
                            Text("\(server.user)@\(server.host):\(server.port)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Edit") { editing = server }
                        Button("Delete", role: .destructive) { model.delete(server) }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.delete(server) }
                        Button("Edit") { editing = server }
                    }
                }
            }
            Section {
                NavigationLink("This device's key") { KeyView() }
                NavigationLink("Debug log") { DebugLogView() }
            }
        }
        .navigationTitle("E.T.")
        .toolbar {
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { ServerEditView(server: nil) }
        }
        .sheet(item: $editing) { server in
            NavigationStack { ServerEditView(server: server) }
        }
    }
}

struct ServerEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var tmuxPath = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Host or IP (e.g. trigkey)", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("User", text: $user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("Name (optional)", text: $name)
            }
            Section {
                TextField("tmux path (found automatically)", text: $tmuxPath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: { Text("Advanced") }
            Section {
                KeyBox()
            } header: {
                Text("Add this key on the server")
            } footer: {
                Text("Append it to ~/.ssh/authorized_keys for this user on the server.")
            }
        }
        .navigationTitle(server == nil ? "Add server" : "Edit server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty || Int(port) == nil)
            }
        }
        .onAppear {
            guard let server else { return }
            name = server.name
            host = server.host
            port = String(server.port)
            user = server.user
            tmuxPath = server.tmuxPath ?? ""
        }
    }

    private func save() {
        var updated = server ?? ServerConfig(host: "", user: "")
        let newHost = host.trimmingCharacters(in: .whitespaces)
        let newPort = Int(port) ?? 22
        // A different address is a different machine: forget the pinned key.
        if updated.host != newHost || updated.port != newPort { updated.hostKey = nil }
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.host = newHost
        updated.port = newPort
        updated.user = user.trimmingCharacters(in: .whitespaces)
        updated.tmuxPath = tmuxPath.isEmpty ? nil : tmuxPath
        model.save(updated)
        dismiss()
    }
}

struct KeyBox: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        if let error = model.identityError {
            Text("Key error: \(error)").foregroundStyle(.red)
        } else {
            Text(model.publicKey)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            HStack {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = model.publicKey
                    copied = true
                }
                Spacer()
                ShareLink(item: model.publicKey)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct KeyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                KeyBox()
            } footer: {
                Text(model.identity?.isHardwareBacked == true
                     ? "Stored in this iPhone's Secure Enclave. It can't be copied off the device. One key for all servers."
                     : "Software key (no Secure Enclave available).")
            }
        }
        .navigationTitle("This device's key")
    }
}

struct DebugLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(model.log.lines.enumerated()), id: \.offset) { item in
                Text(item.element).font(.caption2.monospaced()).id(item.offset)
            }
            .listStyle(.plain)
            .onAppear { proxy.scrollTo(model.log.lines.count - 1, anchor: .bottom) }
        }
        .navigationTitle("Debug log")
        .toolbar { ShareLink(item: model.log.text) }
    }
}

// MARK: - Session

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: SessionController
    @State private var showLog = false
    @State private var newSessionName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(Theme.background))
        .alert("Trust this server?", isPresented: .constant(session.pendingHostKey != nil), presenting: session.pendingHostKey) { _ in
            Button("Trust") { session.answerHostKey(trust: true) }
            Button("Cancel", role: .cancel) { session.answerHostKey(trust: false) }
        } message: { key in
            Text("First connection to \(session.server.host).\n\n\(key.algorithm)\n\(key.fingerprint)\n\nCheck it on the server with: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
        }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                DebugLogView().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { showLog = false } }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(session.server.displayName + (session.sessionName.map { " · \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if case .restoring(let done, let total) = session.state {
                    Text("Restoring \(done)/\(total)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Debug log") { showLog = true }
                    if session.isDisconnected {
                        Button("Reconnect") { model.connect(session.server) }
                    }
                    Button("Servers", role: .destructive) { model.closeSession() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            .padding(.horizontal, 12)
            if !session.windows.isEmpty {
                WindowTabs(session: session)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Theme.surface)
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .connecting(let message):
            if let url = session.approvalURL {
                ApprovalView(host: session.server.displayName, banner: session.authBanner ?? "", url: url)
            } else {
                centered { ProgressView(); Text(message).foregroundStyle(.secondary) }
            }
        case .failed(let message):
            centered {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.active)
                Text(message).multilineTextAlignment(.center)
                Button("Retry") { model.connect(session.server) }.buttonStyle(.borderedProminent)
                Button("Debug log") { showLog = true }
            }
        case .choosingSession(let sessions):
            List {
                Section("Sessions on \(session.server.displayName)") {
                    ForEach(sessions) { info in
                        Button { session.chooseSession(info.name) } label: {
                            HStack {
                                Text(info.name).font(.body.monospaced())
                                Spacer()
                                Text("\(info.windowCount) windows\(info.attachedClients > 0 ? " · attached" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("New session") {
                    TextField("Name", text: $newSessionName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Create") { session.chooseSession(newSessionName, create: true) }
                        .disabled(newSessionName.isEmpty)
                }
            }
        case .connected, .restoring, .disconnected:
            WindowPager(session: session)
                .overlay {
                    if session.state == .disconnected {
                        Color.black.opacity(0.3).overlay {
                            Button("Reconnect") { model.connect(session.server) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16, content: content)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .failed: .red
        case .disconnected: .gray
        default: .orange
        }
    }
}

struct WindowTabs: View {
    @Bindable var session: SessionController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.windows) { page in
                        let selected = page.id == session.currentWindowID
                        Button { session.currentWindowID = page.id } label: {
                            HStack(spacing: 4) {
                                if page.hasBell {
                                    Circle().fill(.red).frame(width: 6, height: 6)
                                } else if page.hasActivity {
                                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                }
                                Text(page.name).font(.caption.monospaced())
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(selected ? Theme.accent.opacity(0.25) : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(selected ? Theme.accent : Color.secondary.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .id(page.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: session.currentWindowID) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct WindowPager: View {
    @Bindable var session: SessionController

    var body: some View {
        TabView(selection: $session.currentWindowID) {
            ForEach(session.windows) { page in
                TerminalPane(host: page.terminal)
                    .tag(Optional(page.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: session.currentWindowID) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

/// Shown while the server holds the login for approval, as Tailscale SSH
/// does in "check" mode. The login continues by itself once approved.
struct ApprovalView: View {
    let host: String
    let banner: String
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.badge.shield.checkmark").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Approve this login").font(.title3.weight(.semibold))
            Text("\(host) wants you to confirm it's you before the connection continues.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                openURL(url)
            } label: {
                Label("Approve in browser", systemImage: "safari").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for approval. Come back here when you're done.").font(.footnote).foregroundStyle(.secondary)
            }
            if !banner.isEmpty {
                Text(banner).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
        .padding(28)
        .frame(maxWidth: 480, maxHeight: .infinity)
    }
}
