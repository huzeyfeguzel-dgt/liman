import SwiftUI
import AppKit
import LimanCore

enum MainPage: String, CaseIterable, Identifiable, Hashable {
    case overview, containers, logs, resources
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L("Genel bakış", "Overview")
        case .containers: L("Konteynerler", "Containers")
        case .logs: L("Loglar", "Logs")
        case .resources: L("Kaynaklar", "Resources")
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .containers: "shippingbox"
        case .logs: "text.alignleft"
        case .resources: "cpu"
        }
    }
}

/// Masaüstü ana penceresi. Menü çubuğu simgesi hızlı erişim için kalır; servis her iki arayüzden bağımsız çalışır.
struct MainWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $state.page) {
                Section {
                    ForEach(MainPage.allCases) { p in
                        Label(p.title, systemImage: p.icon)
                            .badge(badge(for: p))
                            .tag(p)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(state.page?.title ?? "Liman")
        .toolbar { toolbar }
        .frame(minWidth: 980, minHeight: 560)
        .onAppear { state.openWindowAction = openWindow }
    }

    private func badge(for p: MainPage) -> Text? {
        switch p {
        case .containers where state.runningCount > 0: Text(verbatim: "\(state.runningCount)")
        case .resources where state.resourcesPending: Text(verbatim: "!")
        default: nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.page ?? .overview {
        case .overview: OverviewPage()
        case .containers: ContainersPage()
        case .logs: LogsView()
        case .resources: ResourcesView()
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                StatusPill(status: state.currentStatus)
                Spacer(minLength: 0)
                SettingsButton()
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
            }
            Text(state.backend.title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let s = state.currentStatus
            if state.service.isLoaded {
                Button { Task { await state.restartService() } } label: {
                    Label(L("Yeniden başlat", "Restart"), systemImage: "arrow.clockwise")
                }
                .help(L("Servisi yeniden başlat (konteynerler çalışmaya devam eder)", "Restart the service (containers keep running)"))
                .disabled(s.isBusy)
                Button { Task { await state.stopService() } } label: {
                    Label(L("Durdur", "Stop"), systemImage: "stop.fill")
                }
                .help(L("Servisi durdur", "Stop the service"))
                .disabled(s.isBusy)
            } else {
                Button { Task { await state.startService() } } label: {
                    Label(L("Başlat", "Start"), systemImage: "play.fill")
                }
                .help(L("Servisi başlat", "Start the service"))
                .disabled(s.isBusy || s == .notInstalled || s == .needsKernel)
            }
        }
    }
}

// MARK: - Ortak parçalar

/// Ayarlar penceresini açar. Uygulama tray'deyken (accessory) pencere öne gelsin diye uygulamayı da etkinleştirir.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            NSApp.activate()
            openSettings()
        } label: {
            Label(L("Ayarlar", "Settings"), systemImage: "gearshape")
        }
        .help(L("Ayarlar", "Settings"))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

struct Metric: View {
    let title: String, value: String, detail: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

struct Banner<Trailing: View>: View {
    let icon: String, tint: Color, text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
            Spacer()
            trailing
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

enum MemoryText {
    static func mb(_ v: Int) -> String {
        v >= 1024 && v % 1024 == 0 ? "\(v / 1024) GB" : (v >= 1024 ? "\(Fmt.decimal(Double(v) / 1024, digits: 1)) GB" : "\(v) MB")
    }
}
