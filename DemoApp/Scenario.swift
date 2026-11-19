import SwiftUI

/// Each scenario is one focus behavior the tool should be able to verify.
/// Select one at launch with the `-VOScenario <rawValue>` launch argument.
enum Scenario: String, CaseIterable, Identifiable {
    case staticOrder = "static"
    case counter
    case uikitBanner = "uikit-banner"
    case swiftuiError = "swiftui-error"
    case traits
    case longList = "long-list"
    case adjustable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .staticOrder: "Static Order"
        case .counter: "Counter"
        case .uikitBanner: "UIKit Banner"
        case .swiftuiError: "SwiftUI Error"
        case .traits: "Traits"
        case .longList: "Long List"
        case .adjustable: "Adjustable"
        }
    }

    var summary: String {
        switch self {
        case .staticOrder: "Heading and three buttons in a known order"
        case .counter: "Checks that a tap activates while VoiceOver is on"
        case .uikitBanner: "Save shows a banner and notifies VoiceOver with the API from -VOFocusAPI"
        case .swiftuiError: "Submit moves focus to an error with @AccessibilityFocusState"
        case .traits: "Toggle, hint and long labels, to measure what speech capture includes"
        case .longList: "An off-screen row whose combined label has commas"
        case .adjustable: "A custom adjustable control and a slider (swipe up/down to change)"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .staticOrder: StaticOrderView()
        case .counter: CounterView()
        case .uikitBanner: UIKitBannerView()
        case .swiftuiError: SwiftUIErrorView()
        case .traits: TraitsView()
        case .longList: LongListView()
        case .adjustable: AdjustableView()
        }
    }

    static func fromLaunchArguments() -> Scenario? {
        // `-VOScenario foo` lands in the UserDefaults argument domain.
        UserDefaults.standard.string(forKey: "VOScenario").flatMap(Scenario.init(rawValue:))
    }
}
