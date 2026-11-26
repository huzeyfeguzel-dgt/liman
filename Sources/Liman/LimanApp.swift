import SwiftUI
import AppKit
import LimanCore

@main
struct LimanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(delegate.state)
        } label: {
            MenuBarLabel(state: delegate.state)
        }
        .menuBarExtraStyle(.window)

        Window("Liman Logları", id: "logs") {
            LogsView()
                .environment(delegate.state)
        }
        .defaultSize(width: 760, height: 480)

        Settings {
            SettingsView()
                .environment(delegate.state)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await state.bootstrap() }
        // Geliştirme / test: herhangi bir ekranı normal pencerede aç, ekran görüntülerini kaydet.
        if let args = PreviewHarness.Args.parse(CommandLine.arguments) {
            previewWindow = PreviewHarness.run(args, state: state)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdownUI()
    }
}

/// Menü çubuğundaki simge: çalışan konteyner sayısını gösterir.
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        let status = state.currentStatus
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: status))
            if status.isRunning && state.runningCount > 0 {
                Text(verbatim: "\(state.runningCount)").monospacedDigit()
            }
        }
        .help("Liman — \(status.label)")
    }

    /// Simge servis durumunu yansıtır: dolu kutu = çalışıyor, boş = durdu, ok = geçişte, ünlem = hata.
    static func symbol(for status: RuntimeStatus) -> String {
        switch status {
        case .running: "shippingbox.fill"
        case .starting, .stopping, .unknown: "arrow.trianglehead.2.clockwise"
        case .failed: "exclamationmark.triangle.fill"
        case .needsKernel, .notInstalled: "shippingbox.and.arrow.backward"
        case .stopped: "shippingbox"
        }
    }
}
