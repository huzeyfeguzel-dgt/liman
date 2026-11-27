import SwiftUI
import LimanCore

/// Apple container'ın varsayılan CPU/bellek tahsisini yönetir (config.toml + builder VM).
struct ResourcesView: View {
    @Environment(AppState.self) private var state
    @State private var draft: ResourceConfig = .recommended
    @State private var manage = true
    @State private var loaded = false
    @State private var confirm = false
    @State private var applying = false

    private var maxCPU: Int { HostInfo.cpuCount }
    private var maxMem: Int { HostInfo.maxGuestMemoryMB }
    private var dirty: Bool { draft.clamped() != state.resources || manage != state.manageResources }
    private var runningApple: Bool { state.backend == .apple && state.service.isLoaded }

    var body: some View {
        Form {
            Section {
                Toggle(L("Apple container kaynaklarını Liman yönetsin", "Let Liman manage Apple container resources"), isOn: $manage)
                LabeledContent(L("Bu Mac", "This Mac")) {
                    Text(L("\(maxCPU) çekirdek · \(MemoryText.mb(HostInfo.memoryMB)) RAM", "\(maxCPU) cores · \(MemoryText.mb(HostInfo.memoryMB)) RAM"))
                }
            } footer: {
                Text(LocalizedStringKey(L("Kapalıyken Liman `~/.config/container/config.toml` dosyasına dokunmaz ve Apple'ın varsayılanları (konteyner 4 CPU / 1 GB, builder 2 CPU / 2 GB) geçerli olur.", "When off, Liman leaves `~/.config/container/config.toml` untouched and Apple's defaults apply (container 4 CPU / 1 GB, builder 2 CPU / 2 GB).")))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                cpuRow("CPU", value: $draft.containerCPUs)
                memoryRow(L("Bellek", "Memory"), value: $draft.containerMemoryMB, min: 256)
            } header: {
                Text(L("Konteyner varsayılanı", "Container default"))
            } footer: {
                Text(LocalizedStringKey(L("`docker run` / compose'da limit verilmediğinde her konteyner VM'ine bu değerler verilir. Bellek tembel ayrılır: limit, konteyner gerçekten kullanmadıkça RAM tüketmez. Konteyner bazında değiştirmek için `docker run --memory 4g --cpus 2` ya da compose'da `deploy.resources.limits` kullanın.", "Each container VM gets these values when `docker run` / compose sets no limits. Memory is allocated lazily: the limit consumes no RAM unless the container actually uses it. To override per container, use `docker run --memory 4g --cpus 2` or `deploy.resources.limits` in compose.")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!manage)

            Section {
                cpuRow("CPU", value: $draft.builderCPUs)
                memoryRow(L("Bellek", "Memory"), value: $draft.builderMemoryMB, min: 1024)
                if let b = BuilderInfo.current() {
                    LabeledContent(L("Mevcut builder", "Current builder")) {
                        Text(verbatim: "\(b.cpus) CPU · \(MemoryText.mb(b.memoryMB))")
                            .foregroundStyle(b.cpus == draft.builderCPUs && b.memoryMB == draft.builderMemoryMB ? Color.secondary : Color.orange)
                    }
                }
            } header: {
                Text(verbatim: "Builder (docker build, devcontainer)")
            } footer: {
                Text(LocalizedStringKey(L("`docker build` ve VS Code Dev Containers imajları tek bir BuildKit VM'inde derlenir. 2 GB'lık varsayılan, .NET SDK ve Node gibi büyük imajlarda build'in `StreamClosed … Cancel` hatasıyla kopmasına yol açıyor. Değer değişirse builder silinip yeni değerlerle yeniden oluşturulur.", "`docker build` and VS Code Dev Containers images are built in a single BuildKit VM. The 2 GB default makes builds of large images such as .NET SDK and Node fail with `StreamClosed … Cancel`. If the values change, the builder is deleted and recreated with them.")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!manage)

            Section {
                HStack {
                    Button(L("Önerilen değerler", "Recommended Values")) { draft = .recommended }
                    Button(L("Apple varsayılanları", "Apple Defaults")) { draft = .appleDefaults }
                    Spacer()
                    if applying { ProgressView().controlSize(.small) }
                    Button(L("Uygula", "Apply")) {
                        if runningApple && state.runningCount > 0 { confirm = true } else { apply() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(dirty || state.resourcesPending) || applying || state.currentStatus.isBusy)
                }
                status
            } footer: {
                Text(L("Uygulamak Apple container servislerini yeniden başlatır. Çalışan konteynerler durur, imajlar ve volume'ler korunur. Colima seçiliyken değerler kaydedilir ve Apple container'a geçince uygulanır.", "Applying restarts the Apple container services. Running containers stop; images and volumes are kept. While Colima is selected, values are saved and applied when you switch to Apple container."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            draft = state.resources; manage = state.manageResources; loaded = true
        }
        .confirmationDialog(L("Apple container servisleri yeniden başlatılsın mı?", "Restart Apple container services?"), isPresented: $confirm) {
            Button(L("Uygula ve yeniden başlat", "Apply and Restart"), role: .destructive) { apply() }
        } message: {
            Text(L("\(state.runningCount) çalışan konteyner durdurulacak.", "\(state.runningCount) running containers will be stopped."))
        }
    }

    @ViewBuilder private var status: some View {
        if let note = state.service.agent?.resourceNote, runningApple {
            Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        } else if state.resourcesPending {
            Label(L("Kaydedildi, henüz uygulanmadı.", "Saved, not yet applied."), systemImage: "clock").foregroundStyle(.orange).font(.caption)
        } else if let a = state.appliedResources {
            Label(L("Uygulandı: konteyner \(a.containerCPUs) CPU / \(MemoryText.mb(a.containerMemoryMB)), builder \(a.builderCPUs) CPU / \(MemoryText.mb(a.builderMemoryMB))", "Applied: container \(a.containerCPUs) CPU / \(MemoryText.mb(a.containerMemoryMB)), builder \(a.builderCPUs) CPU / \(MemoryText.mb(a.builderMemoryMB))"),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        } else if state.backend != .apple {
            Label(L("Colima seçili: değerler Apple container'a geçince uygulanır.", "Colima selected: values apply when you switch to Apple container."), systemImage: "info.circle")
                .foregroundStyle(.secondary).font(.caption)
        }
    }

    private func apply() {
        applying = true
        Task {
            await state.applyResources(draft, manage: manage)
            draft = state.resources
            applying = false
        }
    }

    private func cpuRow(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            Stepper(value: value, in: 1...maxCPU) {
                Text(L("\(value.wrappedValue) çekirdek", "\(value.wrappedValue) cores")).monospacedDigit()
            }
        }
    }

    private func memoryRow(_ title: String, value: Binding<Int>, min: Int) -> some View {
        let step = 256
        let upper = max(min + step, maxMem / step * step)
        return LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(value.wrappedValue) },
                                      set: { value.wrappedValue = Int(($0 / Double(step)).rounded()) * step }),
                       in: Double(min)...Double(upper), step: Double(step))
                    .frame(minWidth: 180, maxWidth: 260)
                Text(MemoryText.mb(value.wrappedValue)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
}
