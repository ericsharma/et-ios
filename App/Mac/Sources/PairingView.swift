import CoreImage.CIFilterBuiltins
import SwiftUI

/// First run: paste an `et://pair` link from `etd invite`.
struct PairingView: View {
    @Environment(Fleet.self) private var fleet
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair this Mac").font(.largeTitle.bold())
            Text("E.T. reaches your machines through etd. On any machine in your etd network, run:")
            Text("etd invite")
                .font(.body.monospaced())
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
            Text("Then paste the et://pair link here (or open it on this Mac).")
            HStack {
                TextField("et://pair?t=…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { pair() }
                Button("Pair") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let status = fleet.pairingStatus, fleet.pendingPairing == nil {
                Text(status).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 520)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pair() {
        fleet.receivePairingLink(link)
    }
}

struct ConfirmPairingSheet: View {
    @Environment(Fleet.self) private var fleet
    let pending: PendingPairing

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with \(pending.ticket.hostName)?").font(.title2.bold())
            Text("This Mac joins your etd network and can open sessions on every machine in it.")
                .foregroundStyle(.secondary)
            Text("Machine ID \(pending.ticket.endpointId.prefix(16))…")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let status = fleet.pairingStatus {
                HStack {
                    if fleet.isPairing { ProgressView().controlSize(.small) }
                    Text(status)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { fleet.cancelPairing() }
                Button("Pair") { fleet.confirmPairing() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fleet.isPairing)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

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
    @State private var invite: String?
    @State private var inviteError: String?
    @State private var confirmingUnpair = false

    var body: some View {
        Form {
            Section("Hub") {
                LabeledContent("Connected through", value: fleet.hub?.name ?? "Not paired")
                if fleet.hub != nil {
                    Button("Unpair…", role: .destructive) { confirmingUnpair = true }
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
            Button("Unpair", role: .destructive) { fleet.unpair() }
        } message: {
            Text("E.T. forgets the hub. To remove this Mac from the network too, run `etd revoke` on a machine.")
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
