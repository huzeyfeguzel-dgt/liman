import SwiftUI
import LimanCore

/// Eksik bileşenleri (CLI veya Linux çekirdeği) kurmaya yönlendiren ilk kurulum ekranı.
struct SetupView: View {
    @Environment(AppState.self) private var state
    let backend: Backend
    @State private var installing = false
    @State private var installLog = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state.currentStatus {
            case .notInstalled: notInstalled
            case .needsKernel: kernel
            default: EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formula: String { backend == .apple ? "container" : "colima" }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(backend.title) kurulu değil", systemImage: "shippingbox.and.arrow.backward")
                .font(.headline)
            Text(backend == .apple
                 ? "Apple'ın açık kaynak `container` aracı gerekiyor (macOS 26, Apple Silicon)."
                 : "Colima, tam Docker uyumluluğu gereken işler için yedek çalışma zamanıdır.")
                .font(.caption).foregroundStyle(.secondary)

            if let brew = Tools.find("brew") {
                Button {
                    installing = true
                    Task {
                        let r = await Shell.run(brew, ["install", formula], timeout: 1800)
                        installLog = String(r.combined.suffix(400))
                        installing = false
                        await state.service.refresh(backend: backend)
                    }
                } label: {
                    if installing { ProgressView().controlSize(.small) }
                    Text(installing ? "Kuruluyor…" : "Homebrew ile kur (brew install \(formula))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing)
            } else {
                Text("Homebrew bulunamadı. Terminalde:").font(.caption)
                Text("brew install \(formula)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if backend == .apple {
                Link("Ya da Apple'ın imzalı .pkg kurulumunu indirin →",
                     destination: URL(string: "https://github.com/apple/container/releases/latest")!)
                    .font(.caption)
            }
            if !installLog.isEmpty {
                Text(installLog).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var kernel: some View {
        let k = state.kernel
        return VStack(alignment: .leading, spacing: 10) {
            Label("Linux çekirdeği gerekli", systemImage: "cpu")
                .font(.headline)
            Text("Apple container her konteyneri hafif bir VM'de çalıştırır ve bunun için bir kez ~650 MB'lık Kata çekirdek paketini indirir. İndirme kopsa da kaldığı yerden devam eder, SHA-256 ile doğrulanır.")
                .font(.caption).foregroundStyle(.secondary)

            switch k.phase {
            case .idle, .failed:
                if case .failed(let m) = k.phase {
                    Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Button("Çekirdeği indir ve kur") { k.start(state: state) }
                    .buttonStyle(.borderedProminent)
            case .downloading:
                ProgressView(value: k.progress) {
                    Text("İndiriliyor… \(UInt64(max(k.received, 0)).humanBytes) / \(UInt64(max(k.total, 0)).humanBytes)")
                        .font(.caption)
                } currentValueLabel: {
                    if k.bytesPerSecond > 0 {
                        Text("\(UInt64(k.bytesPerSecond).humanBytes)/s").font(.caption2.monospacedDigit())
                    }
                }
                Button("İptal", role: .cancel) { k.cancel() }.controlSize(.small)
            case .verifying:
                ProgressView { Text("SHA-256 doğrulanıyor…").font(.caption) }
            case .installing:
                ProgressView { Text("Çekirdek kuruluyor…").font(.caption) }
            case .done:
                Label("Çekirdek kuruldu", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}
