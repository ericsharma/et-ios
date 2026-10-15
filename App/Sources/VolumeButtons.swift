import AVFoundation
import MediaPlayer
import SwiftUI

/// Uses the volume buttons as input while select mode is open.
///
/// iOS has no API for this (outside the camera), so it uses the common
/// workaround: watch the system volume, treat each change as a press, and
/// put the volume straight back. The volume is parked in the middle so
/// both buttons always register, and restored afterwards. A hidden
/// MPVolumeView in the view hierarchy suppresses the system volume HUD.
@MainActor
final class VolumeButtons {
    /// true = volume up, false = volume down.
    var onPress: ((Bool) -> Void)?

    private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
    private var observation: NSKeyValueObservation?
    private var originalVolume: Float?
    private var expected: Float = 0.5
    private static let parked: Float = 0.5

    /// The hidden view that must be on screen to suppress the HUD.
    var hiddenVolumeView: UIView { volumeView }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: .mixWithOthers)
        try? session.setActive(true)
        originalVolume = session.outputVolume
        setVolume(Self.parked)
        observation = session.observe(\.outputVolume, options: [.new], changeHandler: Self.handler { [weak self] volume in
            Task { @MainActor in self?.changed(to: volume) }
        })
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        if let originalVolume { setVolume(originalVolume) }
        originalVolume = nil
    }

    private func changed(to volume: Float) {
        // Our own reset also changes the volume; ignore it.
        guard abs(volume - expected) > 0.001 else { return }
        onPress?(volume > expected)
        setVolume(Self.parked)
    }

    private func setVolume(_ value: Float) {
        expected = value
        let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        // The slider exists only once the view is in a window.
        DispatchQueue.main.async { slider?.value = value }
        if slider == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.volumeView.subviews.compactMap { $0 as? UISlider }.first?.value = value
            }
        }
    }

    /// KVO calls back on any thread; built outside the main actor.
    nonisolated private static func handler(
        _ update: @escaping @Sendable (Float) -> Void
    ) -> (AVAudioSession, NSKeyValueObservedChange<Float>) -> Void {
        { _, change in if let v = change.newValue { update(v) } }
    }
}

/// Puts VolumeButtons' hidden MPVolumeView in the view hierarchy.
struct HiddenVolumeView: UIViewRepresentable {
    let buttons: VolumeButtons
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        container.addSubview(buttons.hiddenVolumeView)
        container.alpha = 0.01
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
