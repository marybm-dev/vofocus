import SwiftUI

/// Submitting an empty name shows an error below the button and moves VoiceOver
/// focus to it with `@AccessibilityFocusState`.
struct SwiftUIErrorView: View {
    @State private var name = ""
    @State private var showError = false
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign Up")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Button("Submit") {
                showError = name.isEmpty
                guard showError else { return }
                // Focus can't move to the error until it's in the hierarchy, so wait
                // one short beat. Skipping this delay is a common real-world bug.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    errorFocused = true
                }
            }
            .accessibilityIdentifier("submit")
            if showError {
                Text("Name is required")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("error")
                    .accessibilityFocused($errorFocused)
            }
            Spacer()
        }
        .padding()
    }
}
