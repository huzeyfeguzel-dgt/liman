import SwiftUI
import LimanCore

/// Menü çubuğu penceresi: bir gösterge ve hızlı bakış paneli.
/// Ayar ve yönetim işleri (arka uç, kaynaklar, kurulum, toplu işlemler) ana penceredeki ilgili sayfalarda yapılır.
struct MenuContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    /// Bu sayıya kadar konteyner kaydırma olmadan listelenir.
    private static let inlineLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            notices
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear { if state.openWindowAction == nil { state.openWindowAction = openWindow } }
    }

    // MARK: Başlık: durum göstergesi

    private var header: some View {
        let s = state.currentStatus
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(Self.tint(for: s).opacity(0.15))
                if s.isBusy || s == .unknown {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: MenuBarLabel.symbol(for: s))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Self.tint(for: s))
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(s.label).font(.headline)
                Text(subtitle(s))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func subtitle(_ s: RuntimeStatus) -> String {
        if case .failed = s { return state.backend.title }
        if let d = s.detail { return "\(state.backend.title) · \(d)" }
        return state.backend.title
    }

    // MARK: Bildirimler (tek satırlık, tıklanınca ilgili yere götürür)

    @ViewBuilder private var notices: some View {
        if state.updates.updateAvailable, let url = state.updates.downloadURL {
            TrayNotice(icon: "arrow.down.circle.fill", tint: .blue,
                      text: L("Liman \(state.updates.latest?.tag_name ?? "") yayımlandı — indir", "Liman \(state.updates.latest?.tag_name ?? "") is available — download")) {
                NSWorkspace.shared.open(url)
            }
        }
        if state.resourcesPending {
            TrayNotice(icon: "cpu", tint: .orange, text: L("Kaynak ayarları henüz uygulanmadı", "Resource settings not applied yet")) {
                state.openMainWindow(.resources)
            }
        }
        if let err = state.lastError {
            TrayNotice(icon: "exclamationmark.triangle.fill", tint: .orange, text: err) {
                state.openMainWindow(.logs)
            }
        }
    }

    // MARK: İçerik

    @ViewBuilder private var content: some View {
        let s = state.currentStatus
        switch s {
        case .running:
            summary
            if state.containers.isEmpty {
                TrayMessage(icon: "shippingbox", title: L("Konteyner yok", "No containers"),
                        detail: L("`docker run` veya `docker compose up` ile başlatın.", "Start one with `docker run` or `docker compose up`."))
            } else {
                Divider()
                containerList
            }
        case .notInstalled, .needsKernel:
            TrayMessage(icon: "wrench.and.screwdriver", title: L("Kurulum tamamlanmadı", "Setup incomplete"),
                    detail: s == .needsKernel ? L("Linux çekirdeğinin indirilmesi gerekiyor.", "The Linux kernel needs to be downloaded.") : L("\(state.backend.title) kurulu değil.", "\(state.backend.title) is not installed.")) {
                Button(L("Kurulumu aç", "Open setup")) { state.openMainWindow(.overview) }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
            }
        case .failed(let msg):
            TrayMessage(icon: "exclamationmark.triangle", title: L("Servis hata verdi", "Service failed"), detail: msg, isError: true) {
                Button(L("Yeniden dene", "Try again")) { Task { await state.restartService() } }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
            }
        case .stopped:
            TrayMessage(icon: "power", title: L("Servis kapalı", "Service is off"),
                    detail: L("Konteynerleri çalıştırmak için servisi başlatın.", "Start the service to run containers.")) {
                Button(L("Servisi başlat", "Start service")) { Task { await state.startService() } }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
            }
        case .starting, .stopping, .unknown:
            TrayMessage(icon: "hourglass", title: s.label,
                    detail: state.backend == .colima && s != .stopping && s != .unknown
                        ? L("İlk açılışta VM imajı indirildiği için birkaç dakika sürebilir.", "The first start may take a few minutes while the VM image downloads.") : nil)
        }
    }

    /// Servis çalışırken üç büyük, okunaklı gösterge.
    private var summary: some View {
        let memory = state.hostMemory > 0 ? state.hostMemory : state.totalContainerMemory
        return HStack(spacing: 0) {
            TrayMetric(value: "\(state.runningCount)", unit: "/ \(state.containers.count)", label: L("Çalışan", "Running"))
            Divider().frame(height: 30)
            TrayMetric(value: String(format: "%.0f", state.totalCPUPercent), unit: "%", label: "CPU")
            Divider().frame(height: 30)
            TrayMetric(value: memory.humanBytes, unit: nil, label: L("Bellek", "Memory"))
                .help(state.hostMemory > 0
                      ? L("Host'ta sanallaştırma süreçlerinin toplam bellek kullanımı", "Total memory used by virtualization processes on the host")
                      : L("Konteynerlerin toplam bellek kullanımı", "Total memory used by containers"))
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var containerList: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(state.groupedContainers, id: \.project) { group in
                if let p = group.project {
                    TraySectionLabel(text: p)
                } else if state.groupedContainers.count > 1 {
                    TraySectionLabel(text: L("Diğer", "Other"))
                }
                ForEach(group.items) { TrayContainerRow(container: $0) }
            }
        }
        .padding(.vertical, 6)

        if state.containers.count <= Self.inlineLimit {
            rows
        } else {
            ScrollView { rows }.frame(height: 330)
        }
    }

    // MARK: Alt çubuk

    private var footer: some View {
        let s = state.currentStatus
        let loaded = state.service.isLoaded
        return HStack(spacing: 8) {
            Button { state.openMainWindow() } label: {
                Label(L("Liman'ı aç", "Open Liman"), systemImage: "macwindow")
            }
            .keyboardShortcut("o")

            Spacer()

            SettingsButton()
                .labelStyle(.iconOnly)
                .keyboardShortcut(",")

            if s != .notInstalled && s != .needsKernel {
                Button {
                    Task { loaded ? await state.stopService() : await state.startService() }
                } label: {
                    Image(systemName: loaded ? "stop.circle" : "play.circle")
                }
                .disabled(s.isBusy)
                .help(loaded ? L("Servisi durdur", "Stop service") : L("Servisi başlat", "Start service"))
            }

            if state.isQuitting {
                ProgressView().controlSize(.small)
                    .help(L("Servis ve motor durduruluyor…", "Stopping service and engine…"))
            } else {
                Menu {
                    Button(L("Liman'ı tamamen kapat", "Quit Liman completely")) { Task { await state.quitFully() } }
                    Text(L("Arka plan servisi ve motor durur, tüm konteynerler kapanır",
                           "Stops the background service and engine; all containers stop"))
                } label: {
                    Image(systemName: "power")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Çık", "Quit"))
            }
        }
        .buttonStyle(.borderless)
        .font(.body)
        .imageScale(.large)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    static func tint(for s: RuntimeStatus) -> Color {
        switch s {
        case .running: .green
        case .starting, .stopping, .unknown: .yellow
        case .failed: .red
        case .stopped, .notInstalled, .needsKernel: .secondary
        }
    }
}

// MARK: - Tray parçaları

/// Menü çubuğu için sade konteyner satırı: ad, imaj/port ve sağda CPU · bellek.
/// Üzerine gelince tek bir başlat/durdur düğmesi görünür; diğer eylemler sağ tık menüsünde.
private struct TrayContainerRow: View {
    @Environment(AppState.self) private var state
    let container: ContainerSummary
    @State private var hovering = false

    private var busy: Bool { state.busyContainers.contains(container.id) }
    private var live: LiveStats? { container.isRunning ? state.stats[container.id] : nil }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.body)
                    .foregroundStyle(container.isRunning ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 6)

            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { showLogs() }
        .contextMenu { menuItems }
        .help(container.Status ?? container.name)
    }

    /// İmaj ve yayınlanan portlar tek satırda.
    private var detail: String {
        let ports = container.publishedPorts.prefix(2).map { ":\($0)" }.joined(separator: " ")
        let extra = container.publishedPorts.count > 2 ? " +\(container.publishedPorts.count - 2)" : ""
        return ports.isEmpty ? container.shortImage : "\(container.shortImage) · \(ports)\(extra)"
    }

    @ViewBuilder private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if hovering {
            HStack(spacing: 6) {
                if let p = container.publishedPorts.first, container.isRunning {
                    Button { state.openPort(p) } label: { Image(systemName: "safari") }
                        .help(Text(verbatim: "http://localhost:\(p)"))
                }
                Button {
                    Task { await state.perform(container.isRunning ? .stop : .start, on: container) }
                } label: {
                    Image(systemName: container.isRunning ? "stop.fill" : "play.fill")
                }
                .help(container.isRunning ? L("Durdur", "Stop") : L("Başlat", "Start"))
            }
            .buttonStyle(.borderless)
            .imageScale(.medium)
        } else if let live {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.percent(live.cpuPercent))
                Text(live.memoryBytes.humanBytes)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        } else if !container.isRunning {
            Text(L("Durdu", "Stopped")).font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if container.isRunning {
            Button(L("Durdur", "Stop")) { Task { await state.perform(.stop, on: container) } }
            Button(L("Yeniden başlat", "Restart")) { Task { await state.perform(.restart, on: container) } }
            Button(L("Terminalde kabuk aç", "Open shell in Terminal")) { state.openShell(container) }
        } else {
            Button(L("Başlat", "Start")) { Task { await state.perform(.start, on: container) } }
        }
        Button(L("Loglar", "Logs"), action: showLogs)
        if !container.publishedPorts.isEmpty {
            Menu(L("Portu aç", "Open port")) {
                ForEach(container.publishedPorts, id: \.self) { p in
                    Button { state.openPort(p) } label: { Text(verbatim: "localhost:\(p)") }
                }
            }
        }
        Divider()
        Button(L("Konteynerler sayfasında göster", "Show in Containers")) { state.openMainWindow(.containers) }
    }

    private func showLogs() {
        state.logTargetID = container.id
        state.openMainWindow(.logs)
    }
}

private struct TrayMetric: View {
    let value: String
    let unit: String?
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value).font(.title3.weight(.semibold).monospacedDigit())
                if let unit { Text(verbatim: unit).font(.callout).foregroundStyle(.secondary) }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TraySectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }
}

private struct TrayNotice: View {
    let icon: String
    let tint: Color
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(hovering ? 0.16 : 0.10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Servis çalışmıyorken ortalanmış kısa mesaj ve (varsa) tek bir birincil eylem.
private struct TrayMessage<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String?
    var isError = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let detail {
                Text(.init(detail))
                    .font(.callout)
                    .foregroundStyle(isError ? Color.red : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 22)
    }
}

extension TrayMessage where Actions == EmptyView {
    init(icon: String, title: String, detail: String?, isError: Bool = false) {
        self.init(icon: icon, title: title, detail: detail, isError: isError) { EmptyView() }
    }
}

// MARK: - Ana pencereyle paylaşılan parçalar

struct StatusPill: View {
    let status: RuntimeStatus

    var body: some View {
        HStack(spacing: 5) {
            if status.isBusy { ProgressView().controlSize(.mini) }
            else { Circle().fill(color).frame(width: 7, height: 7) }
            Text(status.label).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .starting, .stopping, .unknown: .yellow
        case .failed: .red
        case .stopped, .notInstalled, .needsKernel: .gray
        }
    }
}

struct RuntimeControl: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let s = state.currentStatus
        VStack(spacing: 10) {
            Image(systemName: icon(s)).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title(s)).font(.headline)
            if let d = s.detail {
                Text(d).font(.caption)
                    .foregroundStyle(isFailed(s) ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if !s.isBusy {
                Button {
                    Task { if isFailed(s) { await state.restartService() } else { await state.startService() } }
                } label: {
                    Label(isFailed(s) ? L("Yeniden dene", "Try again") : L("Servisi başlat", "Start service"), systemImage: "play.fill").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                if isFailed(s) {
                    Button(L("Servis logunu aç", "Open service log")) { state.openAgentLog() }.buttonStyle(.link).font(.caption)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if state.backend == .colima, case .starting = s {
                Text(L("İlk açılışta VM imajı indirildiği için birkaç dakika sürebilir.", "The first start may take a few minutes while the VM image downloads."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func isFailed(_ s: RuntimeStatus) -> Bool { if case .failed = s { true } else { false } }
    private func icon(_ s: RuntimeStatus) -> String {
        switch s {
        case .failed: "exclamationmark.triangle"
        case .starting, .stopping, .unknown: "hourglass"
        default: "power.circle"
        }
    }
    private func title(_ s: RuntimeStatus) -> String {
        switch s {
        case .failed: L("\(state.backend.title) servisi hata verdi", "\(state.backend.title) service failed")
        case .starting: L("\(state.backend.title) başlatılıyor", "Starting \(state.backend.title)")
        case .stopping: L("Servis durduruluyor", "Stopping service")
        case .unknown: L("Durum kontrol ediliyor", "Checking status")
        default: L("\(state.backend.title) servisi çalışmıyor", "\(state.backend.title) service is not running")
        }
    }
}

struct EmptyState: View {
    let icon: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(.init(detail)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}
