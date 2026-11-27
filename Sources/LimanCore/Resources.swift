import Foundation
import Darwin

/// Apple container'ın kaynak tahsisi.
///
/// Neden gerekli: Apple container'ın yerleşik varsayılanları her konteyner için 4 CPU / 1 GB, BuildKit
/// builder VM'i için 2 CPU / 2 GB. `docker build` ve devcontainer'lar (ör. dotnet/sdk) bu builder'da
/// çalışır ve 2 GB'ta bellek yetmeyince build `StreamClosed … Cancel` ile kopar. 1 GB'lık konteyner
/// varsayılanı da IDE sunucuları ve derleyiciler için yetersiz kalır. Docker'ın `--memory` / `--cpus`
/// değerleri ve compose `deploy.resources.limits` socktainer üzerinden konteyner bazında yine geçerlidir.
/// Buradaki değerler yalnızca limit verilmediğinde kullanılan varsayılanlardır.
public struct ResourceConfig: Codable, Equatable, Hashable, Sendable {
    public var containerCPUs: Int
    public var containerMemoryMB: Int
    public var builderCPUs: Int
    public var builderMemoryMB: Int

    public init(containerCPUs: Int, containerMemoryMB: Int, builderCPUs: Int, builderMemoryMB: Int) {
        self.containerCPUs = containerCPUs
        self.containerMemoryMB = containerMemoryMB
        self.builderCPUs = builderCPUs
        self.builderMemoryMB = builderMemoryMB
    }

    /// Apple container 1.7'nin yerleşik değerleri.
    public static let appleDefaults = ResourceConfig(containerCPUs: 4, containerMemoryMB: 1024, builderCPUs: 2, builderMemoryMB: 2048)

    /// Bu Mac için önerilen değerler. VM belleği tembel ayrılır; limit, konteyner gerçekten kullanmadıkça RAM tüketmez.
    /// 8 GB / 8 çekirdek → konteyner 4 CPU / 2 GB, builder 4 CPU / 4 GB.
    public static var recommended: ResourceConfig {
        let cpus = HostInfo.cpuCount, mem = HostInfo.memoryMB
        return ResourceConfig(
            containerCPUs: min(4, cpus),
            containerMemoryMB: (mem / 4).clamped(1024, 4096).roundedDown(to: 512),
            builderCPUs: max(2, cpus / 2),
            builderMemoryMB: (mem / 2).clamped(2048, 8192).roundedDown(to: 512))
    }

    /// Değerleri host'un kaldırabileceği aralığa çeker (macOS'a en az 2 GB bırakılır).
    public func clamped() -> ResourceConfig {
        let cpus = HostInfo.cpuCount, maxMem = HostInfo.maxGuestMemoryMB
        return ResourceConfig(
            containerCPUs: containerCPUs.clamped(1, cpus),
            containerMemoryMB: containerMemoryMB.clamped(256, maxMem),
            builderCPUs: builderCPUs.clamped(1, cpus),
            builderMemoryMB: builderMemoryMB.clamped(1024, maxMem))
    }
}

public enum HostInfo {
    public static var cpuCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    public static var memoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
    /// Tek bir VM'e verilebilecek en yüksek bellek: host'a en az 2 GB bırakılır.
    public static var maxGuestMemoryMB: Int { max(1024, memoryMB - 2048) }
}

/// `~/.config/container/config.toml` dosyasını, kullanıcının diğer ayarlarına dokunmadan günceller.
/// Apple container bu dosyayı yalnızca `container system start` sırasında okur.
public enum ContainerSystemConfig {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/container/config.toml")
    }

    /// Dosyayı yazar. İçerik değiştiyse true döner.
    @discardableResult
    public static func apply(_ r: ResourceConfig) throws -> Bool {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let new = render(r, into: old)
        guard new != old else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    public static func render(_ r: ResourceConfig, into text: String) -> String {
        var t = text
        t = set(in: t, section: "container", ["cpus": "\(r.containerCPUs)", "memory": "\"\(r.containerMemoryMB)mb\""])
        t = set(in: t, section: "build", ["cpus": "\(r.builderCPUs)", "memory": "\"\(r.builderMemoryMB)mb\""])
        return t
    }

    /// Bir TOML bölümündeki anahtarları ayarlar. Bölüm ya da anahtar yoksa ekler, geri kalanı aynen korur.
    static func set(in text: String, section: String, _ values: [String: String]) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let keys = values.keys.sorted()

        func isHeader(_ l: String) -> Bool { l.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        func headerName(_ l: String) -> String? {
            var s = l.trimmingCharacters(in: .whitespaces)
            if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]).trimmingCharacters(in: .whitespaces) }
            guard s.hasPrefix("["), s.hasSuffix("]"), !s.hasPrefix("[[") else { return nil }
            return String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        func keyName(_ l: String) -> String? {
            let s = l.trimmingCharacters(in: .whitespaces)
            guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { return nil }
            return s[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        guard let start = lines.firstIndex(where: { headerName($0) == section }) else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("# Liman tarafından yönetilir (Liman › Kaynaklar)")
            lines.append("[\(section)]")
            for k in keys { lines.append("\(k) = \(values[k]!)") }
            return lines.joined(separator: "\n") + "\n"
        }
        var end = lines.count
        if let next = lines[(start + 1)...].firstIndex(where: isHeader) { end = next }

        var missing = Set(keys)
        for i in (start + 1)..<end {
            guard let k = keyName(lines[i]), let v = values[k] else { continue }
            let indent = String(lines[i].prefix(while: { $0 == " " || $0 == "\t" }))
            lines[i] = "\(indent)\(k) = \(v)"
            missing.remove(k)
        }
        // Eksik anahtarları bölümün son dolu satırının arkasına ekle.
        var insertAt = end
        while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        for k in keys where missing.contains(k) {
            lines.insert("\(k) = \(values[k]!)", at: insertAt)
            insertAt += 1
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// BuildKit builder konteynerinin (id: buildkit) kayıtlı kaynakları.
/// Builder bir kez oluşturulduktan sonra config.toml'daki [build] değişikliklerini görmez;
/// silinip yeni değerlerle yeniden oluşturulması gerekir.
public enum BuilderInfo {
    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.container/containers/buildkit/config.json")
    }

    public static func current() -> (cpus: Int, memoryMB: Int)? {
        guard let d = try? Data(contentsOf: configURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let r = o["resources"] as? [String: Any],
              let cpus = r["cpus"] as? Int,
              let mem = (r["memoryInBytes"] as? NSNumber)?.uint64Value else { return nil }
        return (cpus, Int(mem / 1_048_576))
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), Swift.max(lo, hi)) }
    func roundedDown(to step: Int) -> Int { Swift.max(step, self / step * step) }
}

/// Colima VM'inin kaynakları. Colima'da tüm konteynerler tek bir VM'i paylaşır; Docker'ın gördüğü
/// CPU/bellek (ör. `--cpus=4` doğrulaması) bu VM'in boyutudur. Değişiklik VM yeniden başlayınca geçerli olur.
public struct ColimaResources: Codable, Equatable, Hashable, Sendable {
    public var cpus: Int
    public var memoryGB: Int
    public var diskGB: Int

    public init(cpus: Int, memoryGB: Int, diskGB: Int) {
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.diskGB = diskGB
    }

    /// Docker Desktop'a benzer: çekirdeklerin yarısı, belleğin yarısı.
    /// 8 GB / 8 çekirdek → 4 CPU / 4 GB.
    public static var recommended: ColimaResources {
        ColimaResources(cpus: max(2, HostInfo.cpuCount / 2),
                        memoryGB: (HostInfo.memoryMB / 2 / 1024).clamped(2, maxMemoryGB),
                        diskGB: 60)
    }

    public static var maxMemoryGB: Int { max(1, HostInfo.maxGuestMemoryMB / 1024) }

    public func clamped() -> ColimaResources {
        ColimaResources(cpus: cpus.clamped(1, HostInfo.cpuCount),
                        memoryGB: memoryGB.clamped(1, Self.maxMemoryGB),
                        diskGB: diskGB.clamped(10, 2048))
    }
}

/// `colima list --json` çıktısından varsayılan profilin mevcut kaynakları.
public enum ColimaInfo {
    public struct Current: Equatable, Sendable {
        public var running: Bool
        public var cpus: Int
        public var memoryGB: Int
        public var diskGB: Int

        /// İstenen değerlere geçmek için VM'in yeniden başlatılması gerekiyor mu?
        /// Disk yalnızca büyütülebilir; küçük bir değer istenirse yok sayılır.
        public func needsChange(to r: ColimaResources) -> Bool {
            cpus != r.cpus || memoryGB != r.memoryGB || diskGB < r.diskGB
        }
    }

    /// Her satır bir profil JSON nesnesidir; `profile` adlı olanı döner.
    public static func parse(_ output: String, profile: String = "default") -> Current? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["name"] as? String) == profile,
                  let cpus = (o["cpus"] as? NSNumber)?.intValue,
                  let mem = (o["memory"] as? NSNumber)?.doubleValue,
                  let disk = (o["disk"] as? NSNumber)?.doubleValue else { continue }
            let gib = 1_073_741_824.0
            return Current(running: (o["status"] as? String)?.lowercased() == "running",
                           cpus: cpus, memoryGB: Int((mem / gib).rounded()), diskGB: Int((disk / gib).rounded()))
        }
        return nil
    }
}
