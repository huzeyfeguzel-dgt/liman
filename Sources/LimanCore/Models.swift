import Foundation

public struct ContainerSummary: Decodable, Identifiable, Hashable, Sendable {
    public let Id: String
    public let Names: [String]?
    public let Image: String?
    public let State: String?
    public let Status: String?
    public let Ports: [Port]?
    public let Labels: [String: String]?

    public struct Port: Decodable, Hashable, Sendable {
        public let PrivatePort: Int?
        public let PublicPort: Int?
        public let `Type`: String?
        public let IP: String?
    }

    public var id: String { Id }
    public var name: String { (Names?.first ?? Id).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    public var isRunning: Bool { State?.lowercased() == "running" }
    public var shortImage: String {
        (Image ?? "?").replacingOccurrences(of: "docker.io/library/", with: "").replacingOccurrences(of: "docker.io/", with: "")
    }
    public var composeProject: String? { Labels?["com.docker.compose.project"] }
    public var publishedPorts: [Int] {
        Array(Set((Ports ?? []).compactMap { $0.PublicPort })).sorted()
    }
}

public struct ContainerStats: Decodable, Sendable {
    public let memory_stats: Memory?
    public let cpu_stats: CPU?

    public struct Memory: Decodable, Sendable { public let usage: UInt64?; public let limit: UInt64? }
    public struct CPU: Decodable, Sendable {
        public let cpu_usage: Usage?
        public let online_cpus: Int?
        public struct Usage: Decodable, Sendable { public let total_usage: UInt64? }
    }
}

/// UI'da gösterilen, iki ardışık örnekten hesaplanan metrikler.
public struct LiveStats: Sendable, Equatable {
    public var memoryBytes: UInt64
    public var memoryLimit: UInt64
    public var cpuPercent: Double
    public init(memoryBytes: UInt64 = 0, memoryLimit: UInt64 = 0, cpuPercent: Double = 0) {
        self.memoryBytes = memoryBytes; self.memoryLimit = memoryLimit; self.cpuPercent = cpuPercent
    }
    public var memoryFraction: Double { memoryLimit > 0 ? Double(memoryBytes) / Double(memoryLimit) : 0 }
}

/// Genel bakış grafikleri için tek bir zaman örneği.
public struct ResourceSample: Sendable, Identifiable, Equatable {
    public let date: Date
    public let cpuPercent: Double
    public let containerMemory: UInt64
    public let hostVMMemory: UInt64
    public let running: Int
    public var id: Date { date }
    public init(date: Date, cpuPercent: Double, containerMemory: UInt64, hostVMMemory: UInt64, running: Int) {
        self.date = date; self.cpuPercent = cpuPercent; self.containerMemory = containerMemory
        self.hostVMMemory = hostVMMemory; self.running = running
    }
}

public enum Backend: String, CaseIterable, Identifiable, Codable, Sendable {
    // Sıra seçicideki sırayı belirler; rawValue'lar kayıtlı tercihler için değişmemeli.
    case colima, apple
    public var id: String { rawValue }

    /// Yeni kurulumların arka ucu. Apple container'a Ayarlar / Genel bakış'tan elle geçilebilir.
    public static let defaultBackend: Backend = .colima

    public var title: String {
        switch self {
        case .apple: "Apple container"
        case .colima: "Colima"
        }
    }

    public var subtitle: String {
        switch self {
        case .apple: L("Konteyner başına mikro-VM · boşta ~0 kaynak", "Micro-VM per container · ~0 resources when idle")
        case .colima: L("Tek Linux VM · tam Docker uyumluluğu", "Single Linux VM · full Docker compatibility")
        }
    }

    public var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .apple: return "\(home)/.socktainer/container.sock"
        case .colima: return "\(home)/.colima/default/docker.sock"
        }
    }

    public var dockerContextName: String { rawValue }
}

extension UInt64 {
    public var humanBytes: String {
        Fmt.bytes(self)
    }
}

public struct DockerInfo: Decodable, Sendable, Equatable {
    public let NCPU: Int?
    public let MemTotal: UInt64?
}
