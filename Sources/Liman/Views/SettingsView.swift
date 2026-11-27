import SwiftUI
import LimanCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(Prefs.autoStart) private var autoStart = true
    @AppStorage(Prefs.serviceAtLogin) private var serviceAtLogin = true
    @AppStorage(Prefs.stopRuntimeOnExit) private var stopRuntimeOnExit = true
    @AppStorage(Prefs.syncContext) private var syncContext = true
    @AppStorage(Prefs.memThreshold) private var threshold = 0.85
    @AppStorage(Prefs.autoRestart) private var autoRestart = false
    @AppStorage(Prefs.checkUpdates) private var checkUpdates = true
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Prefs.showInDock) private var showInDock = true
    @AppStorage(Loc.prefKey) private var language = AppLanguage.system.rawValue
    @State private var uiAtLogin = false
    @State private var tab: String
    // Kaynaklar sekmesi taslakları (Uygula'ya basılana kadar kaydedilmez).
    @State private var draftColima = ColimaResources.recommended
    @State private var draftManageColima = false
    @State private var draftApple = ResourceConfig.recommended
    @State private var draftManageApple = true
    @State private var dockerSees: DockerInfo?
    @State private var applying = false

    init(initialTab: String = "general") {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(L("Genel", "General"), systemImage: "gearshape", value: "general") { general }
            Tab(L("Kaynaklar", "Resources"), systemImage: "cpu", value: "resources") { resourcesTab }
            Tab(L("Bellek", "Memory"), systemImage: "memorychip", value: "memory") { memory }
            Tab(L("Tanılama", "Diagnostics"), systemImage: "stethoscope", value: "diagnostics") { diagnostics }
        }
        .frame(width: 540, height: 500)
        .onAppear {
            uiAtLogin = state.launchUIAtLogin
            draftColima = state.colimaResources
            draftManageColima = state.manageColima
            draftApple = state.resources
            draftManageApple = state.manageResources
        }
    }

    private var general: some View {
        Form {
            Section {
                // Etiket iki dilde: yanlış dile geçen kullanıcı da seçiciyi bulabilsin.
                Picker("Dil / Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                if language == AppLanguage.system.rawValue {
                    Text(L("macOS dil tercihini izler.", "Follows the macOS language preference."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Arka plan servisi", "Background service")) {
                Toggle(L("Oturum açılışında servisi başlat", "Start service at login"), isOn: Binding(
                    get: { serviceAtLogin },
                    set: { v in Task { await state.setServiceAtLogin(v) } }))
                    .help(L("launchd ajanı (app.liman.agent) Liman kapalıyken de çalışır.", "The launchd agent (app.liman.agent) runs even when Liman is closed."))
                Toggle(L("Liman açılınca servis kapalıysa başlat", "Start service when Liman opens if it's off"), isOn: $autoStart)
                    .help(L("launchd ajanı Liman penceresi ve menü çubuğu kapalıyken de çalışır.", "The launchd agent runs even when the Liman window and menu bar icon are closed."))
                Toggle(L("Servis durunca çalışma zamanını da kapat", "Also shut down the runtime when the service stops"), isOn: $stopRuntimeOnExit)
                    .help(L("Açık: Durdur, `container system stop` / `colima stop` çalıştırır ve tüm konteynerler durur. Kapalı: yalnızca Docker API soketi kapanır.", "On: Stop runs `container system stop` / `colima stop` and all containers stop. Off: only the Docker API socket is closed."))
            }
            Section(L("Uygulama", "App")) {
                Toggle(L("Oturum açılışında Liman'ı aç", "Open Liman at login"), isOn: $uiAtLogin)
                    .onChange(of: uiAtLogin) { _, v in state.launchUIAtLogin = v }
                Toggle(L("Menü çubuğu simgesini göster", "Show menu bar icon"), isOn: $showMenuBarIcon)
                    .disabled(!showInDock)
                    .onChange(of: showMenuBarIcon) { state.applyActivationPolicy() }
                Toggle(L("Dock'ta göster", "Show in Dock"), isOn: $showInDock)
                    .disabled(!showMenuBarIcon)
                    .help(L("Açıkken Dock simgesi ana pencere açık olduğu sürece görünür; pencere kapanınca Liman menü çubuğuna küçülür. Kapalıyken yalnızca menü çubuğunda yaşar. İkisinden biri açık kalmalı.", "When on, the Dock icon shows while the main window is open; closing the window minimizes Liman to the menu bar. When off, Liman lives only in the menu bar. One of the two must stay on."))
                    .onChange(of: showInDock) { state.applyActivationPolicy() }
                Toggle(isOn: $syncContext) { Text(LocalizedStringKey(L("`docker` CLI context'ini seçili arka uca eşitle", "Sync the `docker` CLI context to the selected backend"))) }
                Toggle(L("GitHub'da yeni sürümleri denetle", "Check GitHub for new versions"), isOn: $checkUpdates)
            }
            Section {
                Text(verbatim: "export DOCKER_HOST=unix://\(state.backend.socketPath)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: { Text(L("Liman'sız terminal kullanımı", "Terminal use without Liman")) }
        }
        .formStyle(.grouped)
    }

    // MARK: Kaynaklar

    private var resourcesTab: some View {
        Form {
            Section {
                LabeledContent(L("Bu Mac", "This Mac"), value: L("\(HostInfo.cpuCount) çekirdek · \(HostInfo.memoryMB / 1024) GB bellek", "\(HostInfo.cpuCount) cores · \(HostInfo.memoryMB / 1024) GB memory"))
                LabeledContent(L("Docker'ın gördüğü", "Visible to Docker")) {
                    if let i = dockerSees, let n = i.NCPU {
                        Text(verbatim: "\(n) CPU · \(UInt64(i.MemTotal ?? 0).humanBytes)")
                    } else {
                        Text(state.service.status.isRunning ? L("okunuyor…", "reading…") : L("servis çalışmıyor", "service not running")).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(LocalizedStringKey(L("`docker run --cpus` / devcontainer `runArgs` değerleri Docker'ın gördüğü CPU sayısını aşamaz.", "`docker run --cpus` / devcontainer `runArgs` values can't exceed the CPU count visible to Docker.")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch state.backend {
            case .colima: colimaSection
            case .apple: appleSection
            }
            Section {
                HStack {
                    Button(L("Önerilen değerler", "Recommended values")) {
                        switch state.backend {
                        case .colima: draftColima = .recommended
                        case .apple: draftApple = .recommended
                        }
                    }
                    Spacer()
                    if applying || state.service.status.isBusy { ProgressView().controlSize(.small) }
                    Button(L("Uygula ve yeniden başlat", "Apply and restart")) { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!resourcesDirty || applying)
                }
            } footer: {
                Text(L("Uygulamak çalışma zamanını yeniden başlatır; çalışan konteynerler durur.", "Applying restarts the runtime; running containers will stop."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: state.service.status.isRunning) {
            // Servis durumu değişince ve sekme açıkken periyodik olarak yenile.
            while !Task.isCancelled {
                dockerSees = state.service.status.isRunning ? try? await state.client.info() : nil
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var colimaSection: some View {
        Section {
            Toggle(L("Colima VM kaynaklarını Liman yönetsin", "Let Liman manage Colima VM resources"), isOn: $draftManageColima)
            Group {
                stepper("CPU", value: $draftColima.cpus, in: 1...HostInfo.cpuCount, unit: L("çekirdek", "cores"))
                stepper(L("Bellek", "Memory"), value: $draftColima.memoryGB, in: 1...ColimaResources.maxMemoryGB, unit: "GB")
                stepper(L("Disk", "Disk"), value: $draftColima.diskGB, in: 10...2048, step: 10, unit: "GB")
            }
            .disabled(!draftManageColima)
            if state.colimaPending {
                Label(L("Kaydedilen değerler henüz uygulanmadı.", "Saved values have not been applied yet."), systemImage: "clock").foregroundStyle(.orange)
            }
        } header: {
            Text("Colima VM")
        } footer: {
            Text(L("Tüm konteynerler bu VM'i paylaşır. Kapalıyken Liman ~/.colima/default/colima.yaml'a dokunmaz. Disk yalnızca büyütülebilir. macOS'a en az 2 GB bırakılır.", "All containers share this VM. When off, Liman doesn't touch ~/.colima/default/colima.yaml. Disk can only grow. At least 2 GB is left for macOS."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var appleSection: some View {
        Section {
            Toggle(L("Apple container varsayılanlarını Liman yönetsin", "Let Liman manage Apple container defaults"), isOn: $draftManageApple)
            Group {
                stepper(L("Konteyner CPU", "Container CPU"), value: $draftApple.containerCPUs, in: 1...HostInfo.cpuCount, unit: L("çekirdek", "cores"))
                stepper(L("Konteyner bellek", "Container memory"), value: $draftApple.containerMemoryMB, in: 256...HostInfo.maxGuestMemoryMB, step: 256, unit: "MB")
                stepper("Builder CPU", value: $draftApple.builderCPUs, in: 1...HostInfo.cpuCount, unit: L("çekirdek", "cores"))
                stepper(L("Builder bellek", "Builder memory"), value: $draftApple.builderMemoryMB, in: 1024...HostInfo.maxGuestMemoryMB, step: 512, unit: "MB")
            }
            .disabled(!draftManageApple)
            if state.resourcesPending {
                Label(L("Kaydedilen değerler henüz uygulanmadı.", "Saved values have not been applied yet."), systemImage: "clock").foregroundStyle(.orange)
            }
            if let note = state.service.agent?.resourceNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            }
        } header: {
            Text("Apple container")
        } footer: {
            Text(LocalizedStringKey(L("Her konteyner kendi VM'inde çalışır; bunlar `--cpus` / `--memory` verilmediğinde kullanılan varsayılanlardır. Builder, `docker build` ve devcontainer derlemelerini çalıştırır.", "Each container runs in its own VM; these are the defaults used when `--cpus` / `--memory` aren't given. The builder runs `docker build` and devcontainer builds.")))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(verbatim: "\(value.wrappedValue) \(unit)").monospacedDigit()
                Stepper(title, value: value, in: range, step: step).labelsHidden()
            }
        }
    }

    private var resourcesDirty: Bool {
        switch state.backend {
        case .colima: draftManageColima != state.manageColima || draftColima.clamped() != state.colimaResources || state.colimaPending
        case .apple: draftManageApple != state.manageResources || draftApple.clamped() != state.resources || state.resourcesPending
        }
    }

    private func apply() {
        applying = true
        Task {
            switch state.backend {
            case .colima: await state.applyColimaResources(draftColima, manage: draftManageColima)
            case .apple: await state.applyResources(draftApple, manage: draftManageApple)
            }
            applying = false
        }
    }

    private var memory: some View {
        Form {
            Section {
                LabeledContent(L("Uyarı eşiği", "Warning threshold")) {
                    HStack {
                        Slider(value: $threshold, in: 0.5...0.98, step: 0.01).frame(width: 200)
                        Text(verbatim: Fmt.percent(threshold * 100)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(L("Eşik aşılınca konteyneri otomatik yeniden başlat", "Automatically restart the container when the threshold is exceeded"), isOn: $autoRestart)
            } footer: {
                Text(L("macOS Virtualization.framework, Linux'un serbest bıraktığı belleği host'a tam geri vermiyor (eksik ballooning). Apple container'da konteyneri yeniden başlatmak, VM'i yok edip belleği tamamen geri verir.", "macOS Virtualization.framework doesn't fully return memory freed by Linux to the host (incomplete ballooning). With Apple container, restarting a container destroys its VM and fully returns the memory."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var diagnostics: some View {
        let svc = state.service
        return Form {
            Section(L("Servis (launchd)", "Service (launchd)")) {
                LabeledContent(L("Durum", "Status"), value: svc.status.label + (svc.status.detail.map { " — \($0)" } ?? ""))
                LabeledContent("launchd", value: svc.isLoaded ? L("Yüklü (\(svc.service))", "Loaded (\(svc.service))") : L("Yüklü değil", "Not loaded"))
                if let a = svc.agent, svc.isLoaded {
                    LabeledContent(L("Ajan", "Agent"), value: L("pid \(a.pid) · sürüm \(a.version) · \(a.backend.title)", "pid \(a.pid) · version \(a.version) · \(a.backend.title)"))
                    LabeledContent(L("Toparlanma denemesi", "Recovery attempts"), value: "\(a.restarts)")
                }
                HStack {
                    Button(L("Servis logu", "Service log")) { state.openAgentLog() }
                    Button(L("Servis plist'i", "Service plist")) { NSWorkspace.shared.activateFileViewerSelecting([LimanPaths.launchAgentPlist]) }
                    Spacer()
                    Button(L("Servisi kaldır", "Uninstall service"), role: .destructive) { Task { await svc.uninstall(backend: state.backend) } }
                        .disabled(svc.status.isBusy)
                }
            }
            Section(L("Araçlar", "Tools")) {
                row("container", svc.containerCLI)
                row("socktainer", Tools.socktainer)
                row("LimanAgent", svc.agentExecutable)
                row("colima", svc.colimaCLI)
                row("docker CLI", svc.dockerCLI)
                LabeledContent(L("Linux çekirdeği", "Linux kernel"), value: svc.hasKernel ? L("Kurulu", "Installed") : L("Yok", "Missing"))
            }
            Section(L("Sürüm", "Version")) {
                LabeledContent("Liman", value: state.updates.currentVersion)
                LabeledContent(L("GitHub deposu", "GitHub repository"), value: state.updates.repo ?? L("ayarlanmamış (LimanGitHubRepo)", "not set (LimanGitHubRepo)"))
                if let l = state.updates.latest {
                    LabeledContent(L("Son yayın", "Latest release"), value: l.tag_name)
                }
                Button(L("Şimdi denetle", "Check now")) { Task { await state.updates.check() } }
                    .disabled(state.updates.repo == nil)
            }
            if !svc.lastLog.isEmpty {
                Section(L("Son komut çıktısı", "Last command output")) {
                    ScrollView {
                        Text(svc.lastLog)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ name: String, _ path: String?) -> some View {
        LabeledContent(name) {
            Text(path ?? L("bulunamadı", "not found"))
                .font(.caption.monospaced())
                .foregroundStyle(path == nil ? .red : .secondary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
