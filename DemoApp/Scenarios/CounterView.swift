import SwiftUI

/// Checks whether an XCUI tap still activates a control while VoiceOver is on.
struct CounterView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Count: \(count)")
                .font(.title)
                .accessibilityIdentifier("count")
            Button("Increment") { count += 1 }
                .accessibilityIdentifier("increment")
        }
        .padding()
    }
}
