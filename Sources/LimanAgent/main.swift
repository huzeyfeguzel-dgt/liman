// LimanAgent — launchd altında çalışan arka plan denetleyicisi.
//
// Seçili çalışma zamanını (Apple container + socktainer ya da Colima) ayakta tutar, çökerse yeniden başlatır,
// durumunu ~/Library/Application Support/Liman/agent-status.json dosyasına yazar.
// SIGTERM (launchctl bootout / tray'den "Durdur") alınca çalışma zamanını düzgünce kapatıp çıkar.
import Foundation
import Darwin
import LimanCore

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
}

final class Supervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var socktainer: Process?
    private var status: AgentStatus
    private let config = AgentConfig.load()
    private var consecutiveFailures = 0
    /// Kaynak ayarları (config.toml + builder) bu ajan çalıştırmasında bir kez uygulanır.
    private var resourcesApplied = false
    /// Colima VM boyutu bu ajan çalıştırmasında doğrulandı/uygulandı mı?
    private var colimaApplied = false

    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    init() {
        status = AgentStatus(state: .starting, backend: config.backend, pid: getpid(),
                             startedAt: Date(), version: Self.version)
    }

    // MARK: Durum

    private func set(_ state: AgentState, _ message: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if state == .running, status.state != .running { status.runningSince = Date() }
        if state != .running { status.runningSince = nil }
        if status.state != state || status.message != message {
            log("durum: \(state.rawValue)\(message.map { " — \($0)" } ?? "")")
        }
        status.state = state
        status.message = message
        status.updatedAt = Date()
        status.save()
    }

    private func heartbeat() {
        lock.lock(); defer { lock.unlock() }
        status.updatedAt = Date()
        status.save()
    }

    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    // MARK: Ana döngü

    func run() {
        log("LimanAgent \(Self.version) başladı (pid \(getpid()), arka uç: \(config.backend.rawValue))")
        set(.starting)
        Thread.detachNewThread { [self] in
            while !isStopping {
                tick()
                // Hata durumunda geri çekil (5 s → en fazla 60 s); sağlıklıyken 5 s'de bir kontrol.
                let wait = consecutiveFailures == 0 ? 5.0 : min(5.0 * pow(2, Double(consecutiveFailures - 1)), 60)
                var waited = 0.0
                while waited < wait && !isStopping { Thread.sleep(forTimeInterval: 1); waited += 1; if waited.truncatingRemainder(dividingBy: 5) == 0 { heartbeat() } }
            }
        }
    }

    private func tick() {
        switch config.backend {
        case .apple: tickApple()
        case .colima: tickColima()
        }
    }

    private func tickApple() {
        guard let cli = Tools.find("container") else { set(.notInstalled, L("container CLI bulunamadı", "container CLI not found")); return fail() }
        guard LimanPaths.hasAppleKernel else { set(.needsKernel, L("Linux çekirdeği kurulu değil", "Linux kernel not installed")); return fail() }

        let client = DockerClient(socketPath: Backend.apple.socketPath)
        // Kaynaklar henüz uygulanmadıysa hızlı yoldan dönme: önce config.toml ve builder uzlaştırılmalı.
        if client.pingSync() && (resourcesApplied || config.resources == nil) {
            if status.state != .running { set(.running) } else { heartbeat() }
            consecutiveFailures = 0
            return
        }
        if status.state == .running { set(.starting, L("soket yanıt vermiyor, toparlanıyor", "socket not responding, recovering")) }

        // 0) Kaynak varsayılanları: config.toml'u yaz. Apple container bu dosyayı yalnızca açılışta okur.
        let resources = config.resources?.clamped()
        var tomlChanged = false
        if let r = resources, !resourcesApplied {
            do { tomlChanged = try ContainerSystemConfig.apply(r) }
            catch { log("config.toml yazılamadı: \(error.localizedDescription)"); setNote(L("config.toml yazılamadı: \(error.localizedDescription)", "Could not write config.toml: \(error.localizedDescription)")) }
            if tomlChanged { log("config.toml güncellendi: konteyner \(r.containerCPUs) CPU / \(r.containerMemoryMB) MB, builder \(r.builderCPUs) CPU / \(r.builderMemoryMB) MB") }
        }

        // 1) Apple container servisleri
        let st = Shell.runBlocking(cli, ["system", "status"], timeout: 15)
        let systemRunning = st.ok && st.out.contains("running")
        if systemRunning && tomlChanged {
            // Yeni varsayılanlar ancak servisler yeniden açılınca geçerli olur.
            set(.starting, L("kaynak ayarları uygulanıyor (container servisleri yeniden başlatılıyor)", "applying resource settings (restarting container services)"))
            stopSocktainer()
            let r = Shell.runBlocking(cli, ["system", "stop"], timeout: 100)
            log("container system stop (kaynak değişimi) → \(r.code)")
        }
        if !systemRunning || tomlChanged {
            set(.starting, L("container servisleri başlatılıyor", "starting container services"))
            let r = Shell.runBlocking(cli, ["system", "start", "--disable-kernel-install"], timeout: 180)
            if !r.ok { set(.failed, "container system start: \(r.err.suffix(200))"); return fail() }
        }
        if isStopping { return }

        // 1b) Builder VM'i config.toml'u yalnızca oluşturulurken okur; kayıtlı kaynakları farklıysa yeniden oluştur.
        if let r = resources, !resourcesApplied {
            reconcileBuilder(cli, r)
            resourcesApplied = true
            lock.lock(); status.appliedResources = r; lock.unlock()
        }
        if isStopping { return }

        // 2) socktainer (Docker API soketi)
        if socktainer?.isRunning != true {
            guard let bin = Tools.socktainer else { set(.failed, L("socktainer bulunamadı", "socktainer not found")); return fail() }
            set(.starting, L("socktainer başlatılıyor", "starting socktainer"))
            try? FileManager.default.removeItem(atPath: Backend.apple.socketPath)
            launchSocktainer(bin)
        }
        for _ in 0..<40 where !isStopping {
            if client.pingSync() { set(.running); consecutiveFailures = 0; return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        set(.failed, L("socktainer 10 s içinde yanıt vermedi", "socktainer did not respond within 10 s"))
        fail()
    }

    private func tickColima() {
        guard let cli = Tools.find("colima") else { set(.notInstalled, L("colima bulunamadı", "colima not found")); return fail() }
        let client = DockerClient(socketPath: Backend.colima.socketPath)
        let desired = config.colima?.clamped()
        let alive = client.pingSync()
        if alive && (colimaApplied || desired == nil) {
            if status.state != .running { set(.running) } else { heartbeat() }
            consecutiveFailures = 0
            return
        }

        // Kaynaklar: Colima VM boyutunu yalnızca açılışta alır. Farklıysa durdurup yeni değerlerle aç.
        var args = ["start"]
        if let d = desired {
            let cur = ColimaInfo.parse(Shell.runBlocking(cli, ["list", "--json"], timeout: 15).out)
            if alive {
                guard let cur, cur.needsChange(to: d) else {
                    // Zaten istenen boyutta (ya da okunamadı): çalışan VM'i boşuna yeniden başlatma.
                    markColimaApplied(d)
                    set(.running); consecutiveFailures = 0
                    return
                }
                set(.starting, L("Colima kaynakları uygulanıyor (\(d.cpus) CPU / \(d.memoryGB) GB, VM yeniden başlatılıyor)", "applying Colima resources (\(d.cpus) CPU / \(d.memoryGB) GB, restarting VM)"))
                log("colima kaynakları farklı (\(cur.cpus) CPU / \(cur.memoryGB) GB / \(cur.diskGB) GB disk), yeniden başlatılıyor")
                let r = Shell.runBlocking(cli, ["stop"], timeout: 120)
                log("colima stop (kaynak değişimi) → \(r.code)")
                if isStopping { return }
            }
            args += ["--cpus", "\(d.cpus)", "--memory", "\(d.memoryGB)"]
            // Disk küçültülemez; yalnızca büyütme ya da ilk oluşturma için ver.
            if cur == nil || d.diskGB > cur!.diskGB { args += ["--disk", "\(d.diskGB)"] }
        }

        set(.starting, L("colima VM'i başlatılıyor", "starting colima VM"))
        // colima start uzun sürebilir; sürerken heartbeat at ki tray ajanı ölü sanmasın.
        let hb = DispatchSource.makeTimerSource(queue: .global())
        hb.schedule(deadline: .now() + 5, repeating: 5)
        hb.setEventHandler { [weak self] in self?.heartbeat() }
        hb.resume()
        log("colima \(args.joined(separator: " "))")
        let r = Shell.runBlocking(cli, args, timeout: 1200)
        hb.cancel()
        if isStopping { return }
        if r.ok, client.pingSync() {
            if let d = desired { markColimaApplied(d) }
            set(.running); consecutiveFailures = 0
        }
        else { set(.failed, "colima start: \((r.err.isEmpty ? r.out : r.err).suffix(200))"); fail() }
    }

    private func markColimaApplied(_ r: ColimaResources) {
        colimaApplied = true
        lock.lock(); status.appliedColima = r; lock.unlock()
    }

    private func setNote(_ note: String?) {
        lock.lock(); status.resourceNote = note; lock.unlock()
    }

    /// Builder'ın (id: buildkit) kayıtlı CPU/bellek değeri istenenden farklıysa siler ve yeni değerlerle oluşturur.
    /// Builder hiç yoksa dokunmaz: ilk `docker build`'de config.toml'daki [build] değerleriyle oluşturulur.
    /// Not: çalışan bir build varsa kesilir. Bu yüzden yalnızca ajan açılışında (servis yeniden başlarken) çalışır.
    private func reconcileBuilder(_ cli: String, _ r: ResourceConfig) {
        guard let cur = BuilderInfo.current() else { setNote(nil); return }
        guard cur.cpus != r.builderCPUs || cur.memoryMB != r.builderMemoryMB else { setNote(nil); return }
        set(.starting, L("builder yeniden oluşturuluyor (\(r.builderCPUs) CPU / \(r.builderMemoryMB) MB)", "recreating builder (\(r.builderCPUs) CPU / \(r.builderMemoryMB) MB)"))
        log("builder kaynakları farklı (\(cur.cpus) CPU / \(cur.memoryMB) MB), yeniden oluşturuluyor")
        let del = Shell.runBlocking(cli, ["builder", "delete", "--force"], timeout: 90)
        log("container builder delete --force → \(del.code) \(del.combined.suffix(200))")
        let start = Shell.runBlocking(cli, ["builder", "start", "--cpus", "\(r.builderCPUs)", "--memory", "\(r.builderMemoryMB)M"], timeout: 300)
        log("container builder start → \(start.code) \(start.combined.suffix(200))")
        if start.ok {
            // Kayıtlı yapılandırma kalır; boşta RAM yemesin diye durdur. Sonraki build bu değerlerle açar.
            let stop = Shell.runBlocking(cli, ["builder", "stop"], timeout: 60)
            log("container builder stop → \(stop.code)")
            setNote(nil)
        } else {
            setNote(L("Builder yeniden oluşturulamadı: \(start.combined.suffix(160))", "Could not recreate builder: \(start.combined.suffix(160))"))
        }
    }

    private func stopSocktainer() {
        if let p = socktainer, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        socktainer = nil
    }

    private func fail() {
        consecutiveFailures += 1
        lock.lock(); status.restarts += 1; lock.unlock()
    }

    private func launchSocktainer(_ bin: String) {
        LimanPaths.ensureDirs()
        let logURL = LimanPaths.socktainerLog
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let fh = try? FileHandle(forWritingTo: logURL)
        _ = try? fh?.seekToEnd()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.environment = Tools.environment
        p.standardOutput = fh ?? FileHandle.nullDevice
        p.standardError = fh ?? FileHandle.nullDevice
        p.terminationHandler = { proc in log("socktainer çıktı (kod \(proc.terminationStatus))") }
        do { try p.run(); socktainer = p; log("socktainer başlatıldı (pid \(p.processIdentifier))") }
        catch { log("socktainer başlatılamadı: \(error)") }
    }

    // MARK: Kapanış

    func shutdown() {
        lock.lock()
        if stopping { lock.unlock(); return }
        stopping = true
        lock.unlock()
        set(.stopping)
        stopSocktainer()
        // Foundation.Process alt süreci ayrı süreç grubunda başlatır; ajan önceden kill -9 ile ölmüşse
        // launchd o socktainer'ı temizlemez. Bu paketin socktainer'ından sahipsiz kalanları da kapat.
        if let bin = Tools.socktainer {
            let r = Shell.runBlocking("/usr/bin/pkill", ["-TERM", "-f", "^\(NSRegularExpression.escapedPattern(for: bin))$"], timeout: 5)
            if r.code == 0 { log("sahipsiz socktainer süreçleri kapatıldı") }
        }
        // Kapanış anında yeniden oku: tray "yeniden başlat" için bunu geçici olarak false yapar.
        if AgentConfig.load().stopRuntimeOnExit {
            switch config.backend {
            case .apple:
                if let cli = Tools.find("container") {
                    let r = Shell.runBlocking(cli, ["system", "stop"], timeout: 100)
                    log("container system stop → \(r.code)")
                }
            case .colima:
                if let cli = Tools.find("colima") {
                    let r = Shell.runBlocking(cli, ["stop"], timeout: 100)
                    log("colima stop → \(r.code)")
                }
            }
        }
        set(.stopped)
        log("LimanAgent durdu")
    }
}

let supervisor = Supervisor()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    // Ana kuyruk: Swift 6'da main.swift'teki globaller MainActor'a bağlı; arka plan kuyruğundan
    // `supervisor`a erişmek çalışma zamanı izolasyon denetimini tetikleyip süreci SIGTRAP ile çökertiyordu.
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("sinyal \(sig) alındı, kapanıyor")
        supervisor.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

supervisor.run()
dispatchMain()
