import Foundation
import AppKit
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

    static func register() {
        UserDefaults.standard.register(defaults: [
            backend: Backend.apple.rawValue,
            autoStart: true,
            serviceAtLogin: true,
            stopRuntimeOnExit: true,
            syncContext: true,
            memThreshold: 0.85,
            autoRestart: false,
            checkUpdates: true,
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
            Task { await onBackendChanged(from: oldValue) }
        }
    }

    private(set) var containers: [ContainerSummary] = []
    private(set) var stats: [String: LiveStats] = [:]
    private(set) var hostMemory: UInt64 = 0
    private(set) var lastError: String?
    private(set) var busyContainers: Set<String> = []
    /// Log penceresinde gösterilecek konteyner kimliği.
    var logTargetID: String?

    private var prevCPU: [String: (usage: UInt64, at: Date)] = [:]
    private var warned: [String: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var lastSyncedContext: Backend?

    var client: DockerClient { DockerClient(socketPath: backend.socketPath) }
    var currentStatus: RuntimeStatus { service.status }
    var runningCount: Int { containers.filter(\.isRunning).count }

    var agentConfig: AgentConfig {
        AgentConfig(backend: backend, stopRuntimeOnExit: Prefs.bool(Prefs.stopRuntimeOnExit))
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
        backend = Backend(rawValue: UserDefaults.standard.string(forKey: Prefs.backend) ?? "") ?? .apple
    }

    // MARK: Yaşam döngüsü

    func bootstrap() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        Log.file("Liman \(updates.currentVersion) açıldı · bildirim izni: \(granted ? "var" : "yok")")
        await service.refresh(backend: backend)
        // Ajan başka bir arka uçla çalışıyorsa tray tercihini ona uydur (tek doğruluk kaynağı: ajan).
        if service.isLoaded, let a = service.agent, a.backend != backend {
            backend = a.backend
        }
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

    func quitStoppingService() async {
        await stopService()
        NSApp.terminate(nil)
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
        if service.status.isRunning, Prefs.bool(Prefs.syncContext), lastSyncedContext != backend {
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
            if lastError?.hasPrefix("Soket") == true || lastError?.hasPrefix("HTTP") == true { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshStats() async {
        let running = containers.filter(\.isRunning)
        guard !running.isEmpty else { stats = [:]; return }
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
        await memoryWatchdog()
    }

    /// Apple Virtualization.framework'ün eksik ballooning desteği nedeniyle şişen konteynerleri uyarır / yeniden başlatır.
    private func memoryWatchdog() async {
        let threshold = UserDefaults.standard.double(forKey: Prefs.memThreshold)
        let autoRestart = Prefs.bool(Prefs.autoRestart)
        for c in containers where c.isRunning {
            guard let s = stats[c.id], s.memoryLimit > 0, s.memoryFraction >= threshold else { continue }
            if let last = warned[c.id], Date().timeIntervalSince(last) < 1800 { continue }
            warned[c.id] = Date()
            let pct = Int(s.memoryFraction * 100)
            if autoRestart {
                notify("\(c.name) yeniden başlatılıyor", "Bellek limitin %\(pct)'ine ulaştı (\(s.memoryBytes.humanBytes)).")
                await perform(.restart, on: c)
            } else {
                notify("\(c.name) bellek sınırına yakın", "%\(pct) · \(s.memoryBytes.humanBytes) / \(s.memoryLimit.humanBytes). Yeniden başlatmak belleği macOS'a geri verir.")
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
        for c in containers where c.isRunning { await perform(.stop, on: c) }
    }

    func openPort(_ port: Int) {
        if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) }
    }

    func openAgentLog() {
        NSWorkspace.shared.open(LimanPaths.agentLog)
    }

    /// Terminal.app'te `docker exec -it <ad> sh` açar (otomasyon izni gerektirmeyen .command yöntemi).
    func openShell(_ c: ContainerSummary) {
        guard let docker = service.dockerCLI else { lastError = "docker CLI bulunamadı (brew install docker)"; return }
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

    /// Tray uygulamasının kendisi (menü çubuğu simgesi) oturum açılışında açılsın mı.
    var launchUIAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { lastError = "Oturum öğesi: \(error.localizedDescription)" }
        }
    }

    func setServiceAtLogin(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Prefs.serviceAtLogin)
        await service.setStartAtLogin(on)
    }
}
