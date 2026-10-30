import EtLink
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
    let renameOnMachine: (SessionRef) -> Void
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
            // Touching the toolbar, the scroll view grows up under it while
            // its document view doesn't, so the tabs drew outside the
            // document view and clicks never reached them.
            .padding(.top, 1)
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
                Text(Nicknames.shared.machine(ref.machine)).font(.caption2).foregroundStyle(.secondary)
                if let agent = AgentProfile.matching(command: info.command, name: info.name, title: info.title) {
                    AgentMark(profile: agent, size: 13)
                }
                Text(Nicknames.shared.session(machine: ref.machine, name: ref.name)).font(.caption.monospaced())
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
            Button("Rename on Machine…") { renameOnMachine(ref) }
            Divider()
            Button("End Session…", role: .destructive) { end(ref) }
        }
    }
}

/// Under the terminal, styled like the iOS key row: Upload on the left, a
/// big mic in the middle (on-device dictation), Paste and Send (Enter) on
/// the right. While listening, the live text floats above the bar.
struct InputBar: View {
    @Environment(Fleet.self) private var fleet
    let terminal: SessionTerminal
    let voice: VoiceInput

    /// Both sides have the same width, so the mic stays centered.
    private let sideWidth: CGFloat = 148

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                barButton(systemName: "photo") { pickFiles() }
                    .help("Send files to \(terminal.ref.machine) and type their paths (⇧⌘U)")
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            .frame(width: sideWidth, alignment: .leading)
            Spacer(minLength: 4)
            micButton
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                barButton(systemName: "doc.on.clipboard") {
                    terminal.view.paste(terminal.view)
                    terminal.focus()
                }
                .help("Paste")
                Button {
                    terminal.send([0x0D])
                    terminal.focus()
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 40)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Send (Enter)")
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
        .focusable(false)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(nsColor: Theme.background))
        .environment(\.colorScheme, .dark)
        .disabled(!terminal.isAttached)
    }

    private func barButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 40)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var micButton: some View {
        let listening = voice.state == .listening
        return Button { Task { await Self.toggle(terminal: terminal, voice: voice, fleet: fleet) } } label: {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(listening ? .white : Color(nsColor: Theme.background))
                .frame(width: 60, height: 60)
                .background(listening ? Color.red : Theme.accent, in: Circle())
                .symbolEffect(.pulse, isActive: listening)
                .shadow(color: (listening ? Color.red : Theme.accent).opacity(0.4), radius: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(voice.state == .stopping)
        .help(listening ? "Stop and type what you said (⇧⌘D)" : "Dictate into the terminal (⇧⌘D)")
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }

    /// Tap to start, tap to stop; the text is typed into the session
    /// without Return, so it can be edited before sending.
    static func toggle(terminal: SessionTerminal, voice: VoiceInput, fleet: Fleet) async {
        switch voice.state {
        case .idle:
            await voice.start(contextualStrings: contextualStrings(fleet))
        case .listening:
            let text = await voice.stop()
            fleet.log.add("Dictated \(text.count) characters into \(terminal.ref.id)")
            if !text.isEmpty { terminal.send(Array(text.utf8)) }
            terminal.focus()
        case .stopping:
            break
        }
    }

    private static func contextualStrings(_ fleet: Fleet) -> [String] {
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
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Send to ~/etd-downloads on \(terminal.ref.machine): the paths are typed into \(terminal.ref.name)."
        panel.prompt = "Send"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, !panel.urls.isEmpty { terminal.sendFiles(panel.urls) }
            terminal.focus()
        }
        if let window = terminal.view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

/// Live transcription over the bottom of the terminal while dictating, as on
/// iOS; an error from the mic shows in the same place.
struct ListeningBubble: View {
    @Environment(Fleet.self) private var fleet
    let terminal: SessionTerminal
    let voice: VoiceInput

    var body: some View {
        Group {
            if voice.state != .idle {
                bubble
            } else if let error = voice.error {
                Text(error)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { voice.error = nil }
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .animation(.snappy, value: voice.state)
    }

    /// Live transcription, as on iOS. Click to stop.
    private var bubble: some View {
        Button { Task { await InputBar.toggle(terminal: terminal, voice: voice, fleet: fleet) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(.red).symbolEffect(.variableColor, isActive: true)
                Text(voice.text.isEmpty ? "Listening…" : voice.text)
                    .font(.callout)
                    .foregroundStyle(voice.text.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .truncationMode(.head) // long dictation: show the latest words
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Click to stop").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 640)
        .padding(.horizontal, 12)
    }

}
