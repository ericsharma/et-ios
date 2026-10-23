import SwiftUI
import UIKit

/// The share sheet's "E.T." (PLAN-files F7): pick a machine, then
/// optionally a session; the files go to ~/etd-downloads there.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Starting the endpoint takes a moment: start it while the user picks.
        IrohLink.shared.start()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let model = ShareModel { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        self.model = model
        let hosting = UIHostingController(rootView: ShareView(model: model))
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        Task { await model.load(providers) }
    }
}
