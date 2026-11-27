import SwiftUI
import Charts
import LimanCore

/// Ana sayfa: çalışma zamanı durumu, özet metrikler, CPU/bellek grafikleri ve çalışan konteynerlerin genel görünümü.
struct OverviewPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.updates.updateAvailable, let url = state.updates.downloadURL {
                    Banner(icon: "arrow.down.circle.fill", tint: .blue,
                           text: L("Liman \(state.updates.latest?.tag_name ?? "") yayımlandı", "Liman \(state.updates.latest?.tag_name ?? "") is available")) {
                        Link(L("İndir", "Download"), destination: url)
                    }
                }
                if state.resourcesPending {
                    Banner(icon: "cpu", tint: .orange, text: L("Kaynak ayarları kaydedildi ama henüz uygulanmadı.", "Resource settings are saved but not yet applied.")) {
                        Button(L("Kaynaklar", "Resources")) { state.page = .resources }
                    }
                }

                runtimeCard(backend: $state.backend)

                switch state.currentStatus {
                case .notInstalled, .needsKernel:
                    Card { SetupView(backend: state.backend) }
                case .running:
                    metrics
                    charts
                    runningContainers
                    memoryBreakdown
                    defaultsCard
                default:
                    Card { RuntimeControl() }
                }

                if let err = state.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Çalışma zamanı

    private func runtimeCard(backend: Binding<Backend>) -> some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(L("Çalışma zamanı", "Runtime")).font(.headline)
                        StatusPill(status: state.currentStatus)
                    }
                    Text(state.currentStatus.detail ?? state.backend.subtitle)
                        .font(.callout).foregroundStyle(.secondary)
                    Text(verbatim: "DOCKER_HOST=unix://\(state.backend.socketPath)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                Picker(L("Arka uç", "Backend"), selection: backend) {
                    ForEach(Backend.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .disabled(state.currentStatus.isBusy)
            }
        }
    }

    // MARK: Metrikler

    private var metrics: some View {
        let cpu = state.totalCPUPercent
        let mem = state.totalContainerMemory
        let stopped = state.containers.count - state.runningCount
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            Metric(title: L("Çalışan konteyner", "Running containers"), value: "\(state.runningCount)",
                   detail: stopped > 0 ? L("\(stopped) durdu · toplam \(state.containers.count)", "\(stopped) stopped · \(state.containers.count) total") : L("toplam \(state.containers.count)", "\(state.containers.count) total"))
            Metric(title: L("CPU kullanımı", "CPU usage"), value: Fmt.percent(cpu, digits: 1),
                   detail: L("\(HostInfo.cpuCount) çekirdeğin toplamı", "Total of \(HostInfo.cpuCount) cores"))
            Metric(title: L("Konteyner belleği", "Container memory"), value: mem == 0 ? "—" : mem.humanBytes,
                   detail: L("konteyner içi kullanım", "usage inside containers"))
            Metric(title: L("Host'ta VM belleği", "VM memory on host"), value: state.hostMemory.humanBytes,
                   detail: L("RAM: \(Fmt.percent(Double(hostMemPct))) · VM süreçleri", "RAM: \(Fmt.percent(Double(hostMemPct))) · VM processes"))
        }
    }

    private var hostMemPct: Int {
        Int((Double(state.hostMemory) / Double(max(HostInfo.memoryMB, 1) * 1_048_576) * 100).rounded())
    }

    // MARK: Grafikler

    /// Bellek grafiği seri adları (lejant ve renk ölçeği aynı anahtarı kullanmalı).
    private var vmSeries: String { L("Host'ta VM", "VM on host") }
    private var insideSeries: String { L("Konteyner içi", "Inside containers") }

    private var charts: some View {
        let h = state.history
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ChartHeader(title: "CPU", value: Fmt.percent(state.totalCPUPercent, digits: 1),
                                detail: L("Host CPU kapasitesinin yüzdesi", "Percent of host CPU capacity"))
                    Chart(h) { s in
                        AreaMark(x: .value(L("Zaman", "Time"), s.date), y: .value("CPU", s.cpuPercent))
                            .foregroundStyle(.linearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0.03)],
                                                             startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value(L("Zaman", "Time"), s.date), y: .value("CPU", s.cpuPercent))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...max(10, (h.map(\.cpuPercent).max() ?? 0) * 1.2))
                    .chartYAxis { AxisMarks(position: .leading) { v in
                        AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(verbatim: Fmt.percent(d)) } }
                    } }
                    .chartXAxis { timeAxis }
                    .chartXScale(domain: timeDomain)
                    .frame(height: 160)
                    .overlay { if h.count < 2 { collecting } }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ChartHeader(title: L("Bellek", "Memory"), value: state.hostMemory.humanBytes,
                                detail: L("Host'taki VM belleği ve konteyner içi kullanım", "VM memory on host and usage inside containers"))
                    Chart {
                        ForEach(h) { s in
                            AreaMark(x: .value(L("Zaman", "Time"), s.date), y: .value("MB", Double(s.hostVMMemory) / 1_048_576),
                                     series: .value(L("Seri", "Series"), "VM"))
                                .foregroundStyle(.linearGradient(colors: [.purple.opacity(0.3), .purple.opacity(0.03)],
                                                                 startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value(L("Zaman", "Time"), s.date), y: .value("MB", Double(s.hostVMMemory) / 1_048_576),
                                     series: .value(L("Seri", "Series"), vmSeries))
                                .foregroundStyle(by: .value(L("Seri", "Series"), vmSeries))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value(L("Zaman", "Time"), s.date), y: .value("MB", Double(s.containerMemory) / 1_048_576),
                                     series: .value(L("Seri", "Series"), insideSeries))
                                .foregroundStyle(by: .value(L("Seri", "Series"), insideSeries))
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartForegroundStyleScale([vmSeries: Color.purple, insideSeries: Color.green])
                    .chartLegend(position: .top, alignment: .trailing)
                    .chartYAxis { AxisMarks(position: .leading) { v in
                        AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(MemoryText.mb(Int(d))) } }
                    } }
                    .chartXAxis { timeAxis }
                    .chartXScale(domain: timeDomain)
                    .frame(height: 160)
                    .overlay { if h.count < 2 { collecting } }
                }
            }
        }
    }

    /// Sabit 15 dakikalık pencere: grafik Activity Monitor gibi soldan dolar, eksen etiketleri tekrarlamaz.
    private var timeDomain: ClosedRange<Date> {
        let end = state.history.last?.date ?? Date()
        let first = state.history.first?.date ?? end
        // En az 2, en fazla 15 dakika: ilk dakikalarda grafik boş bir şerit gibi görünmesin.
        let span = min(max(end.timeIntervalSince(first), 120), 15 * 60)
        return end.addingTimeInterval(-span)...end
    }

    private var timeAxis: some AxisContent {
        let span = timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound)
        return AxisMarks(values: .stride(by: .minute, count: span > 6 * 60 ? 5 : 1)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour().minute(), collisionResolution: .greedy)
        }
    }

    private var collecting: some View {
        Text(L("Veri toplanıyor…", "Collecting data…")).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Çalışan konteynerler

    private var runningContainers: some View {
        let running = state.containers.filter(\.isRunning)
            .sorted { (state.stats[$0.id]?.memoryBytes ?? 0) > (state.stats[$1.id]?.memoryBytes ?? 0) }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Çalışan konteynerler", "Running containers")).font(.headline)
                    Text(verbatim: "\(running.count)").font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    if state.runningCount > 0 {
                        Button(L("Tümünü durdur", "Stop All")) { Task { await state.stopAll() } }.controlSize(.small)
                    }
                    Button(L("Tümünü gör →", "See All →")) { state.page = .containers }.buttonStyle(.link)
                }
                if running.isEmpty {
                    Text(LocalizedStringKey(state.containers.isEmpty
                         ? L("Henüz konteyner yok. Terminalde `docker run` veya `docker compose up` ile başlatın.", "No containers yet. Start one in Terminal with `docker run` or `docker compose up`.")
                         : L("Çalışan konteyner yok (\(state.containers.count) durdurulmuş).", "No running containers (\(state.containers.count) stopped).")))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(running.prefix(8)) { c in
                            RunningRow(container: c)
                            if c.id != running.prefix(8).last?.id { Divider() }
                        }
                    }
                    if running.count > 8 {
                        Text(L("+\(running.count - 8) konteyner daha", "+\(running.count - 8) more containers")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Bellek dağılımı

    @ViewBuilder private var memoryBreakdown: some View {
        let items = state.containers.filter(\.isRunning)
            .compactMap { c -> (name: String, mb: Double, limitMB: Double)? in
                guard let s = state.stats[c.id], s.memoryBytes > 0 else { return nil }
                return (c.name, Double(s.memoryBytes) / 1_048_576, Double(s.memoryLimit) / 1_048_576)
            }
            .sorted { $0.mb > $1.mb }
            .prefix(10)
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ChartHeader(title: L("Konteyner başına bellek", "Memory per container"), value: nil, detail: L("Kullanım ve limit (en yüksek 10)", "Usage and limit (top 10)"))
                    Chart(Array(items), id: \.name) { it in
                        // xStart/xEnd: iki çubuk üst üste biner, yığılmaz.
                        BarMark(xStart: .value(L("Başlangıç", "Start"), 0.0), xEnd: .value("Limit", it.limitMB), y: .value(L("Konteyner", "Container"), it.name))
                            .foregroundStyle(Color.secondary.opacity(0.15))
                        BarMark(xStart: .value(L("Başlangıç", "Start"), 0.0), xEnd: .value(L("Kullanım", "Usage"), it.mb), y: .value(L("Konteyner", "Container"), it.name))
                            .foregroundStyle(it.limitMB > 0 && it.mb / it.limitMB >= 0.85 ? Color.red : Color.green)
                            .annotation(position: .trailing) {
                                Text(MemoryText.mb(Int(it.mb))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis { AxisMarks { v in
                        AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(MemoryText.mb(Int(d))) } }
                    } }
                    .frame(height: CGFloat(items.count) * 28 + 30)
                }
            }
        }
    }

    // MARK: Varsayılan kaynaklar

    @ViewBuilder private var defaultsCard: some View {
        if state.backend == .apple {
            let r = state.appliedResources ?? state.resources
            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Varsayılan kaynaklar", "Default resources")).font(.headline)
                        Text(L("Konteyner: \(r.containerCPUs) CPU · \(MemoryText.mb(r.containerMemoryMB))   ·   Builder: \(r.builderCPUs) CPU · \(MemoryText.mb(r.builderMemoryMB))", "Container: \(r.containerCPUs) CPU · \(MemoryText.mb(r.containerMemoryMB))   ·   Builder: \(r.builderCPUs) CPU · \(MemoryText.mb(r.builderMemoryMB))"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Düzenle", "Edit")) { state.page = .resources }
                }
            }
        }
    }
}

private struct ChartHeader: View {
    let title: String, value: String?, detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let value { Text(value).font(.title3.weight(.semibold)).monospacedDigit() }
        }
    }
}

/// Genel bakıştaki kompakt çalışan konteyner satırı.
private struct RunningRow: View {
    @Environment(AppState.self) private var state
    let container: ContainerSummary

    var body: some View {
        let c = container
        let live = state.stats[c.id]
        HStack(spacing: 12) {
            Circle().fill(.green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let p = c.composeProject {
                        Label(p, systemImage: "square.stack.3d.up").labelStyle(.titleAndIcon)
                    }
                    Text(c.shortImage).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(c.publishedPorts.prefix(2), id: \.self) { p in
                    Button { state.openPort(p) } label: { Text(verbatim: ":\(p)") }.buttonStyle(.link).font(.caption)
                }
            }
            .frame(width: 80, alignment: .leading)
            Text(live.map { Fmt.percent($0.cpuPercent, digits: 1) } ?? "—")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Group {
                if let live { MemoryBar(stats: live, barWidth: 60) } else { Text("—").font(.caption).foregroundStyle(.tertiary) }
            }
            .frame(width: 170, alignment: .leading)
            HStack(spacing: 2) {
                if state.busyContainers.contains(c.id) {
                    ProgressView().controlSize(.small)
                } else {
                    RowButton("stop.fill", L("Durdur", "Stop")) { await state.perform(.stop, on: c) }
                    RowButton("arrow.clockwise", L("Yeniden başlat", "Restart")) { await state.perform(.restart, on: c) }
                    Button { state.logTargetID = c.id; state.page = .logs } label: { Image(systemName: "text.alignleft") }
                        .buttonStyle(.borderless).help(L("Loglar", "Logs"))
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}
