import SwiftUI

@main
struct CodexSpeedMonitorMenuApp: App {
    @StateObject private var store = TelemetryStore()

    var body: some Scene {
        MenuBarExtra {
            WidgetView(store: store)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Token speed")
        }
        .menuBarExtraStyle(.window)

        Window("Codex Speed Report", id: "report") {
            ReportView(store: store)
        }
        .defaultSize(width: 1040, height: 720)
    }
}
