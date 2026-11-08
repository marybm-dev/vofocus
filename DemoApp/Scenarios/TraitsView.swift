import SwiftUI

/// Measures what XCUIVoiceOverService captures of VoiceOver's speech:
/// - a toggle: the trait and value on landing, only the value after a change, and the
///   full announcement again after moving away and back
/// - a button with a hint, which VoiceOver speaks after a pause
/// - buttons with long labels of numbered words ("w1 w2 …"), so any length cutoff
///   shows exactly where it falls and whether the trait after it survives
struct TraitsView: View {
    @State private var notifications = false

    static func words(_ count: Int) -> String {
        (1...count).map { "w\($0)" }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Traits")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Toggle("Notifications", isOn: $notifications)
                .accessibilityIdentifier("toggle")
            Button("Share") {}
                .accessibilityHint("Shares this page")
                .accessibilityIdentifier("hinted")
            Button(Self.words(40)) {}
                .lineLimit(1)
                .accessibilityIdentifier("medium")
            Button(Self.words(150)) {}
                .lineLimit(1)
                .accessibilityIdentifier("long")
            Button("Done") {}
                .accessibilityIdentifier("done")
        }
        .padding()
    }
}
