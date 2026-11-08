import SwiftUI

/// The baseline: a heading and three buttons stacked top to bottom. VoiceOver
/// should read them in this order.
struct StaticOrderView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Static Order")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Button("One") {}
            Button("Two") {}
            Button("Three") {}
        }
        .padding()
    }
}
