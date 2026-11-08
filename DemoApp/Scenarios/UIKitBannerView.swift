import Accessibility
import SwiftUI
import UIKit

/// Which API the banner uses to tell VoiceOver about itself. Chosen at launch with
/// `-VOFocusAPI <rawValue>` (default uikit-layout).
enum FocusAPI: String, CaseIterable {
    /// UIAccessibility.post(notification: .layoutChanged, argument: banner)
    case uikitLayout = "uikit-layout"
    /// UIAccessibility.post(notification: .screenChanged, argument: banner)
    case uikitScreen = "uikit-screen"
    /// AccessibilityNotification.LayoutChanged(banner).post() (iOS 17+, cross-framework)
    case notificationLayout = "notification-layout"
    /// AccessibilityNotification.ScreenChanged(banner).post()
    case notificationScreen = "notification-screen"
    /// AccessibilityNotification.Announcement("Profile saved").post(); focus stays put
    case announcement
    /// The same announcement, posted 0.5 s after the tap instead of during it
    case announcementDelayed = "announcement-delayed"

    static var fromLaunchArguments: FocusAPI {
        UserDefaults.standard.string(forKey: "VOFocusAPI").flatMap(FocusAPI.init(rawValue:)) ?? .uikitLayout
    }
}

/// Tapping Save shows a banner at the bottom of the screen and notifies VoiceOver with
/// the API chosen by `-VOFocusAPI`. All but `announcement` pass the banner as the
/// element to focus.
///
/// If VoiceOver honors the programmatic focus, it lands on "Saved successfully".
/// If not, it stays on "Save, button", because VoiceOver doesn't move focus to
/// new content on its own.
struct UIKitBannerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BannerViewController {
        BannerViewController(api: .fromLaunchArguments)
    }
    func updateUIViewController(_ controller: BannerViewController, context: Context) {}
}

final class BannerViewController: UIViewController {
    private let banner = UILabel()
    private let api: FocusAPI

    init(api: FocusAPI) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        switch api {
        case .uikitLayout:
            UIAccessibility.post(notification: .layoutChanged, argument: banner)
        case .uikitScreen:
            UIAccessibility.post(notification: .screenChanged, argument: banner)
        case .notificationLayout:
            AccessibilityNotification.LayoutChanged(banner).post()
        case .notificationScreen:
            AccessibilityNotification.ScreenChanged(banner).post()
        case .announcement:
            AccessibilityNotification.Announcement("Profile saved").post()
        case .announcementDelayed:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AccessibilityNotification.Announcement("Profile saved").post()
            }
        }
    }
}
