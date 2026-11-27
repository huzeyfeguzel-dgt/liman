import Foundation
import AppKit
import SwiftUI
import Observation
import ServiceManagement
import UserNotifications
import os
import LimanCore

enum Log {
    static let app = Logger(subsystem: "app.liman.Liman", category: "app")

    /// Birleşik log'a ek olarak ~/Library/Logs/Liman/app.log dosyasına da yazar (destek/hata ayıklama için).
    static func file(_ message: String) {
        app.notice("\(message, privacy: .public)")
        LimanPaths.ensureDirs()
        let url = LimanPaths.logsDir.appendingPathComponent("app.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum Prefs {
    static let backend = "backend"
    static let autoStart = "autoStartService"
    static let serviceAtLogin = "serviceAtLogin"
    static let stopRuntimeOnExit = "stopRuntimeOnServiceStop"
    static let syncContext = "syncDockerContext"
    static let memThreshold = "memoryWarningThreshold"
    static let autoRestart = "autoRestartOnMemory"
    static let checkUpdates = "checkUpdates"
    static let manageResources = "manageResources"
    static let resources = "resourceConfig"
    static let manageColima = "manageColimaResources"
    static let colimaResources = "colimaResources"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let showInDock = "showInDock"

    static func register() {
        UserDefaults.standard.register(defaults: [
            backend: Backend.defaultBackend.rawValue,
            autoStart: true,
            serviceAtLogin: true,
            stopRuntimeOnExit: true,
            syncContext: true,
            memThreshold: 0.85,
            autoRestart: false,
            checkUpdates: true,
            manageResources: true,
            // Varsayılan kapalı: kullanıcının elle ayarladığı colima.yaml'ı sessizce değiştirme.
            manageColima: false,
            showMenuBarIcon: true,
            showInDock: true,
        ])
    }

    static var bool: (String) -> Bool { UserDefaults.standard.bool(forKey:) }
}

@MainActor
@Observable
final class AppState {
    let service = ServiceController()
    let kernel = KernelInstaller()
    let updates = UpdateChecker()

    var backend: Backend {
        didSet {
            guard backend != oldValue else { return }
            UserDefaults.standard.set(backend.rawValue, forKey: Prefs.backend)
            containers = []; stats = [:]
            // Ajanın zaten kullandığı arka ucu benimserken servisi yeniden başlatma.
            if adoptingAgentBackend { return }
            Task { await onBackendChanged(from: oldValue) }
        }
    }

    private(set) var containers: [ContainerSummary] = []
    private(set) var stats: [String: LiveStats] = [:]
    private(set) var hostMemory: UInt64 = 0
    private(set) var lastError: String?
    private(set) var busyContainers: Set<String> = []
    /// Log ekranında gösterilecek konteyner kimliği.
    var logTargetID: String?
    /// Ana penceredeki seçili sayfa (menü çubuğundan da yönlendirilir).
    var page: MainPage? = .overview

    /// Apple container varsayılan kaynakları (kaydedilmiş istek; uygulanana kadar ajan eskisini kullanır).
    private(set) var resources: ResourceConfig
    var manageResources: Bool {
        didSet { UserDefaults.standard.set(manageResources, forKey: Prefs.manageResources) }
    }

    /// SwiftUI'nin pencere açma eylemi; Dock simgesine tıklanınca ana pencereyi yeniden açmak için saklanır.
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    /// Colima VM kaynakları (kaydedilmiş istek).
    private(set) var colimaResources: ColimaResources
    var manageColima: Bool {
        didSet { UserDefaults.standard.set(manageColima, forKey: Prefs.manageColima) }
    }

    private var prevCPU: [String: (usage: UInt64, at: Date)] = [:]
    private var warned: [String: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var lastSyncedContext: Backend?

    var client: DockerClient { DockerClient(socketPath: backend.socketPath) }
    var currentStatus: RuntimeStatus { service.status }
    var runningCount: Int { containers.filter(\.isRunning).count }

    var agentConfig: AgentConfig {
        AgentConfig(backend: backend, stopRuntimeOnExit: Prefs.bool(Prefs.stopRuntimeOnExit),
                    resources: manageResources ? resources.clamped() : nil,
                    colima: manageColima ? colimaResources.clamped() : nil)
    }

    /// Ajanın şu an kullandığı kaynaklar (yalnızca Apple container çalışırken anlamlı).
    var appliedResources: ResourceConfig? {
        guard service.isLoaded, let a = service.agent, a.backend == .apple else { return nil }
        return a.appliedResources
    }

    /// Kaydedilen kaynaklar henüz çalışma zamanına uygulanmadı mı?
    var resourcesPending: Bool {
        guard manageResources, backend == .apple, service.status.isRunning else { return false }
        return appliedResources != resources.clamped()
    }

    var appliedColima: ColimaResources? {
        guard service.isLoaded, let a = service.agent, a.backend == .colima else { return nil }
        return a.appliedColima
    }

    var colimaPending: Bool {
        guard manageColima, backend == .colima, service.status.isRunning else { return false }
        return appliedColima != colimaResources.clamped()
    }

    private var serviceAtLogin: Bool { Prefs.bool(Prefs.serviceAtLogin) }

    var groupedContainers: [(project: String?, items: [ContainerSummary])] {
        let groups = Dictionary(grouping: containers, by: { $0.composeProject })
        return groups.keys.sorted { ($0 ?? "~") < ($1 ?? "~") }.map { key in
            (key, groups[key]!.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) })
        }
    }

    init() {
        Prefs.register()
        Self.migrateBackendDefault()
        backend = Backend(rawValue: UserDefaults.standard.string(forKey: Prefs.backend) ?? "") ?? .defaultBackend
        manageResources = Prefs.bool(Prefs.manageResources)
        if let d = UserDefaults.standard.data(forKey: Prefs.resources),
           let r = try? JSONDecoder().decode(ResourceConfig.self, from: d) {
            resources = r
        } else {
            resources = .recommended
        }
        manageColima = Prefs.bool(Prefs.manageColima)
        if let d = UserDefaults.standard.data(forKey: Prefs.colimaResources),
           let r = try? JSONDecoder().decode(ColimaResources.self, from: d) {
            colimaResources = r
        } else {
            colimaResources = .recommended
        }
    }

    /// 0.2.0'da varsayılan arka uç Apple container → Colima oldu. Arka ucu hiç elle seçmemiş mevcut kullanıcılar
    /// (tercih kaydı yok ama ajan yapılandırması var) sessizce Colima'ya geçmesin: kullandıkları arka ucu sabitle.
    private static func migrateBackendDefault() {
        let d = UserDefaults.standard
        guard d.object(forKey: Prefs.backend) == nil,
              FileManager.default.fileExists(atPath: LimanPaths.config.path) else { return }
        let existing = AgentConfig.load().backend
        d.set(existing.rawValue, forKey: Prefs.backend)
        Log.file("arka uç tercihi mevcut kurulumdan korundu: \(existing.rawValue)")
    }

    // MARK: Kaynaklar

    /// Yeni kaynak değerlerini kaydeder ve servis çalışıyorsa uygular.
    /// Ajan config.toml'u yazar; içerik değiştiyse Apple container servislerini yeniden başlatır
    /// (çalışan konteynerler durur) ve builder'ı yeni değerlerle yeniden oluşturur.
    func applyResources(_ r: ResourceConfig, manage: Bool) async {
        resources = r.clamped()
        manageResources = manage
        if let d = try? JSONEncoder().encode(resources) { UserDefaults.standard.set(d, forKey: Prefs.resources) }
        Log.file("kaynaklar: yönet=\(manage) konteyner \(resources.containerCPUs) CPU/\(resources.containerMemoryMB) MB, builder \(resources.builderCPUs) CPU/\(resources.builderMemoryMB) MB")
        if service.isLoaded {
            await restartService()
        } else {
            try? agentConfig.save()
        }
    }

    /// Colima VM kaynaklarını kaydeder; servis çalışıyorsa ajanı yeniden başlatır.
    /// Yeni ajan VM boyutu farklıysa `colima stop` + `colima start --cpus … --memory …` yapar (konteynerler durur).
    func applyColimaResources(_ r: ColimaResources, manage: Bool) async {
        colimaResources = r.clamped()
        manageColima = manage
        if let d = try? JSONEncoder().encode(colimaResources) { UserDefaults.standard.set(d, forKey: Prefs.colimaResources) }
        Log.file("colima kaynakları: yönet=\(manage) \(colimaResources.cpus) CPU / \(colimaResources.memoryGB) GB / \(colimaResources.diskGB) GB disk")
        if service.isLoaded {
            await restartService()
        } else {
            try? agentConfig.save()
        }
    }

    // MARK: Pencere

    /// Ana pencere ekranda mı? Kapalıyken uygulama yalnızca menü çubuğunda (tray) yaşar.
    @ObservationIgnored var mainWindowVisible = false {
        didSet { if mainWindowVisible != oldValue { applyActivationPolicy() } }
    }

    /// Menü çubuğu simgesi açıksa pencere kapatıldığında / ⌘Q'da uygulama tray'e küçülür.
    var minimizesToTray: Bool { Prefs.bool(Prefs.showMenuBarIcon) && !isQuitting }

    func openMainWindow(_ page: MainPage? = nil) {
        if let page { self.page = page }
        // Tray'deyken (accessory) Dock simgesi ve uygulama menüsü pencereyle birlikte geri gelsin.
        if Prefs.bool(Prefs.showInDock) { NSApp.setActivationPolicy(.regular) }
        openWindowAction?(id: "main")
        NSApp.activate()
    }

    /// Açık pencereleri kapatır; uygulama, servis ve motor menü çubuğunda çalışmaya devam eder.
    func minimizeToTray() {
        for w in NSApp.windows where w.isVisible && !(w is NSPanel) && w.styleMask.contains(.titled) {
            w.close()
        }
        mainWindowVisible = false
    }

    /// Dock simgesi yalnızca ana pencere açıkken (ve tercih açıksa) görünür; pencere kapanınca uygulama tray'e iner.
    /// Menü çubuğu simgesi kapalıysa uygulamaya ulaşılamayacağı için Dock her zaman açık kalır.
    func applyActivationPolicy() {
        let tray = Prefs.bool(Prefs.showMenuBarIcon)
        let dock = !tray || (Prefs.bool(Prefs.showInDock) && mainWindowVisible)
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
    }

    // MARK: Yaşam döngüsü

    /// true iken `backend` değişimi servisi yeniden başlatmaz (ajanın arka ucunu benimseme).
    @ObservationIgnored private var adoptingAgentBackend = false

    private func adoptAgentBackend() {
        guard service.isLoaded, let a = service.agent, a.backend != backend else { return }
        adoptingAgentBackend = true
        backend = a.backend
        adoptingAgentBackend = false
    }

    /// Önizleme/test: servise dokunmadan yalnızca durumu okur (plist, launchctl, docker context değişmez).
    var readOnly = false

    func bootstrap() async {
        if readOnly {
            await service.refresh(backend: backend)
            adoptAgentBackend()
            startPolling()
            return
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        Log.file("Liman \(updates.currentVersion) açıldı · bildirim izni: \(granted ? "var" : "yok")")
        await service.refresh(backend: backend)
        // Ajan başka bir arka uçla çalışıyorsa tray tercihini ona uydur (tek doğruluk kaynağı: ajan).
        adoptAgentBackend()
        await service.reconcile(config: agentConfig, startAtLogin: serviceAtLogin)
        if Prefs.bool(Prefs.autoStart), service.status == .stopped {
            await startService()
        }
        startPolling()
        if Prefs.bool(Prefs.checkUpdates) { await updates.check() }
    }

    /// Yalnızca arayüz kapanır; arka plan servisi çalışmaya devam eder.
    func shutdownUI() { pollTask?.cancel() }

    func startService() async {
        lastError = nil
        await service.start(config: agentConfig, startAtLogin: serviceAtLogin)
        await afterStatusChange()
    }

    func stopService() async {
        await service.stop(backend: backend)
        containers = []; stats = [:]
    }

    func restartService() async {
        await service.restart(config: agentConfig, startAtLogin: serviceAtLogin)
        await afterStatusChange()
    }

    func toggleService() async {
        if service.isLoaded { await stopService() } else { await startService() }
    }

    /// Tam kapanış sürüyor mu? (tekrar tetiklenmeyi ve yoklamanın servisi yeniden başlatmasını önler)
    private(set) var isQuitting = false

    /// Uygulamayı tamamen kapatır: arka plan servisi, socktainer ve çalışma zamanı (Apple container / Colima)
    /// durdurulur, ardından uygulama çıkar. Yalnızca tray menüsünden (ya da tray yokken ⌘Q ile) tetiklenir.
    func quitFully() async {
        guard !isQuitting else { return }
        isQuitting = true
        Log.file("tam kapanış istendi: servis ve çalışma zamanı durduruluyor")
        pollTask?.cancel()
        minimizeToTray()
        if !readOnly {
            if service.isLoaded {
                // Kullanıcı tercihi ne olursa olsun bu kapanışta motor da dursun; ajan kapanırken bunu okur.
                // Sonraki başlatmada start() tercihlerden yeni yapılandırma yazar.
                var c = AgentConfig.load()
                c.stopRuntimeOnExit = true
                try? c.save()
                await service.stop(backend: backend)
            } else {
                // Servis zaten kapalı ama çalışma zamanı ("çalışma zamanını kapat" tercihi kapalıyken) açık kalmış olabilir.
                await stopRuntimeDirectly()
            }
            containers = []; stats = [:]
        }
        Log.file("tam kapanış tamamlandı")
        NSApp.terminate(nil)
    }

    private func stopRuntimeDirectly() async {
        switch backend {
        case .apple:
            if let cli = Tools.find("container") {
                let r = await Shell.run(cli, ["system", "stop"], timeout: 100)
                Log.file("container system stop → \(r.code)")
            }
        case .colima:
            if let cli = Tools.find("colima") {
                let r = await Shell.run(cli, ["stop"], timeout: 100)
                Log.file("colima stop → \(r.code)")
            }
        }
    }

    private func onBackendChanged(from old: Backend) async {
        lastSyncedContext = nil
        if service.isLoaded {
            // Ajan tek arka uç yönetir: eski çalışma zamanını kapatıp yenisini başlatır.
            // Kapanışta eski arka ucun yapılandırması okunsun diye önce durdur, sonra yeni arka uçla başlat.
            await service.restart(config: agentConfig, startAtLogin: serviceAtLogin, keepRuntime: false)
            await afterStatusChange()
        } else {
            await service.refresh(backend: backend)
        }
    }

    private func afterStatusChange() async {
        if !readOnly, service.status.isRunning, Prefs.bool(Prefs.syncContext), lastSyncedContext != backend {
            await service.syncDockerContext(to: backend)
            lastSyncedContext = backend
        }
        await refreshContainers()
    }

    // MARK: Yoklama

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let wasRunning = self.service.status.isRunning
                // launchctl'ı her 3. turda, durum dosyasını her turda oku.
                await self.service.refresh(checkLaunchd: tick % 3 == 0 || self.service.status.isBusy, backend: self.backend)
                if self.service.status.isRunning != wasRunning || (self.service.status.isRunning && self.lastSyncedContext != self.backend) {
                    await self.afterStatusChange()
                } else {
                    await self.refreshContainers()
                }
                if tick % 2 == 0 { await self.refreshStats() }
                self.hostMemory = HostMemory.virtualizationFootprint()
                if tick % 28800 == 28799, Prefs.bool(Prefs.checkUpdates) { await self.updates.check() } // ~24 saat
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshContainers() async {
        guard service.status.isRunning else { containers = []; return }
        do {
            containers = try await client.containers()
            if lastError?.hasPrefix("Soket") == true || lastError?.hasPrefix("Socket") == true || lastError?.hasPrefix("HTTP") == true { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshStats() async {
        let running = containers.filter(\.isRunning)
        guard !running.isEmpty else { stats = [:]; recordSample(); return }
        let c = client
        let results = await withTaskGroup(of: (String, ContainerStats?).self) { group in
            for item in running { group.addTask { (item.id, try? await c.stats(item.id)) } }
            var out: [(String, ContainerStats?)] = []
            for await r in group { out.append(r) }
            return out
        }
        var next: [String: LiveStats] = [:]
        let now = Date()
        for (id, s) in results {
            guard let s else { continue }
            var live = LiveStats(memoryBytes: s.memory_stats?.usage ?? 0, memoryLimit: s.memory_stats?.limit ?? 0)
            if let usage = s.cpu_stats?.cpu_usage?.total_usage {
                if let prev = prevCPU[id], usage >= prev.usage {
                    let wall = now.timeIntervalSince(prev.at) * 1e9
                    if wall > 0 { live.cpuPercent = Double(usage - prev.usage) / wall * 100 }
                }
                prevCPU[id] = (usage, now)
            }
            next[id] = live
        }
        stats = next
        recordSample()
        await memoryWatchdog()
    }

    /// Apple Virtualization.framework'ün eksik ballooning desteği nedeniyle şişen konteynerleri uyarır / yeniden başlatır.
    private func memoryWatchdog() async {
        // Bozuk/eksik tercih değeri düşük bellekte yanlış alarm üretmesin.
        let stored = UserDefaults.standard.double(forKey: Prefs.memThreshold)
        let threshold = (0.5...0.99).contains(stored) ? stored : 0.85
        let autoRestart = Prefs.bool(Prefs.autoRestart)
        for c in containers where c.isRunning {
            guard let s = stats[c.id], s.memoryLimit > 0, s.memoryFraction >= threshold else { continue }
            if let last = warned[c.id], Date().timeIntervalSince(last) < 1800 { continue }
            warned[c.id] = Date()
            let pct = Int(s.memoryFraction * 100)
            if autoRestart {
                notify(L("\(c.name) yeniden başlatılıyor", "Restarting \(c.name)"),
                       L("Bellek limitin %\(pct)'ine ulaştı (\(s.memoryBytes.humanBytes)).", "Memory reached \(pct)% of the limit (\(s.memoryBytes.humanBytes))."))
                await perform(.restart, on: c)
            } else {
                notify(L("\(c.name) bellek sınırına yakın", "\(c.name) is near its memory limit"),
                       L("\(Fmt.percent(Double(pct))) · \(s.memoryBytes.humanBytes) / \(s.memoryLimit.humanBytes). Yeniden başlatmak belleği macOS'a geri verir.", "\(Fmt.percent(Double(pct))) · \(s.memoryBytes.humanBytes) / \(s.memoryLimit.humanBytes). Restarting returns the memory to macOS."))
            }
        }
    }

    private func notify(_ title: String, _ body: String) {
        Log.file("bildirim: \(title) — \(body)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { Log.file("bildirim gönderilemedi: \(error.localizedDescription)") }
        }
    }

    // MARK: Konteyner eylemleri

    enum Action { case start, stop, restart, remove }

    /// Genel bakış grafikleri için kaynak geçmişi (~6 s'de bir, son ~15 dakika).
    private(set) var history: [ResourceSample] = []
    static let historyLimit = 150

    /// Tüm konteynerlerin CPU toplamı, host'un toplam CPU kapasitesine oranla (0–100).
    var totalCPUPercent: Double {
        stats.values.reduce(0) { $0 + $1.cpuPercent } / Double(max(HostInfo.cpuCount, 1))
    }
    var totalContainerMemory: UInt64 { stats.values.reduce(0) { $0 + $1.memoryBytes } }

    private func recordSample() {
        let s = ResourceSample(date: Date(), cpuPercent: totalCPUPercent, containerMemory: totalContainerMemory,
                               hostVMMemory: HostMemory.virtualizationFootprint(), running: runningCount)
        history.append(s)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// Birden fazla konteynere aynı eylemi paralel uygular (çoklu seçim, compose projesi).
    func performBulk(_ action: Action, on items: [ContainerSummary]) async {
        let targets = items.filter { c in
            switch action {
            case .start: !c.isRunning
            case .stop, .restart: c.isRunning
            case .remove: true
            }
        }
        guard !targets.isEmpty else { return }
        for c in targets { busyContainers.insert(c.id) }
        let cl = client
        let errors = await withTaskGroup(of: String?.self) { group in
            for c in targets {
                group.addTask {
                    do { try await Self.run(action, id: c.id, client: cl); return nil }
                    catch { return "\(c.name): \(error.localizedDescription)" }
                }
            }
            var out: [String] = []
            for await e in group { if let e { out.append(e) } }
            return out
        }
        for c in targets { busyContainers.remove(c.id) }
        lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")
        Log.file("toplu \(action): \(targets.count) konteyner, \(errors.count) hata")
        await refreshContainers()
    }

    nonisolated private static func run(_ action: Action, id: String, client: DockerClient) async throws {
        switch action {
        case .start: try await client.start(id)
        case .stop: try await client.stop(id)
        case .restart: try await client.restart(id)
        case .remove: try await client.remove(id)
        }
    }

    func perform(_ action: Action, on c: ContainerSummary) async {
        busyContainers.insert(c.id)
        defer { busyContainers.remove(c.id) }
        do {
            switch action {
            case .start: try await client.start(c.id)
            case .stop: try await client.stop(c.id)
            case .restart: try await client.restart(c.id)
            case .remove: try await client.remove(c.id)
            }
            lastError = nil
        } catch {
            lastError = "\(c.name): \(error.localizedDescription)"
        }
        await refreshContainers()
    }

    func stopAll() async {
        await performBulk(.stop, on: containers)
    }

    func openPort(_ port: Int) {
        if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) }
    }

    func openAgentLog() {
        NSWorkspace.shared.open(LimanPaths.agentLog)
    }

    /// Terminal.app'te `docker exec -it <ad> sh` açar (otomasyon izni gerektirmeyen .command yöntemi).
    func openShell(_ c: ContainerSummary) {
        guard let docker = service.dockerCLI else { lastError = L("docker CLI bulunamadı (brew install docker)", "docker CLI not found (brew install docker)"); return }
        let script = """
        #!/bin/zsh
        export DOCKER_HOST="unix://\(backend.socketPath)"
        echo "Liman → \(c.name) (\(backend.title))"
        "\(docker)" exec -it "\(c.name)" sh -c 'command -v bash >/dev/null && exec bash || exec sh'
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("liman-\(c.name).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { lastError = error.localizedDescription }
    }

    // MARK: Oturum açılışı

    /// Liman uygulamasının kendisi oturum açılışında açılsın mı.
    var launchUIAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { lastError = L("Oturum öğesi: \(error.localizedDescription)", "Login item: \(error.localizedDescription)") }
        }
    }

    func setServiceAtLogin(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Prefs.serviceAtLogin)
        await service.setStartAtLogin(on)
    }
}
