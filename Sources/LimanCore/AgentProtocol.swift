import Foundation

/// Tray uygulaması ile launchd ajanı (LimanAgent) arasındaki sözleşme.
/// İletişim dosya tabanlıdır: tray `agent-config.json` yazar, ajan `agent-status.json` yazar.
/// Yaşam döngüsü (başlat/durdur/yeniden başlat) launchctl ile yönetilir.
public enum LimanPaths {
    public static let agentLabel = "app.liman.agent"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var supportDir: URL { home.appendingPathComponent("Library/Application Support/Liman", isDirectory: true) }
    public static var logsDir: URL { home.appendingPathComponent("Library/Logs/Liman", isDirectory: true) }
    public static var config: URL { supportDir.appendingPathComponent("agent-config.json") }
    public static var status: URL { supportDir.appendingPathComponent("agent-status.json") }
    public static var agentLog: URL { logsDir.appendingPathComponent("agent.log") }
    public static var socktainerLog: URL { logsDir.appendingPathComponent("socktainer.log") }
    public static var launchAgentPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist") }

    public static var kernelsDir: URL {
        home.appendingPathComponent("Library/Application Support/com.apple.container/kernels")
    }
    public static var hasAppleKernel: Bool {
        FileManager.default.fileExists(atPath: kernelsDir.appendingPathComponent("default.kernel-arm64").path)
    }

    public static func ensureDirs() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}

public struct AgentConfig: Codable, Equatable, Sendable {
    public var backend: Backend
    /// Ajan durdurulurken çalışma zamanını da kapat (container system stop / colima stop).
    public var stopRuntimeOnExit: Bool

    public init(backend: Backend = .apple, stopRuntimeOnExit: Bool = true) {
        self.backend = backend
        self.stopRuntimeOnExit = stopRuntimeOnExit
    }

    public static func load() -> AgentConfig {
        guard let d = try? Data(contentsOf: LimanPaths.config),
              let c = try? JSONDecoder().decode(AgentConfig.self, from: d) else { return AgentConfig() }
        return c
    }

    public func save() throws {
        LimanPaths.ensureDirs()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: LimanPaths.config, options: .atomic)
    }
}

public enum AgentState: String, Codable, Sendable {
    case starting, running, stopping, stopped, needsKernel, notInstalled, failed
}

public struct AgentStatus: Codable, Equatable, Sendable {
    public var state: AgentState
    public var backend: Backend
    public var message: String?
    public var pid: Int32
    public var startedAt: Date
    public var runningSince: Date?
    public var restarts: Int
    public var updatedAt: Date
    public var version: String

    public init(state: AgentState, backend: Backend, message: String? = nil, pid: Int32, startedAt: Date,
                runningSince: Date? = nil, restarts: Int = 0, updatedAt: Date = Date(), version: String) {
        self.state = state; self.backend = backend; self.message = message; self.pid = pid
        self.startedAt = startedAt; self.runningSince = runningSince; self.restarts = restarts
        self.updatedAt = updatedAt; self.version = version
    }

    /// Ajan her ~5 s'de bir yazar; 20 s'den eskiyse ajan takılmış ya da ölmüş demektir.
    public var isStale: Bool { Date().timeIntervalSince(updatedAt) > 20 }

    public static func load() -> AgentStatus? {
        guard let d = try? Data(contentsOf: LimanPaths.status) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AgentStatus.self, from: d)
    }

    public func save() {
        LimanPaths.ensureDirs()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(self).write(to: LimanPaths.status, options: .atomic)
    }
}

public enum LaunchAgentPlist {
    /// Ajan için ~/Library/LaunchAgents plist içeriği.
    public static func make(agentExecutable: String) -> [String: Any] {
        [
            "Label": LimanPaths.agentLabel,
            "ProgramArguments": [agentExecutable],
            "RunAtLoad": true,
            // Temiz çıkışta (durdur) yeniden başlatma; çökünce başlat.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            // `container system stop` / `colima stop` için zaman tanı.
            "ExitTimeOut": 120,
            "ProcessType": "Interactive",
            "StandardOutPath": LimanPaths.agentLog.path,
            "StandardErrorPath": LimanPaths.agentLog.path,
            "EnvironmentVariables": ["PATH": Tools.searchPaths.joined(separator: ":")],
        ]
    }
}
