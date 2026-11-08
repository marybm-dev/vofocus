import SwiftUI

@main
struct DemoApp: App {
    init() {
        FocusLogger.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView(launchScenario: Scenario.fromLaunchArguments())
        }
    }
}

/// Launched with `-VOScenario <name>`: shows that scenario alone, with no navigation
/// chrome, so the focus order is deterministic. Otherwise shows a menu of scenarios.
struct RootView: View {
    let launchScenario: Scenario?

    var body: some View {
        if let launchScenario {
            launchScenario.view
        } else {
            NavigationStack {
                List(Scenario.allCases) { scenario in
                    NavigationLink {
                        scenario.view.navigationTitle(scenario.title)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(scenario.title)
                            Text(scenario.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("VOFocus Demo")
            }
        }
    }
}
