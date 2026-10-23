import ETOnboarding
import SwiftUI

/// Onboarding (docs/PLAN-macos.md §4.2–4.3), in the main window until done.
struct SetupView: View {
    @Environment(Setup.self) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up this Mac").font(.largeTitle.bold())
            ForEach(setup.steps, id: \.self) { step in
                Label(step, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            stage
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var stage: some View {
        switch setup.stage {
        case .looking:
            HStack { ProgressView().controlSize(.small); Text("Looking for etd on this Mac…") }
        case .working(let text):
            HStack { ProgressView().controlSize(.small); Text(text) }
        case .needsApproval:
            VStack(alignment: .leading, spacing: 10) {
                Text("Make this Mac a machine").font(.title2.bold())
                Text("E.T. runs etd in the background, so your phone and other machines reach this Mac even when the app is closed. macOS asks you to allow it once: turn on **E.T.** in System Settings → General → Login Items.")
                Button("Open Login Items") { setup.openLoginItems() }
                    .keyboardShortcut(.defaultAction)
                HStack { ProgressView().controlSize(.small); Text("Waiting for approval…").foregroundStyle(.secondary) }
            }
        case .chooseNetwork:
            NetworkChoice()
        case .addPhone:
            AddPhone()
        case .done:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Try Again") { setup.start() }
            }
        }
        if setup.canTakeOver {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("etd was installed with `etd install`. E.T. can run it instead, with the same key and network: no new join.")
                    .foregroundStyle(.secondary)
                Button("Let E.T. Manage etd") { setup.takeOver() }
            }
        }
    }
}

/// §4.3: two large choices side by side, then the form of the chosen one.
struct NetworkChoice: View {
    @Environment(Setup.self) private var setup
    @State private var choice: Choice?

    enum Choice { case start, join }

    var body: some View {
        switch choice {
        case nil:
            HStack(spacing: 16) {
                ChoiceCard(title: "Start a new network",
                           text: "This Mac is the first machine. Add your phone and other machines after.",
                           symbol: "sparkles") { choice = .start }
                ChoiceCard(title: "Join a network",
                           text: "Add this Mac to the network of your other machines.",
                           symbol: "point.3.connected.trianglepath.dotted") { choice = .join }
            }
            .onAppear { if !setup.joinLink.isEmpty { choice = .join } }
        case .start:
            StartNetworkForm { choice = nil }
        case .join:
            JoinNetworkForm { choice = nil }
        }
    }
}

struct ChoiceCard: View {
    let title: String
    let text: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.title)
                Text(title).font(.title3.bold())
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct StartNetworkForm: View {
    @Environment(Setup.self) private var setup
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a new network").font(.title2.bold())
            LabeledContent("Network name") {
                Text(setup.status?.network?.name ?? setup.joinName).font(.body.monospaced())
            }
            Text("etd names a network after its first machine.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back", action: back)
                Button("Create") { setup.startNewNetwork() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct JoinNetworkForm: View {
    @Environment(Setup.self) private var setup
    let back: () -> Void

    var body: some View {
        @Bindable var setup = setup
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a network").font(.title2.bold())
            Text("Paste the link from `etd invite --machine` on one of your machines, or from E.T. on your phone: Network → Invite → Machine.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("et://pair?t=…", text: $setup.joinLink)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                if let link = setup.clipboardLink, link != setup.joinLink {
                    Button("Paste") { setup.receive(link: link) }
                }
            }
            LabeledContent("Name for this Mac") {
                TextField("m1-air", text: $setup.joinName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(maxWidth: 240)
            }
            if !setup.joinName.isEmpty && !Onboarding.isValidMachineName(setup.joinName) {
                Text("Only letters, digits, “.”, “_” and “-”.").font(.caption).foregroundStyle(.red)
            }
            if let error = setup.joinError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Back", action: back).disabled(setup.isJoining)
                Button("Join") { setup.join() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.joinLink.isEmpty || setup.isJoining || !Onboarding.isValidMachineName(setup.joinName))
                if setup.isJoining { ProgressView().controlSize(.small) }
            }
        }
    }
}

/// After Start a new network: the phone's QR code.
struct AddPhone: View {
    @Environment(Setup.self) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your phone").font(.title2.bold())
            Text("Scan with the iPhone camera, or in E.T. → + → Scan QR code.").foregroundStyle(.secondary)
            if let invite = setup.phoneInvite, let qr = NetworkSettings.qrCode(invite) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                Text("Valid 10 minutes, one use.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No invite yet.").foregroundStyle(.secondary)
            }
            HStack {
                Button("New Code") { setup.refreshPhoneInvite() }
                Button("Skip") { setup.finishAddPhone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
