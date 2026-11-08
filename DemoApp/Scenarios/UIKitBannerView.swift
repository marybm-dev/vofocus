import SwiftUI
import UIKit

/// Tapping Save shows a banner at the bottom of the screen and posts
/// `.layoutChanged` with the banner as its argument.
///
/// If VoiceOver honors the programmatic focus, it lands on "Saved successfully".
/// If not, it stays on "Save, button", because VoiceOver doesn't move focus to
/// new content on its own.
struct UIKitBannerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BannerViewController { BannerViewController() }
    func updateUIViewController(_ controller: BannerViewController, context: Context) {}
}

final class BannerViewController: UIViewController {
    private let banner = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Edit Profile"
        title.font = .preferredFont(forTextStyle: .title1)
        title.accessibilityTraits = .header

        var saveConfig = UIButton.Configuration.filled()
        saveConfig.title = "Save"
        let save = UIButton(configuration: saveConfig)
        save.accessibilityIdentifier = "save"
        save.addAction(UIAction { [weak self] _ in self?.showBanner() }, for: .primaryActionTriggered)

        var cancelConfig = UIButton.Configuration.plain()
        cancelConfig.title = "Cancel"
        let cancel = UIButton(configuration: cancelConfig)

        let stack = UIStackView(arrangedSubviews: [title, save, cancel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        banner.text = "Saved successfully"
        banner.textAlignment = .center
        banner.backgroundColor = .systemGreen
        banner.textColor = .white
        banner.accessibilityIdentifier = "banner"
        banner.isHidden = true
        banner.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(banner)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            banner.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            banner.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            banner.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            banner.heightAnchor.constraint(equalToConstant: 56),
        ])
    }

    private func showBanner() {
        banner.isHidden = false
        UIAccessibility.post(notification: .layoutChanged, argument: banner)
    }
}
