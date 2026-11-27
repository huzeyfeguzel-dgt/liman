import SwiftUI
import AppKit
import LimanCore

@main
struct LimanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true
    /// Dil değişince tüm sahneler `.id(language)` ile yeniden kurulur; metinler `L(...)` ile o an çözülür.
    @AppStorage(Loc.prefKey) private var language = AppLanguage.system.rawValue

    var body: some Scene {
        // Ana masaüstü penceresi. İlk sahne olduğu için Dock simgesine tıklayınca yeniden açılır.
        Window("Liman", id: "main") {
            MainWindow()
                .environment(delegate.state)
                .localized(language)
                // `.localized` görünümü dil değişince yeniden kurar; görünürlük takibi bu sınırın dışında kalmalı.
                // Pencere kapanınca Dock simgesi gizlenir, uygulama menü çubuğunda (tray) çalışmaya devam eder.
                .onAppear { delegate.state.mainWindowVisible = true }
                .onDisappear { delegate.state.mainWindowVisible = false }
        }
        .defaultSize(width: 1000, height: 660)
        .commands { LimanCommands(state: delegate.state, language: language, trayEnabled: showMenuBarIcon) }

        // Hızlı erişim için menü çubuğu simgesi (Ayarlar'dan kapatılabilir).
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuContentView()
                .environment(delegate.state)
                .localized(language)
        } label: {
            MenuBarLabel(state: delegate.state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.state)
                .localized(language)
        }
    }
}

/// Uygulama menüsüne "Servis" ve "Görünüm" komutları.
struct LimanCommands: Commands {
    let state: AppState
    /// Yalnızca dil değişince menülerin yeniden kurulması için.
    let language: String
    /// Menü çubuğu simgesi açık mı (⌘Q tray'e küçültür) yoksa kapalı mı (⌘Q tamamen kapatır).
    let trayEnabled: Bool

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appTermination) {
            if trayEnabled {
                Button(L("Menü çubuğuna küçült", "Minimize to menu bar")) { state.minimizeToTray() }
                    .keyboardShortcut("q")
            } else {
                Button(L("Liman'ı kapat (servis ve motor durur)", "Quit Liman (stops service and engine)")) {
                    Task { await state.quitFully() }
                }
                .keyboardShortcut("q")
            }
        }
        CommandMenu(L("Servis", "Service")) {
            Button(L("Başlat", "Start")) { Task { await state.startService() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.service.isLoaded || state.currentStatus.isBusy)
            Button(L("Durdur", "Stop")) { Task { await state.stopService() } }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!state.service.isLoaded || state.currentStatus.isBusy)
            Button(L("Yeniden başlat", "Restart")) { Task { await state.restartService() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!state.service.isLoaded || state.currentStatus.isBusy)
            Divider()
            Button(L("Tüm konteynerleri durdur", "Stop all containers")) { Task { await state.stopAll() } }
                .disabled(state.runningCount == 0)
            Divider()
            Button(L("Servis logunu aç", "Open service log")) { state.openAgentLog() }
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(MainPage.allCases.enumerated()), id: \.element) { i, p in
                Button(p.title) { state.openMainWindow(p) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.readOnly = CommandLine.arguments.contains("--readonly")
        Task { await state.bootstrap() }
        // Geliştirme / test: herhangi bir ekranı normal pencerede aç, ekran görüntülerini kaydet.
        if let args = PreviewHarness.Args.parse(CommandLine.arguments) {
            previewWindow = PreviewHarness.run(args, state: state)
        }
        // Ana pencere açılışta görünmezse (ör. oturum açılışında) doğrudan tray'de başla.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [state] in
            if !state.mainWindowVisible { state.applyActivationPolicy() }
        }
    }

    /// Ana pencere kapansa da uygulama menü çubuğunda (tray) açık kalır; servis ve motor çalışmaya devam eder.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q ve Dock'taki "Çık" uygulamayı kapatmaz, tray'e küçültür. Tam kapanış yalnızca tray menüsünden yapılır.
    /// Oturum kapatma / yeniden başlatma / kapatma sırasında macOS'u bekletmemek için hemen çıkılır
    /// (launchd ajanı bu durumda kendi SIGTERM'ini alır).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.isQuitting || Self.isSystemQuit { return .terminateNow }
        if state.minimizesToTray {
            state.minimizeToTray()
        } else {
            // Menü çubuğu simgesi kapalı: tray yok, ⌘Q tam kapanış yapar.
            Task { await state.quitFully() }
        }
        return .terminateCancel
    }

    /// Çıkış isteği oturum kapatma / yeniden başlatma / kapatmadan mı geliyor? (quit Apple Event'inde neden alanı olur)
    private static var isSystemQuit: Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent,
              ev.eventClass == kCoreEventClass, ev.eventID == kAEQuitApplication else { return false }
        return ev.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    /// Dock simgesine tıklanınca pencere yoksa ana pencereyi aç.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { state.openMainWindow() }
        return true
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

extension View {
    /// Görünümü seçili dile göre yeniden kurar ve tarih/sayı biçimleri için yerel ayarı uygular.
    func localized(_ language: String) -> some View {
        id(language).environment(\.locale, Loc.locale)
    }
}
