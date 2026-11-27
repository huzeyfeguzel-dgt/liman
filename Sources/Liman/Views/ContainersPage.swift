import SwiftUI
import LimanCore

/// Docker Desktop benzeri konteyner tablosu: onay kutularıyla çoklu seçim, toplu eylemler,
/// compose projesi satırları ve her satırda görünür eylem düğmeleri.
struct ContainersPage: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var onlyRunning = false
    @State private var selection: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var pendingRemoval: [ContainerSummary] = []

    private var groups: [(project: String?, items: [ContainerSummary])] {
        state.groupedContainers.compactMap { g in
            let items = g.items.filter { c in
                (!onlyRunning || c.isRunning) && (query.isEmpty
                    || c.name.localizedCaseInsensitiveContains(query)
                    || c.shortImage.localizedCaseInsensitiveContains(query)
                    || (g.project?.localizedCaseInsensitiveContains(query) ?? false))
            }
            return items.isEmpty ? nil : (g.project, items)
        }
    }

    private var visible: [ContainerSummary] { groups.flatMap(\.items) }
    private var selected: [ContainerSummary] { state.containers.filter { selection.contains($0.id) } }

    var body: some View {
        Group {
            switch state.currentStatus {
            case .running:
                if state.containers.isEmpty {
                    EmptyState(icon: "shippingbox", title: L("Konteyner yok", "No Containers"),
                               detail: L("Terminalde `docker run` veya `docker compose up` ile başlatın.", "Start one in Terminal with `docker run` or `docker compose up`."))
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        actionBar
                        Divider()
                        header
                        Divider()
                        table
                    }
                }
            case .notInstalled, .needsKernel:
                ScrollView { SetupView(backend: state.backend).frame(maxWidth: 560) }
            default:
                RuntimeControl().frame(maxHeight: .infinity)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: L("Ad, imaj veya proje", "Name, image or project"))
        .onChange(of: state.containers) { _, list in
            // Silinen konteynerler seçimde kalmasın.
            selection.formIntersection(list.map(\.id))
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { !pendingRemoval.isEmpty },
                                                                 set: { if !$0 { pendingRemoval = [] } })) {
            Button(L("Sil", "Remove"), role: .destructive) {
                let items = pendingRemoval
                pendingRemoval = []
                selection.subtract(items.map(\.id))
                Task { await state.performBulk(.remove, on: items) }
            }
        } message: {
            let running = pendingRemoval.filter(\.isRunning).count
            Text(running > 0
                 ? L("\(running) çalışan konteyner zorla durdurulup silinecek. İsimli volume'ler ve imajlar korunur.", "\(running) running containers will be force-stopped and removed. Named volumes and images are kept.")
                 : L("İsimli volume'ler ve imajlar korunur.", "Named volumes and images are kept."))
        }
    }

    private var removalTitle: String {
        pendingRemoval.count == 1 ? L("\(pendingRemoval[0].name) silinsin mi?", "Remove \(pendingRemoval[0].name)?") : L("\(pendingRemoval.count) konteyner silinsin mi?", "Remove \(pendingRemoval.count) containers?")
    }

    // MARK: Üst çubuk

    private var actionBar: some View {
        let sel = selected
        let canStart = sel.contains { !$0.isRunning }
        let canStop = sel.contains(where: \.isRunning)
        return HStack(spacing: 8) {
            if sel.isEmpty {
                Text(L("\(state.runningCount) çalışıyor · toplam \(state.containers.count)", "\(state.runningCount) running · \(state.containers.count) total"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(L("\(sel.count) seçili", "\(sel.count) selected")).font(.callout.weight(.semibold))
                Button(L("Seçimi temizle", "Clear Selection")) { selection = [] }.buttonStyle(.link).font(.callout)
            }
            Spacer()
            Toggle(L("Yalnızca çalışanlar", "Running only"), isOn: $onlyRunning).toggleStyle(.switch).controlSize(.mini)
                .fixedSize()
            Divider().frame(height: 18)
            ViewThatFits(in: .horizontal) {
                bulkButtons(sel, canStart: canStart, canStop: canStop).labelStyle(.titleAndIcon)
                bulkButtons(sel, canStart: canStart, canStop: canStop).labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func bulkButtons(_ sel: [ContainerSummary], canStart: Bool, canStop: Bool) -> some View {
        HStack(spacing: 6) {
                Button { Task { await state.performBulk(.start, on: sel) } } label: {
                    Label(L("Başlat", "Start"), systemImage: "play.fill")
                }
                .disabled(!canStart)
                Button { Task { await state.performBulk(.stop, on: sel) } } label: {
                    Label(L("Durdur", "Stop"), systemImage: "stop.fill")
                }
                .disabled(!canStop)
                Button { Task { await state.performBulk(.restart, on: sel) } } label: {
                    Label(L("Yeniden başlat", "Restart"), systemImage: "arrow.clockwise")
                }
                .disabled(!canStop)
                Button(role: .destructive) { pendingRemoval = sel } label: {
                    Label(L("Sil", "Remove"), systemImage: "trash")
                }
                .tint(.red)
                .disabled(sel.isEmpty)
                .help(L("Seçili konteynerleri sil", "Remove selected containers"))
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .fixedSize()
    }

    // MARK: Tablo

    private var header: some View {
        HStack(spacing: Col.spacing) {
            TriStateCheckbox(state: checkState(visible)) { toggle(visible) }
                .frame(width: Col.check)
                .help(L("Görünenlerin tümünü seç", "Select all visible"))
            Text(L("Ad", "Name")).frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Text(L("İmaj", "Image")).frame(minWidth: Col.imageMin, maxWidth: Col.imageMax, alignment: .leading)
            Text(L("Durum", "Status")).frame(width: Col.status, alignment: .leading)
            Text(L("Port", "Ports")).frame(width: Col.ports, alignment: .leading)
            Text("CPU").frame(width: Col.cpu, alignment: .trailing)
            Text(L("Bellek", "Memory")).frame(width: Col.memory, alignment: .leading)
            Text(L("Eylemler", "Actions")).frame(width: Col.actions, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.bar)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups, id: \.project) { g in
                    let key = g.project ?? "~"
                    if let p = g.project {
                        projectRow(p, items: g.items, key: key)
                    }
                    if g.project == nil || !collapsed.contains(key) {
                        ForEach(g.items) { c in
                            ContainerTableRow(container: c, indented: g.project != nil,
                                              selected: Binding(get: { selection.contains(c.id) },
                                                                set: { if $0 { selection.insert(c.id) } else { selection.remove(c.id) } }),
                                              onRemove: { pendingRemoval = [c] })
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private func projectRow(_ name: String, items: [ContainerSummary], key: String) -> some View {
        let running = items.filter(\.isRunning).count
        let cpu = items.compactMap { state.stats[$0.id]?.cpuPercent }.reduce(0, +)
        let mem = items.compactMap { state.stats[$0.id]?.memoryBytes }.reduce(0, +)
        let busy = items.contains { state.busyContainers.contains($0.id) }
        return HStack(spacing: Col.spacing) {
            TriStateCheckbox(state: checkState(items)) { toggle(items) }
                .frame(width: Col.check)
            HStack(spacing: 6) {
                Button {
                    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(collapsed.contains(key) ? 0 : 90))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.blue)
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(L("compose projesi", "compose project")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: Col.imageMin, maxWidth: Col.imageMax, alignment: .leading)
            StatusBadge(running: running > 0, text: L("\(running)/\(items.count) çalışıyor", "\(running)/\(items.count) running")).frame(width: Col.status, alignment: .leading)
            Color.clear.frame(width: Col.ports)
            Text(running > 0 ? Fmt.percent(cpu, digits: 1) : "—")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Col.cpu, alignment: .trailing)
            Text(mem > 0 ? mem.humanBytes : "—")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Col.memory, alignment: .leading)
            HStack(spacing: 2) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if running > 0 {
                    RowButton("stop.fill", L("Projeyi durdur", "Stop project")) { await state.performBulk(.stop, on: items) }
                    RowButton("arrow.clockwise", L("Projeyi yeniden başlat", "Restart project")) { await state.performBulk(.restart, on: items) }
                } else {
                    RowButton("play.fill", L("Projeyi başlat", "Start project")) { await state.performBulk(.start, on: items) }
                }
                Button { pendingRemoval = items } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .help(L("Projedeki tüm konteynerleri sil", "Remove all containers in the project"))
                    .disabled(busy)
            }
            .frame(width: Col.actions, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.primary.opacity(0.035))
    }

    private func checkState(_ items: [ContainerSummary]) -> TriStateCheckbox.Value {
        let n = items.filter { selection.contains($0.id) }.count
        return n == 0 ? .off : (n == items.count ? .on : .mixed)
    }

    private func toggle(_ items: [ContainerSummary]) {
        let ids = items.map(\.id)
        if checkState(items) == .on { selection.subtract(ids) } else { selection.formUnion(ids) }
    }
}

// MARK: - Satır

enum Col {
    static let spacing: CGFloat = 10
    static let check: CGFloat = 18
    static let nameMin: CGFloat = 120
    static let imageMin: CGFloat = 80
    static let imageMax: CGFloat = 220
    static let status: CGFloat = 96
    static let ports: CGFloat = 56
    static let cpu: CGFloat = 50
    static let memory: CGFloat = 120
    static let actions: CGFloat = 120
}

struct ContainerTableRow: View {
    @Environment(AppState.self) private var state
    let container: ContainerSummary
    let indented: Bool
    @Binding var selected: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    private var c: ContainerSummary { container }
    private var busy: Bool { state.busyContainers.contains(c.id) }
    private var live: LiveStats? { state.stats[c.id] }

    var body: some View {
        HStack(spacing: Col.spacing) {
            TriStateCheckbox(state: selected ? .on : .off) { selected.toggle() }
                .frame(width: Col.check)
            HStack(spacing: 8) {
                Circle().fill(c.isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Button { showLogs() } label: {
                        Text(c.name).font(.callout.weight(.medium)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(L("Logları göster", "Show logs"))
                    Text(String(c.id.prefix(12))).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, indented ? 20 : 0)
            .frame(minWidth: Col.nameMin, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Text(c.shortImage).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: Col.imageMin, maxWidth: Col.imageMax, alignment: .leading)
                .help(c.Image ?? "")

            StatusBadge(running: c.isRunning, text: statusText)
                .frame(width: Col.status, alignment: .leading)
                .help(c.Status ?? c.State ?? "")

            HStack(spacing: 4) {
                ForEach(c.publishedPorts.prefix(1), id: \.self) { p in
                    Button { state.openPort(p) } label: { Text(verbatim: "\(p)") }
                        .buttonStyle(.link).font(.caption)
                        .help("http://localhost:\(p)")
                }
                if c.publishedPorts.count > 1 {
                    Text(verbatim: "+\(c.publishedPorts.count - 1)").font(.caption2).foregroundStyle(.secondary)
                }
                if c.publishedPorts.isEmpty { Text("—").font(.caption).foregroundStyle(.tertiary) }
            }
            .frame(width: Col.ports, alignment: .leading)

            Text(live.map { Fmt.percent($0.cpuPercent, digits: 1) } ?? "—")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: Col.cpu, alignment: .trailing)

            Group {
                if let live, c.isRunning { MemoryBar(stats: live, barWidth: 28) } else { Text("—").foregroundStyle(.tertiary).font(.caption) }
            }
            .frame(width: Col.memory, alignment: .leading)

            actions.frame(width: Col.actions, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private var statusText: String {
        if c.isRunning { return L("Çalışıyor", "Running") }
        let s = (c.State ?? "").lowercased()
        return switch s {
        case "exited", "stopped": L("Durdu", "Stopped")
        case "created": L("Oluşturuldu", "Created")
        case "paused": L("Duraklatıldı", "Paused")
        case "restarting": L("Yeniden başlıyor", "Restarting")
        case "": L("Bilinmiyor", "Unknown")
        default: s.capitalized
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if busy {
                ProgressView().controlSize(.small).frame(width: 24)
            } else if c.isRunning {
                RowButton("stop.fill", L("Durdur", "Stop")) { await state.perform(.stop, on: c) }
                RowButton("arrow.clockwise", L("Yeniden başlat (belleği geri verir)", "Restart (frees memory)")) { await state.perform(.restart, on: c) }
            } else {
                RowButton("play.fill", L("Başlat", "Start")) { await state.perform(.start, on: c) }
            }
            Button { showLogs() } label: { Image(systemName: "text.alignleft") }
                .buttonStyle(.borderless).help(L("Loglar", "Logs"))
            Button { state.openShell(c) } label: { Image(systemName: "terminal") }
                .buttonStyle(.borderless).help(L("Terminalde kabuk aç", "Open shell in Terminal"))
                .disabled(!c.isRunning)
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.red)
                .help(L("Sil", "Remove"))
                .disabled(busy)
        }
        .imageScale(.medium)
    }

    @ViewBuilder private var menu: some View {
        if c.isRunning {
            Button(L("Durdur", "Stop")) { Task { await state.perform(.stop, on: c) } }
            Button(L("Yeniden başlat", "Restart")) { Task { await state.perform(.restart, on: c) } }
            Button(L("Terminalde kabuk aç", "Open Shell in Terminal")) { state.openShell(c) }
        } else {
            Button(L("Başlat", "Start")) { Task { await state.perform(.start, on: c) } }
        }
        Button(L("Loglar", "Logs")) { showLogs() }
        if !c.publishedPorts.isEmpty {
            Menu(L("Portu aç", "Open Port")) {
                ForEach(c.publishedPorts, id: \.self) { p in
                    Button { state.openPort(p) } label: { Text(verbatim: "localhost:\(p)") }
                }
            }
        }
        Divider()
        Button(L("Kimliği kopyala", "Copy ID")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c.id, forType: .string)
        }
        Button(selected ? L("Seçimden çıkar", "Deselect") : L("Seç", "Select")) { selected.toggle() }
        Button(L("Sil…", "Remove…"), role: .destructive, action: onRemove)
    }

    private func showLogs() {
        state.logTargetID = c.id
        state.page = .logs
    }
}

// MARK: - Küçük parçalar

struct RowButton: View {
    let symbol: String, help: String
    let action: () async -> Void
    init(_ symbol: String, _ help: String, _ action: @escaping () async -> Void) {
        self.symbol = symbol; self.help = help; self.action = action
    }
    var body: some View {
        Button { Task { await action() } } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

struct StatusBadge: View {
    let running: Bool, text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((running ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(running ? Color.green : Color.secondary)
    }
}

/// Seçili / seçili değil / kısmen seçili durumlu onay kutusu (proje ve "tümünü seç" satırları için).
struct TriStateCheckbox: View {
    enum Value { case off, on, mixed }
    let state: Value
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .off: "square"
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        }
    }
}
