import SwiftUI

/// Each scenario is one focus behavior the tool should be able to verify.
/// Select one at launch with the `-VOScenario <rawValue>` launch argument.
enum Scenario: String, CaseIterable, Identifiable {
    case staticOrder = "static"
    case counter
    case uikitBanner = "uikit-banner"
    case swiftuiError = "swiftui-error"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .staticOrder: "Static Order"
        case .counter: "Counter"
        case .uikitBanner: "UIKit Banner"
        case .swiftuiError: "SwiftUI Error"
        }
    }

    var summary: String {
        switch self {
        case .staticOrder: "Heading and three buttons in a known order"
        case .counter: "Checks that a tap activates while VoiceOver is on"
        case .uikitBanner: "Save posts .layoutChanged to a banner at the bottom"
        case .swiftuiError: "Submit moves focus to an error with @AccessibilityFocusState"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .staticOrder: StaticOrderView()
        case .counter: CounterView()
        case .uikitBanner: UIKitBannerView()
        case .swiftuiError: SwiftUIErrorView()
        }
    }

    static func fromLaunchArguments() -> Scenario? {
        // `-VOScenario foo` lands in the UserDefaults argument domain.
        UserDefaults.standard.string(forKey: "VOScenario").flatMap(Scenario.init(rawValue:))
    }
}
