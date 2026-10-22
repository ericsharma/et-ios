import CoreImage.CIFilterBuiltins
import SwiftUI

/// The etd network (PLAN-network §4.7): every machine and device, and
/// invites. Only machines may revoke (D1), so there is no Revoke here.
struct NetworkView: View {
    @Bindable var session: SessionController
    @State private var invite: Invite?
    @State private var inviting = false
    @State private var error: String?

    struct Invite: Identifiable {
        let machine: Bool
        let url: String
        var id: String { url }
    }

    var body: some View {
        List {
            if let network = session.network {
                Section("Machines") {
                    ForEach(network.members.filter(\.isMachine)) { member in
                        MemberRow(member: member, isHub: member.endpointId == session.server.irohEndpointId)
                    }
                }
                Section {
                    ForEach(network.members.filter { !$0.isMachine }) { member in
                        MemberRow(member: member, isHub: false)
                    }
                } header: {
                    Text("Phones and tablets")
                } footer: {
                    Text("To remove a device, run `etd revoke <name>` on a machine.")
                }
            } else if let networkError = session.networkError {
                Section { Text(networkError).font(.footnote).foregroundStyle(.red) }
            } else {
                Section { ProgressView() }
            }
            Section {
                Button("Add a phone or tablet", systemImage: "iphone") { makeInvite(machine: false) }
                Button("Add a machine", systemImage: "desktopcomputer") { makeInvite(machine: true) }
                if inviting { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("An invite is valid 10 minutes, once. Every member can run commands on every machine.")
            }
        }
        .navigationTitle(session.network?.name ?? "Network")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.reloadNetwork() }
        .task { await session.reloadNetwork() }
        .sheet(item: $invite) { invite in
            NavigationStack { InviteView(invite: invite) }
        }
    }

    private func makeInvite(machine: Bool) {
        guard !inviting else { return }
        inviting = true
        error = nil
        Task {
            defer { inviting = false }
            do {
                invite = Invite(machine: machine, url: try await session.invite(machine: machine))
            } catch {
                self.error = "Couldn't make an invite: \(SessionController.describeMm(error))"
            }
        }
    }
}

private struct MemberRow: View {
    let member: NetMember
    let isHub: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(member.name + (isHub ? " (connected)" : ""))
            Text(member.endpointId.prefix(16) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// A device invite as a QR code (scan it with E.T. on the new device), or
/// a machine invite as the `etd join` command.
private struct InviteView: View {
    let invite: NetworkView.Invite
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if invite.machine {
                    Text("Run this on the new machine:")
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = command
                        copied = true
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Scan this with the Camera app on the new phone or tablet (E.T. installed there).")
                        .multilineTextAlignment(.center)
                    if let image = Self.qrCode(invite.url) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .padding(12)
                            .background(.white, in: .rect(cornerRadius: 8))
                    }
                    ShareLink(item: invite.url) { Label("Share link", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }
                Text("Valid 10 minutes, once.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(invite.machine ? "Add a machine" : "Add a phone or tablet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private var command: String { "etd join '\(invite.url)'" }

    static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
