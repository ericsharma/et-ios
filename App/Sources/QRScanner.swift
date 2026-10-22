import AVFoundation
import SwiftUI
import UIKit

/// Scans for an `et://pair` QR code (from `etd pair`) and hands the link to
/// the model, which shows the confirm sheet. Shown as the start screen when
/// no server is saved, and from + → Scan QR code.
struct PairScannerView: View {
    @Environment(AppModel.self) private var model
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    /// The last code read that isn't a pairing link.
    @State private var notPairing = false

    var body: some View {
        ZStack {
            switch access {
            case .authorized:
                // Paused while the confirm sheet is up, so it doesn't re-read the code.
                QRCameraView(paused: model.pendingPairing != nil || model.pairingStatus != nil) { text in
                    if text.lowercased().hasPrefix("et://pair") {
                        notPairing = false
                        model.receivePairingLink(text)
                    } else {
                        notPairing = true
                    }
                }
                .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.8), lineWidth: 3)
                    .frame(width: 240, height: 240)
            case .notDetermined:
                ProgressView()
            default:
                VStack(spacing: 12) {
                    Text("E.T. needs the camera to scan the pairing QR code.")
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                .padding()
            }
        }
        .overlay(alignment: .top) {
            Text(notPairing ? "That QR code isn't an E.T. pairing code." : "Run `etd pair` on the machine and point the camera at its QR code.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}

/// The camera preview with a QR metadata reader. Reports each new code once.
struct QRCameraView: UIViewRepresentable {
    var paused: Bool
    let onCode: @MainActor (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.onCode = onCode
        view.start()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onCode = onCode
        view.setPaused(paused)
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.stop()
    }

    final class PreviewView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var onCode: (@MainActor (String) -> Void)?
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "et.qr")
        private var paused = false
        private var lastCode: String?

        func start() {
            let layer = layer as! AVCaptureVideoPreviewLayer
            layer.session = session
            layer.videoGravity = .resizeAspectFill
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let session = session
            queue.async { session.startRunning() }
        }

        func stop() {
            let session = session
            queue.async { session.stopRunning() }
        }

        func setPaused(_ paused: Bool) {
            // After the sheet closes, the same code may be scanned again.
            if self.paused && !paused { lastCode = nil }
            self.paused = paused
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            let codes = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated {
                guard !paused, let code = codes.first, code != lastCode else { return }
                lastCode = code
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode?(code)
            }
        }
    }
}
