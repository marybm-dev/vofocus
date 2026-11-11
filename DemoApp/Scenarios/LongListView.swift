import SwiftUI

/// A list whose last row starts off screen and has commas in its label. VoiceOver
/// speaks a combined label with spaces before the commas ("Toppings , Fresh Basil ,
/// …") while the accessibility label has none, so tools that compare the two exactly
/// can't find the row.
struct LongListView: View {
    @State private var status = "Nothing opened"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recipe")
                    .font(.title)
                    .accessibilityAddTraits(.isHeader)
                Text(status)
                    .accessibilityIdentifier("status")
                ForEach(1...30, id: \.self) { index in
                    Text("Detail \(index)")
                }
                Button {
                    status = "Toppings opened"
                    // Delayed so VoiceOver's own response to the activation doesn't cut it off.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        AccessibilityNotification.Announcement("Toppings opened").post()
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Toppings")
                        Text("Fresh Basil")
                        Text("and 2 more")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("toppings")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
