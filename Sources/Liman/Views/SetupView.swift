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

    /// Colima Docker CLI'ı içermez; `docker` / `docker compose` için birlikte kurulur.
    private var formulas: [String] { backend == .apple ? ["container"] : ["colima", "docker", "docker-compose"] }
    private var formula: String { formulas.joined(separator: " ") }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("\(backend.title) kurulu değil", "\(backend.title) is not installed"), systemImage: "shippingbox.and.arrow.backward")
                .font(.headline)
            Text(LocalizedStringKey(backend == .apple
                 ? L("Apple'ın açık kaynak `container` aracı gerekiyor (macOS 26, Apple Silicon).",
                     "Requires Apple's open-source `container` tool (macOS 26, Apple Silicon).")
                 : L("Varsayılan çalışma zamanı Colima: tek bir Linux VM'de tam Docker uyumluluğu. Apple container'a Ayarlar'dan geçebilirsiniz.",
                     "The default runtime is Colima: full Docker compatibility in a single Linux VM. You can switch to Apple container in Settings.")))
                .font(.caption).foregroundStyle(.secondary)

            if let brew = Tools.find("brew") {
                Button {
                    installing = true
                    Task {
                        let r = await Shell.run(brew, ["install"] + formulas, timeout: 1800)
                        installLog = String(r.combined.suffix(400))
                        installing = false
                        await state.service.refresh(backend: backend)
                    }
                } label: {
                    if installing { ProgressView().controlSize(.small) }
                    Text(installing ? L("Kuruluyor…", "Installing…") : L("Homebrew ile kur (brew install \(formula))", "Install with Homebrew (brew install \(formula))"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing)
            } else {
                Text(L("Homebrew bulunamadı. Terminalde:", "Homebrew not found. In Terminal:")).font(.caption)
                Text(verbatim: "brew install \(formula)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if backend == .apple {
                Link(L("Ya da Apple'ın imzalı .pkg kurulumunu indirin →", "Or download Apple's signed .pkg installer →"),
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
            Label(L("Linux çekirdeği gerekli", "Linux kernel required"), systemImage: "cpu")
                .font(.headline)
            Text(L("Apple container her konteyneri hafif bir VM'de çalıştırır ve bunun için bir kez ~650 MB'lık Kata çekirdek paketini indirir. İndirme kopsa da kaldığı yerden devam eder, SHA-256 ile doğrulanır.", "Apple container runs each container in a lightweight VM and downloads the ~650 MB Kata kernel bundle once for this. Interrupted downloads resume where they left off and are verified with SHA-256."))
                .font(.caption).foregroundStyle(.secondary)

            switch k.phase {
            case .idle, .failed:
                if case .failed(let m) = k.phase {
                    Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Button(L("Çekirdeği indir ve kur", "Download and install kernel")) { k.start(state: state) }
                    .buttonStyle(.borderedProminent)
            case .downloading:
                ProgressView(value: k.progress) {
                    Text(L("İndiriliyor… \(UInt64(max(k.received, 0)).humanBytes) / \(UInt64(max(k.total, 0)).humanBytes)", "Downloading… \(UInt64(max(k.received, 0)).humanBytes) / \(UInt64(max(k.total, 0)).humanBytes)"))
                        .font(.caption)
                } currentValueLabel: {
                    if k.bytesPerSecond > 0 {
                        Text(verbatim: "\(UInt64(k.bytesPerSecond).humanBytes)/s").font(.caption2.monospacedDigit())
                    }
                }
                Button(L("İptal", "Cancel"), role: .cancel) { k.cancel() }.controlSize(.small)
            case .verifying:
                ProgressView { Text(L("SHA-256 doğrulanıyor…", "Verifying SHA-256…")).font(.caption) }
            case .installing:
                ProgressView { Text(L("Çekirdek kuruluyor…", "Installing kernel…")).font(.caption) }
            case .done:
                Label(L("Çekirdek kuruldu", "Kernel installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}
