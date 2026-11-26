import Foundation
import Observation
import Darwin
import LimanCore

/// Tray'de gösterilen birleşik servis durumu.
enum RuntimeStatus: Equatable, Sendable {
    case unknown
    case notInstalled
    case needsKernel
    case stopped
    case starting(String?)
    case stopping
    case running(since: Date?)
    case failed(String)

    var label: String {
        switch self {
        case .unknown: "Kontrol ediliyor…"
        case .notInstalled: "Kurulu değil"
        case .needsKernel: "Linux çekirdeği gerekli"
        case .stopped: "Durduruldu"
        case .starting: "Başlatılıyor…"
        case .stopping: "Durduruluyor…"
        case .running: "Çalışıyor"
        case .failed: "Hata"
        }
    }

    var detail: String? {
        switch self {
        case .starting(let m): m
        case .failed(let m): m
        case .running(let since?):
            Date().timeIntervalSince(since) < 60
                ? "Az önce başladı"
                : "\(Self.uptime.string(from: since, to: Date()) ?? "") süredir çalışıyor"
        default: nil
        }
    }

    var isRunning: Bool { if case .running = self { true } else { false } }
    var isBusy: Bool {
        switch self {
        case .starting, .stopping: true
        default: false
        }
    }

    private static let uptime: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
}

/// Arka plan ajanını (LimanAgent) launchd üzerinden yönetir:
/// ~/Library/LaunchAgents/app.liman.agent.plist yazar, `launchctl bootstrap/bootout/kickstart` çağırır,
/// ajanın yazdığı durum dosyasını okur.
@MainActor
@Observable
final class ServiceController {
    private(set) var status: RuntimeStatus = .unknown
    private(set) var agent: AgentStatus?
    private(set) var isLoaded = false
    private(set) var lastLog = ""
    private var pending: RuntimeStatus?
    private var requestedAt: Date?

    let launchctl = "/bin/launchctl"
    var domain: String { "gui/\(getuid())" }
    var service: String { "\(domain)/\(LimanPaths.agentLabel)" }

    var containerCLI: String? { Tools.find("container") }
    var colimaCLI: String? { Tools.find("colima") }
    var dockerCLI: String? { Tools.find("docker") }
    var hasKernel: Bool { LimanPaths.hasAppleKernel }

    /// Paketteki ajan; geliştirmede (`swift run`) tray ile aynı klasördeki ikili.
    var agentExecutable: String? {
        if let p = Bundle.main.url(forAuxiliaryExecutable: "LimanAgent")?.path,
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LimanAgent").path
        return sibling.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    var appVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev" }

    // MARK: Durum

    func refresh(checkLaunchd: Bool = true, backend: Backend) async {
        if checkLaunchd {
            isLoaded = (await Shell.run(launchctl, ["print", service], timeout: 5)).ok
        }
        agent = AgentStatus.load()
        status = compute(backend: backend)
    }

    private func compute(backend: Backend) -> RuntimeStatus {
        if let pending { return pending }
        guard isLoaded else {
            switch backend {
            case .apple:
                if containerCLI == nil { return .notInstalled }
                if !hasKernel { return .needsKernel }
            case .colima:
                if colimaCLI == nil { return .notInstalled }
            }
            return .stopped
        }
        guard let a = agent else { return .starting("ajan başlatılıyor") }
        if a.isStale {
            if let r = requestedAt, Date().timeIntervalSince(r) < 30 { return .starting("ajan başlatılıyor") }
            return .failed("Ajan yanıt vermiyor (son sinyal \(Int(Date().timeIntervalSince(a.updatedAt))) s önce)")
        }
        switch a.state {
        case .running: return .running(since: a.runningSince)
        case .starting: return .starting(a.message)
        case .stopping: return .stopping
        case .stopped: return .stopped
        case .needsKernel: return .needsKernel
        case .notInstalled: return .notInstalled
        case .failed: return .failed(a.message ?? "bilinmeyen hata")
        }
    }

    // MARK: Yaşam döngüsü

    func start(config: AgentConfig, startAtLogin: Bool) async {
        pending = .starting("servis kaydediliyor")
        status = pending!
        defer { pending = nil }
        guard let exe = agentExecutable else {
            pending = nil; status = .failed("LimanAgent ikilisi bulunamadı"); return
        }
        do {
            try config.save()
            try writePlist(agentExecutable: exe)
        } catch {
            pending = nil; status = .failed("Yapılandırma yazılamadı: \(error.localizedDescription)"); return
        }
        // Eski bir çalıştırmadan kalan durum dosyası yanlış "çalışıyor" göstermesin.
        try? FileManager.default.removeItem(at: LimanPaths.status)

        log(await Shell.run(launchctl, ["enable", service], timeout: 10))
        // Yüklüyse önce düzgünce indir: `kickstart -k` ajana temizlik fırsatı vermeden öldürüyor.
        if await isServiceLoaded() {
            log(await Shell.run(launchctl, ["bootout", service], timeout: 30))
            await waitUntilUnloaded()
        }
        // Ajan kapanışı launchd'de bitmeden bootstrap "5: Input/output error" verebilir; kısa süre yeniden dene.
        var r = ShellResult(code: -1, out: "", err: "")
        for attempt in 0..<10 {
            r = await Shell.run(launchctl, ["bootstrap", domain, LimanPaths.launchAgentPlist.path], timeout: 30)
            if r.ok || !r.err.contains("Input/output error") { break }
            Log.app.notice("bootstrap yeniden deneniyor (\(attempt + 1))")
            try? await Task.sleep(for: .seconds(1))
        }
        log(r)
        if !startAtLogin {
            // Bu oturumda çalışmaya devam eder, bir sonraki oturum açılışında yüklenmez.
            log(await Shell.run(launchctl, ["disable", service], timeout: 10))
        }
        requestedAt = Date()
        pending = nil
        if !r.ok {
            status = .failed("launchctl: \(r.combined.suffix(200))")
            return
        }
        await refresh(backend: config.backend)
    }

    func stop(backend: Backend) async {
        pending = .stopping
        status = .stopping
        // bootout ajana SIGTERM gönderip HEMEN döner; ajan çalışma zamanını kapatıp çıkana kadar (en fazla
        // ExitTimeOut = 120 s) launchd işi tutar. Kapanış bitmeden "durdu" demeyelim.
        let r = await Shell.run(launchctl, ["bootout", service], timeout: 30)
        log(r)
        await waitUntilUnloaded()
        pending = nil
        requestedAt = nil
        await refresh(backend: backend)
    }

    /// keepRuntime: yalnızca ajan + socktainer yenilenir, konteynerler çalışmaya devam eder.
    /// Arka uç değişiminde false verilir ki eski çalışma zamanı kapansın.
    func restart(config: AgentConfig, startAtLogin: Bool, keepRuntime: Bool = true) async {
        if isLoaded {
            if keepRuntime {
                // Ajan kapanırken yapılandırmayı okur; geçici olarak "çalışma zamanını kapatma" de.
                var c = AgentConfig.load()
                c.stopRuntimeOnExit = false
                try? c.save()
            }
            await stop(backend: config.backend)
        }
        await start(config: config, startAtLogin: startAtLogin)
    }

    /// Uygulama taşındı/güncellendiyse plist'i yeni ikiliye yönlendirir; ajan eski sürümse yeniden başlatır.
    func reconcile(config: AgentConfig, startAtLogin: Bool) async {
        guard let exe = agentExecutable,
              let d = try? Data(contentsOf: LimanPaths.launchAgentPlist),
              let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return }
        let current = (plist["ProgramArguments"] as? [String])?.first
        let versionMismatch = agent.map { $0.version != appVersion } ?? false
        if current != exe || (isLoaded && versionMismatch) {
            Log.app.notice("ajan uzlaştırılıyor: yol değişti=\(current != exe), sürüm farkı=\(versionMismatch)")
            try? writePlist(agentExecutable: exe)
            if isLoaded { await restart(config: config, startAtLogin: startAtLogin) }
        }
    }

    /// Servisi tamamen kaldırır (plist silinir).
    func uninstall(backend: Backend) async {
        if isLoaded { await stop(backend: backend) }
        try? FileManager.default.removeItem(at: LimanPaths.launchAgentPlist)
        await refresh(backend: backend)
    }

    /// Oturum açılışında başlatma tercihini çalışan servisi etkilemeden günceller.
    func setStartAtLogin(_ on: Bool) async {
        log(await Shell.run(launchctl, [on ? "enable" : "disable", service], timeout: 10))
    }

    private func isServiceLoaded() async -> Bool {
        (await Shell.run(launchctl, ["print", service], timeout: 5)).ok
    }

    /// launchd işi tamamen kalkana kadar bekler (ajanın temiz kapanışı + ExitTimeOut payı).
    private func waitUntilUnloaded(timeout: TimeInterval = 130) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, await isServiceLoaded() {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func writePlist(agentExecutable exe: String) throws {
        LimanPaths.ensureDirs()
        try FileManager.default.createDirectory(at: LimanPaths.launchAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: LaunchAgentPlist.make(agentExecutable: exe), format: .xml, options: 0)
        try data.write(to: LimanPaths.launchAgentPlist, options: .atomic)
    }

    // MARK: docker CLI context senkronizasyonu

    func syncDockerContext(to b: Backend) async {
        guard let docker = dockerCLI else { return }
        if b == .apple, !(await Shell.run(docker, ["context", "inspect", "apple"], timeout: 10)).ok {
            log(await Shell.run(docker, ["context", "create", "apple",
                                         "--description", "Apple container (Liman/socktainer)",
                                         "--docker", "host=unix://\(Backend.apple.socketPath)"], timeout: 10))
        }
        let current = await Shell.run(docker, ["context", "show"], timeout: 10)
        if current.out != b.dockerContextName {
            log(await Shell.run(docker, ["context", "use", b.dockerContextName], timeout: 10))
        }
    }

    // MARK: Çekirdek

    struct KernelSpec: Sendable { let url: URL; let digest: String; let binaryPath: String }

    /// container 1.7.1'in önerdiği çekirdek; özellik listesi okunamazsa yedek olarak kullanılır.
    static let fallbackKernel = KernelSpec(
        url: URL(string: "https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-arm64.tar.zst")!,
        digest: "sha256:2c5bf7cde334ad5307d482f45cceda496f91c9b6b96f5278c47f4f4eac1bbae6",
        binaryPath: "opt/kata/share/kata-containers/vmlinux-6.18.56-208-debug")

    /// `container system property list` çıktısındaki [kernel] bölümünü okur.
    /// Bu komut apiserver'a XPC ile bağlanır; servis kapalıysa (ilk kurulumda olduğu gibi) önce
    /// çekirdek kurmadan `container system start` çalıştırıp yeniden dener.
    func recommendedKernel() async -> KernelSpec? {
        guard let cli = containerCLI else { return nil }
        if let spec = await readKernelProperties(cli) { return spec }
        log(await Shell.run(cli, ["system", "start", "--disable-kernel-install"], timeout: 120))
        if let spec = await readKernelProperties(cli) { return spec }
        Log.file("çekirdek özellikleri okunamadı; yerleşik yedek değerler kullanılıyor")
        return Self.fallbackKernel
    }

    private func readKernelProperties(_ cli: String) async -> KernelSpec? {
        let r = await Shell.run(cli, ["system", "property", "list"], timeout: 15)
        // Bu komut hata durumunda da 0 dönebiliyor; içeriğe bakıyoruz.
        guard r.ok, !r.combined.contains("XPC connection error") else { return nil }
        var inKernel = false
        var kv: [String: String] = [:]
        for raw in r.out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inKernel = (line == "[kernel]"); continue }
            guard inKernel, let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            kv[k] = v
        }
        guard let u = kv["url"].flatMap(URL.init(string:)), let d = kv["digest"], let bp = kv["binaryPath"] else { return nil }
        return KernelSpec(url: u, digest: d, binaryPath: bp)
    }

    func installKernel(tar: URL, binaryPath: String) async -> ShellResult {
        guard let cli = containerCLI else { return ShellResult(code: -1, out: "", err: "container yok") }
        // Arşiv üyeleri "./" önekli olabilir; iki biçimi de deneriz. --force KULLANMIYORUZ (mevcut çekirdeği önce siler).
        var r = await Shell.run(cli, ["system", "kernel", "set", "--tar", tar.path, "--binary", binaryPath], timeout: 300)
        if !hasKernel {
            r = await Shell.run(cli, ["system", "kernel", "set", "--tar", tar.path, "--binary", "./" + binaryPath], timeout: 300)
        }
        log(r)
        return r
    }

    private func log(_ r: ShellResult) {
        let text = r.combined
        guard !text.isEmpty else { return }
        lastLog = String((lastLog + "\n" + text).suffix(8000))
    }
}
