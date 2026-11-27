import Foundation
import Darwin

public struct ShellResult: Sendable {
    public let code: Int32
    public let out: String
    public let err: String
    public var ok: Bool { code == 0 }
    public init(code: Int32, out: String, err: String) { self.code = code; self.out = out; self.err = err }
    public var combined: String { [out, err].filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// GUI uygulamaları launchd'den minimal bir PATH ile başlar; Homebrew araçlarını burada buluyoruz.
public enum Tools {
    public static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":")
        return env
    }

    public static func find(_ name: String) -> String? {
        for dir in searchPaths {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Uygulama paketine gömülü socktainer; yoksa Homebrew kurulumu.
    public static var socktainer: String? {
        if let p = Bundle.main.url(forAuxiliaryExecutable: "socktainer")?.path,
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/socktainer").path
        if FileManager.default.isExecutableFile(atPath: helpers) { return helpers }
        return find("socktainer")
    }
}

public enum Shell {
    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 120) async -> ShellResult {
        await Task.detached(priority: .utility) {
            runBlocking(executable, args, timeout: timeout)
        }.value
    }

    public static func runBlocking(_ executable: String, _ args: [String], timeout: TimeInterval) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = Tools.environment
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return ShellResult(code: -1, out: "", err: error.localizedDescription)
        }
        // Boru tamponu dolup süreç kilitlenmesin diye iki ucu da eşzamanlı okuyoruz.
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
            return ShellResult(code: -2, out: String(decoding: outData, as: UTF8.self), err: L("zaman aşımı (\(Int(timeout)) s)", "timed out (\(Int(timeout)) s)"))
        }
        p.waitUntilExit()
        return ShellResult(code: p.terminationStatus,
                           out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                           err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Sanallaştırma süreçlerinin host'taki toplam bellek kullanımı (libproc ile, `ps` çağırmadan).
public enum HostMemory {
    public static let patterns = ["com.apple.Virtualization.VirtualMachine", "/container-", "socktainer", "limactl"]

    public static func virtualizationFootprint() -> UInt64 {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return 0 }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var total: UInt64 = 0
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let path = String(decoding: pathBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard patterns.contains(where: { path.contains($0) }) else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size {
                total += info.pti_resident_size
            }
        }
        return total
    }
}
