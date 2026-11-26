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
    @State private var uiAtLogin = false
    @State private var tab: String

    init(initialTab: String = "general") {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Genel", systemImage: "gearshape", value: "general") { general }
            Tab("Bellek", systemImage: "memorychip", value: "memory") { memory }
            Tab("Tanılama", systemImage: "stethoscope", value: "diagnostics") { diagnostics }
        }
        .frame(width: 540, height: 440)
        .onAppear { uiAtLogin = state.launchUIAtLogin }
    }

    private var general: some View {
        Form {
            Section("Arka plan servisi") {
                Toggle("Oturum açılışında servisi başlat", isOn: Binding(
                    get: { serviceAtLogin },
                    set: { v in Task { await state.setServiceAtLogin(v) } }))
                    .help("launchd ajanı (app.liman.agent) menü çubuğu uygulaması kapalıyken de çalışır.")
                Toggle("Liman açılınca servis kapalıysa başlat", isOn: $autoStart)
                Toggle("Servis durunca çalışma zamanını da kapat", isOn: $stopRuntimeOnExit)
                    .help("Açık: Durdur, `container system stop` / `colima stop` çalıştırır ve tüm konteynerler durur. Kapalı: yalnızca Docker API soketi kapanır.")
            }
            Section("Menü çubuğu") {
                Toggle("Oturum açılışında menü çubuğu simgesini göster", isOn: $uiAtLogin)
                    .onChange(of: uiAtLogin) { _, v in state.launchUIAtLogin = v }
                Toggle("`docker` CLI context'ini seçili arka uca eşitle", isOn: $syncContext)
                Toggle("GitHub'da yeni sürümleri denetle", isOn: $checkUpdates)
            }
            Section {
                Text("export DOCKER_HOST=unix://\(state.backend.socketPath)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: { Text("Liman'sız terminal kullanımı") }
        }
        .formStyle(.grouped)
    }

    private var memory: some View {
        Form {
            Section {
                LabeledContent("Uyarı eşiği") {
                    HStack {
                        Slider(value: $threshold, in: 0.5...0.98, step: 0.01).frame(width: 200)
                        Text(verbatim: "%\(Int(threshold * 100))").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Eşik aşılınca konteyneri otomatik yeniden başlat", isOn: $autoRestart)
            } footer: {
                Text("macOS Virtualization.framework, Linux'un serbest bıraktığı belleği host'a tam geri vermiyor (eksik ballooning). Apple container'da konteyneri yeniden başlatmak, VM'i yok edip belleği tamamen geri verir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var diagnostics: some View {
        let svc = state.service
        return Form {
            Section("Servis (launchd)") {
                LabeledContent("Durum", value: svc.status.label + (svc.status.detail.map { " — \($0)" } ?? ""))
                LabeledContent("launchd", value: svc.isLoaded ? "Yüklü (\(svc.service))" : "Yüklü değil")
                if let a = svc.agent, svc.isLoaded {
                    LabeledContent("Ajan", value: "pid \(a.pid) · sürüm \(a.version) · \(a.backend.title)")
                    LabeledContent("Toparlanma denemesi", value: "\(a.restarts)")
                }
                HStack {
                    Button("Servis logu") { state.openAgentLog() }
                    Button("Servis plist'i") { NSWorkspace.shared.activateFileViewerSelecting([LimanPaths.launchAgentPlist]) }
                    Spacer()
                    Button("Servisi kaldır", role: .destructive) { Task { await svc.uninstall(backend: state.backend) } }
                        .disabled(svc.status.isBusy)
                }
            }
            Section("Araçlar") {
                row("container", svc.containerCLI)
                row("socktainer", Tools.socktainer)
                row("LimanAgent", svc.agentExecutable)
                row("colima", svc.colimaCLI)
                row("docker CLI", svc.dockerCLI)
                LabeledContent("Linux çekirdeği", value: svc.hasKernel ? "Kurulu" : "Yok")
            }
            Section("Sürüm") {
                LabeledContent("Liman", value: state.updates.currentVersion)
                LabeledContent("GitHub deposu", value: state.updates.repo ?? "ayarlanmamış (LimanGitHubRepo)")
                if let l = state.updates.latest {
                    LabeledContent("Son yayın", value: l.tag_name)
                }
                Button("Şimdi denetle") { Task { await state.updates.check() } }
                    .disabled(state.updates.repo == nil)
            }
            if !svc.lastLog.isEmpty {
                Section("Son komut çıktısı") {
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
            Text(path ?? "bulunamadı")
                .font(.caption.monospaced())
                .foregroundStyle(path == nil ? .red : .secondary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
