import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Settings (⌘,)

struct SettingsView: View {
    var body: some View {
        TabView {
            NetworkSettings()
                .tabItem { Label("Network", systemImage: "network") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }
}

struct NetworkSettings: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Setup.self) private var setup
    @State private var invite: String?
    @State private var inviteError: String?
    @State private var confirmingUnpair = false

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Machine name", value: setup.status?.machineName ?? fleet.hub?.name ?? "—")
                LabeledContent("etd", value: setup.status.map { "\($0.version ?? "?"), managed by \(setup.manager?.label ?? "?")" } ?? "—")
                LabeledContent("Login item", value: Setup.describe(Setup.agent.status))
                if fleet.hub != nil {
                    Button("Unpair E.T.…", role: .destructive) { confirmingUnpair = true }
                }
            }
            if let network = fleet.network {
                Section("Network \(network.name)") {
                    ForEach(network.members) { member in
                        Label(member.name, systemImage: member.isMachine ? "desktopcomputer" : "iphone")
                    }
                }
            }
            Section("Invite") {
                HStack {
                    Button("Invite a Phone or Mac") { makeInvite(machine: false) }
                    Button("Invite a Machine") { makeInvite(machine: true) }
                }
                .disabled(fleet.phase != .ready)
                if let invite {
                    HStack(alignment: .top, spacing: 12) {
                        if let qr = Self.qrCode(invite) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(invite).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(invite, forType: .string)
                            }
                            Text("One use, valid 10 minutes. A machine: `etd join <link>` there.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let inviteError { Text(inviteError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task { await fleet.reloadNetwork() }
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmingUnpair) {
            Button("Unpair", role: .destructive) {
                fleet.unpair()
                setup.start()
            }
        } message: {
            Text("E.T. forgets its pairing and pairs again at the next start. etd and manymux keep running.")
        }
    }

    private func makeInvite(machine: Bool) {
        inviteError = nil
        Task {
            do { invite = try await fleet.invite(machine: machine) } catch { inviteError = Fleet.describe(error) }
        }
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("E.T. for Mac").font(.title2.bold())
            Text(AppInfo.buildLabel).font(.caption.monospaced()).textSelection(.enabled)
            Text("Your manymux sessions on every machine, over etd.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
