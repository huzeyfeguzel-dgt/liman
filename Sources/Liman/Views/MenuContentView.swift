import SwiftUI
import LimanCore

struct MenuContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 0) {
            if state.updates.updateAvailable { updateBanner }
            header(backend: $state.backend)
            Divider()
            content
                .frame(maxHeight: 420)
            if let err = state.lastError {
                Divider()
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            serviceBar
            Divider()
            footer
        }
        .frame(width: 380)
    }

    // MARK: Güncelleme

    private var updateBanner: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Liman \(state.updates.latest?.tag_name ?? "") yayımlandı").font(.callout)
            Spacer()
            if let url = state.updates.downloadURL {
                Link("İndir", destination: url).font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
    }

    // MARK: Başlık

    private func header(backend: Binding<Backend>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Liman").font(.headline)
                Spacer()
                StatusPill(status: state.currentStatus)
            }
            Picker("Arka uç", selection: backend) {
                ForEach(Backend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(state.currentStatus.isBusy)
            .help("Servis çalışıyorsa arka uç değişince yeniden başlatılır")

            HStack {
                Text(state.currentStatus.detail ?? state.backend.subtitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if state.hostMemory > 0 {
                    Label(state.hostMemory.humanBytes, systemImage: "memorychip")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Host'ta sanallaştırma süreçlerinin toplam bellek kullanımı (RSS)")
                }
            }
        }
        .padding(12)
    }

    // MARK: İçerik

    @ViewBuilder private var content: some View {
        switch state.currentStatus {
        case .notInstalled, .needsKernel:
            SetupView(backend: state.backend)
        case .running:
            if state.containers.isEmpty {
                EmptyState(icon: "shippingbox", title: "Konteyner yok",
                           detail: "Terminalde `docker run` veya `docker compose up` ile başlatın.")
            } else {
                containerList
            }
        case .stopped, .failed, .unknown, .starting, .stopping:
            RuntimeControl()
        }
    }

    private var containerList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(state.groupedContainers, id: \.project) { group in
                    if let p = group.project {
                        Label(p, systemImage: "square.stack.3d.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 8)
                    } else if state.groupedContainers.count > 1 {
                        Text("Bağımsız").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                    ForEach(group.items) { c in
                        ContainerRow(container: c) {
                            state.logTargetID = c.id
                            openWindow(id: "logs")
                            NSApp.activate()
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Servis kontrolleri

    private var serviceBar: some View {
        let s = state.currentStatus
        let loaded = state.service.isLoaded
        return HStack(spacing: 6) {
            Text("Servis").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if loaded {
                Button { Task { await state.restartService() } } label: {
                    Label("Yeniden başlat", systemImage: "arrow.clockwise")
                }
                .disabled(s.isBusy)
                Button { Task { await state.stopService() } } label: {
                    Label("Durdur", systemImage: "stop.fill")
                }
                .disabled(s.isBusy)
            } else {
                Button { Task { await state.startService() } } label: {
                    Label("Başlat", systemImage: "play.fill")
                }
                .disabled(s.isBusy || s == .notInstalled || s == .needsKernel)
            }
            if s.isRunning && state.runningCount > 0 {
                Menu {
                    Button("Tüm konteynerleri durdur") { Task { await state.stopAll() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Alt bilgi

    private var footer: some View {
        HStack(spacing: 10) {
            Button { state.openAgentLog() } label: { Image(systemName: "doc.text.magnifyingglass") }
                .help("Servis logunu aç")
            Spacer()
            Button { openSettings(); NSApp.activate() } label: { Image(systemName: "gearshape") }
                .help("Ayarlar")
            Menu {
                Button("Arayüzü kapat (servis çalışmaya devam eder)") { NSApp.terminate(nil) }
                Button("Servisi durdur ve çık") { Task { await state.quitStoppingService() } }
            } label: { Image(systemName: "power") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Çık")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

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
                    Label(isFailed(s) ? "Yeniden dene" : "Servisi başlat", systemImage: "play.fill").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                if isFailed(s) {
                    Button("Servis logunu aç") { state.openAgentLog() }.buttonStyle(.link).font(.caption)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if state.backend == .colima, case .starting = s {
                Text("İlk açılışta VM imajı indirildiği için birkaç dakika sürebilir.")
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
        case .failed: "\(state.backend.title) servisi hata verdi"
        case .starting: "\(state.backend.title) başlatılıyor"
        case .stopping: "Servis durduruluyor"
        case .unknown: "Durum kontrol ediliyor"
        default: "\(state.backend.title) servisi çalışmıyor"
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
