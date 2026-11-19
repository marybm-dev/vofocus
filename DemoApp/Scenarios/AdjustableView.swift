import SwiftUI

/// Adjustable controls, which VoiceOver users change with a one-finger swipe up or
/// down. XCUIVoiceOverService has no increment or decrement, so this checks whether
/// a synthesized swipe reaches VoiceOver as one.
struct AdjustableView: View {
    @State private var servings = 2
    @State private var volume = 50.0

    var body: some View {
        VStack(spacing: 32) {
            Text("Adjustable")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            // A custom adjustable element: swipe up adds a serving, down removes one.
            Text("Servings: \(servings)")
                .font(.title2)
                .padding()
                .accessibilityElement()
                .accessibilityLabel("Servings")
                .accessibilityValue("\(servings)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: servings = min(servings + 1, 10)
                    case .decrement: servings = max(servings - 1, 1)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("servings")
            Slider(value: $volume, in: 0...100, step: 10) { Text("Volume") }
                .accessibilityIdentifier("volume")
            Text("Volume: \(Int(volume))")
                .accessibilityIdentifier("volume-readout")
        }
        .padding()
    }
}
