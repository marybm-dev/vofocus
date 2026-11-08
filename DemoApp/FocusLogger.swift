import UIKit
import os

/// Logs every VoiceOver focus change to os.log (subsystem dev.vofocus.DemoApp,
/// category focus), so a run can be cross-checked in Console.app.
enum FocusLogger {
    private static let log = Logger(subsystem: "dev.vofocus.DemoApp", category: "focus")

    @MainActor
    static func start() {
        #if DEBUG
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
        ) { note in
            // Delivered on the main queue (queue: .main), so reading UIKit state is safe.
            nonisolated(unsafe) let element = note.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject
            MainActor.assumeIsolated {
                let label = element?.accessibilityLabel ?? "<no label>"
                let id = (element as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "-"
                log.notice("focus label=\(label, privacy: .public) id=\(id, privacy: .public)")
            }
        }
        #endif
    }
}
