import SwiftUI
import LimanCore

struct ContainerRow: View {
    @Environment(AppState.self) private var state
    let container: ContainerSummary
    let showLogs: () -> Void
    @State private var hovering = false
    @State private var confirmRemove = false

    private var busy: Bool { state.busyContainers.contains(container.id) }
    private var live: LiveStats? { state.stats[container.id] }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(container.shortImage).lineLimit(1)
                    ForEach(container.publishedPorts.prefix(3), id: \.self) { p in
                        // verbatim: Türkçe yerelde 8080 → "8.080" biçimlenmesin
                        Button { state.openPort(p) } label: { Text(verbatim: ":\(p)") }
                            .buttonStyle(.link)
                            .help("http://localhost:\(p) adresini aç")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let live, container.isRunning {
                    MemoryBar(stats: live)
                }
            }
            Spacer(minLength: 4)

            if busy {
                ProgressView().controlSize(.small)
            } else if hovering {
                actions
            } else if let live, container.isRunning {
                Text(String(format: "%.0f%%", live.cpuPercent))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("CPU")
            } else if !container.isRunning {
                Text(container.Status ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .confirmationDialog("\(container.name) silinsin mi?", isPresented: $confirmRemove) {
            Button("Sil", role: .destructive) { Task { await state.perform(.remove, on: container) } }
        } message: { Text("Konteyner zorla durdurulup silinecek. İsimli volume'ler korunur.") }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if container.isRunning {
                iconButton("stop.fill", "Durdur") { await state.perform(.stop, on: container) }
                iconButton("arrow.clockwise", "Yeniden başlat (belleği geri verir)") { await state.perform(.restart, on: container) }
            } else {
                iconButton("play.fill", "Başlat") { await state.perform(.start, on: container) }
            }
            Button(action: showLogs) { Image(systemName: "text.alignleft") }.help("Loglar")
            if container.isRunning {
                Button { state.openShell(container) } label: { Image(systemName: "terminal") }.help("Terminalde kabuk aç")
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
    }

    @ViewBuilder private var menuItems: some View {
        if container.isRunning {
            Button("Durdur") { Task { await state.perform(.stop, on: container) } }
            Button("Yeniden başlat") { Task { await state.perform(.restart, on: container) } }
            Button("Terminalde kabuk aç") { state.openShell(container) }
        } else {
            Button("Başlat") { Task { await state.perform(.start, on: container) } }
        }
        Button("Loglar", action: showLogs)
        if !container.publishedPorts.isEmpty {
            Menu("Portu aç") {
                ForEach(container.publishedPorts, id: \.self) { p in
                    Button { state.openPort(p) } label: { Text(verbatim: "localhost:\(p)") }
                }
            }
        }
        Divider()
        Button("Kimliği kopyala") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        }
        Button("Sil…", role: .destructive) { confirmRemove = true }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: symbol) }.help(help)
    }
}

struct MemoryBar: View {
    let stats: LiveStats

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: min(stats.memoryFraction, 1))
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: 90)
                .controlSize(.mini)
            Text("\(stats.memoryBytes.humanBytes) / \(stats.memoryLimit.humanBytes)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch stats.memoryFraction {
        case ..<0.6: .green
        case ..<0.85: .yellow
        default: .red
        }
    }
}
