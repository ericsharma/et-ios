import AppKit
import ETCore
import SwiftUI

/// Every session on every machine as a row of tabs above the terminal, as
/// on the iPad: machine name, then session name; a red dot for a bell.
struct SessionTabs: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: SessionRef?
    let newSession: () -> Void
    let rename: (SessionRef) -> Void
    let end: (SessionRef) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(fleet.machines) { machine in
                        ForEach(machine.sessions) { info in
                            tab(SessionRef(machine: machine.name, name: info.name), info: info)
                        }
                    }
                    Button(action: newSession) {
                        Image(systemName: "plus").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.3)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("New Session (⌘T)")
                    .disabled(fleet.phase != .ready)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .onChange(of: selection) { _, ref in
                if let ref { withAnimation { proxy.scrollTo(ref, anchor: .center) } }
            }
        }
        .background(.bar)
    }

    private func tab(_ ref: SessionRef, info: MmSessionInfo) -> some View {
        let selected = ref == selection
        return Button { selection = ref } label: {
            HStack(spacing: 4) {
                if info.bells > 0 {
                    Circle().fill(Theme.bell).frame(width: 6, height: 6)
                }
                Text(ref.machine).font(.caption2).foregroundStyle(.secondary)
                Text(ref.name).font(.caption.monospaced())
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Theme.accent.opacity(0.25) : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(selected ? Theme.accent : Color.secondary.opacity(0.3)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(info.title.isEmpty ? ref.id : "\(ref.id): \(info.title)")
        .id(ref)
        .contextMenu {
            Button("Open in New Window") { openWindow(value: ref) }
            Button("Rename…") { rename(ref) }
            Divider()
            Button("End Session…", role: .destructive) { end(ref) }
        }
    }
}

/// Under the terminal: dictation (on-device speech) and file upload.
struct InputBar: View {
    @Environment(Fleet.self) private var fleet
    let terminal: SessionTerminal
    let voice: VoiceInput

    var body: some View {
        VStack(spacing: 0) {
            if voice.state != .idle {
                listening
            }
            HStack(spacing: 8) {
                Button { pickFiles() } label: { Label("Upload", systemImage: "paperclip") }
                    .help("Upload files to \(terminal.ref.machine) and type their paths (⇧⌘U)")
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Spacer()
                if let error = voice.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                micButton
            }
            .focusable(false)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(.bar)
        .disabled(!terminal.isAttached)
    }

    private var micButton: some View {
        let listening = voice.state == .listening
        return Button { Task { await toggle() } } label: {
            Label(listening ? "Stop" : "Dictate", systemImage: listening ? "stop.fill" : "mic.fill")
                .symbolEffect(.pulse, isActive: listening)
        }
        .tint(listening ? .red : Theme.accent)
        .buttonStyle(.borderedProminent)
        .disabled(voice.state == .stopping)
        .help(listening ? "Stop and type what you said (⇧⌘D)" : "Dictate into the terminal (⇧⌘D)")
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }

    private var listening: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(.red).symbolEffect(.variableColor, isActive: true)
            Text(voice.text.isEmpty ? "Listening…" : voice.text)
                .foregroundStyle(voice.text.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .truncationMode(.head) // long dictation: show the latest words
                .frame(maxWidth: .infinity, alignment: .leading)
            if voice.state == .stopping { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Tap to start, tap to stop; the text is typed into the session
    /// without Return, so it can be edited before sending.
    private func toggle() async {
        switch voice.state {
        case .idle:
            await voice.start(contextualStrings: contextualStrings)
        case .listening:
            let text = await voice.stop()
            fleet.log.add("Dictated \(text.count) characters into \(terminal.ref.id)")
            if !text.isEmpty { terminal.send(Array(text.utf8)) }
            terminal.focus()
        case .stopping:
            break
        }
    }

    private var contextualStrings: [String] {
        var names = ["claude", "tmux", "git", "ssh"]
        for machine in fleet.machines {
            names.append(machine.name)
            names += machine.sessions.map(\.name)
        }
        return Array(Set(names))
    }

    /// A Finder file picker: any files, several at once.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Upload to \(terminal.ref.machine): the paths are typed into \(terminal.ref.name)."
        panel.prompt = "Upload"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, !panel.urls.isEmpty { terminal.upload(panel.urls) }
            terminal.focus()
        }
        if let window = terminal.view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
