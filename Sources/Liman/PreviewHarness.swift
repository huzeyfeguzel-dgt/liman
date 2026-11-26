import SwiftUI
import AppKit
import LimanCore

/// Geliştirme ve otomatik UI testi için önizleme düzeneği.
///
///   Liman --preview <ekran> [--snapshot <dosya.png>] [--delay 10] [--every 15 --count 4] [--action <eylem>]
///
/// ekran:  menu | logs | settings-general | settings-memory | settings-diagnostics
/// eylem:  kernel → çekirdek indirmesini başlatır · start | stop | restart → servis
///         backend-apple | backend-colima → arka ucu değiştirir
/// Birden fazla görüntüde dosya adına -1, -2… eklenir.
@MainActor
enum PreviewHarness {
    struct Args {
        var screen = "menu"
        var snapshot: String?
        var delay = 10.0
        var every = 0.0
        var count = 1
        var action: String?

        static func parse(_ argv: [String]) -> Args? {
            guard let i = argv.firstIndex(of: "--preview") else { return nil }
            var a = Args()
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { a.screen = argv[i + 1] }
            func value(_ flag: String) -> String? {
                guard let j = argv.firstIndex(of: flag), j + 1 < argv.count else { return nil }
                return argv[j + 1]
            }
            a.snapshot = value("--snapshot")
            a.delay = value("--delay").flatMap(Double.init) ?? a.delay
            a.every = value("--every").flatMap(Double.init) ?? 0
            a.count = value("--count").flatMap(Int.init) ?? 1
            a.action = value("--action")
            return a
        }
    }

    static func run(_ args: Args, state: AppState) -> NSWindow {
        let (view, size): (AnyView, NSSize) = switch args.screen {
        case "logs": (AnyView(LogsView()), NSSize(width: 760, height: 420))
        case let s where s.hasPrefix("settings"):
            (AnyView(SettingsView(initialTab: String(s.dropFirst("settings-".count)))), NSSize(width: 520, height: 380))
        default: (AnyView(MenuContentView()), NSSize(width: 380, height: 520))
        }
        if args.screen == "logs" { state.logTargetID = nil }

        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Liman (önizleme: \(args.screen))"
        w.contentView = NSHostingView(rootView: view.environment(state))
        w.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            switch args.action {
            case "kernel":
                try? await Task.sleep(for: .seconds(2))
                state.kernel.start(state: state)
            case "start":
                try? await Task.sleep(for: .seconds(2))
                await state.startService()
            case "stop":
                try? await Task.sleep(for: .seconds(2))
                await state.stopService()
            case "restart":
                try? await Task.sleep(for: .seconds(2))
                await state.restartService()
            case let s? where s.hasPrefix("backend-"):
                try? await Task.sleep(for: .seconds(2))
                if let b = Backend(rawValue: String(s.dropFirst("backend-".count))) { state.backend = b }
            default: break
            }
        }

        if let path = args.snapshot {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(args.delay))
                for k in 1...max(args.count, 1) {
                    let out = args.count > 1 ? path.replacingOccurrences(of: ".png", with: "-\(k).png") : path
                    snapshot(w, to: out)
                    if k < args.count { try? await Task.sleep(for: .seconds(args.every)) }
                }
            }
        }
        return w
    }

    static func snapshot(_ w: NSWindow, to path: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
