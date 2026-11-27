import Foundation
import CryptoKit
import Observation
import LimanCore

/// Apple container'ın Linux çekirdeğini kopmalara dayanıklı biçimde indirir (HTTP Range ile kaldığı yerden devam),
/// SHA-256 ile doğrular ve `container system kernel set --tar` ile kurar.
@MainActor
@Observable
final class KernelInstaller {
    enum Phase: Equatable { case idle, downloading, verifying, installing, done, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var received: Int64 = 0
    private(set) var total: Int64 = 0
    private(set) var bytesPerSecond: Double = 0

    var progress: Double { total > 0 ? Double(received) / Double(total) : 0 }
    var isRunning: Bool { [.downloading, .verifying, .installing].contains(phase) }

    private var task: Task<Void, Never>?

    static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.liman.Liman/kernel", isDirectory: true)

    func start(state: AppState) {
        guard !isRunning else { return }
        task = Task { await run(state: state) }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }

    private func run(state: AppState) async {
        let runtime = state.service
        phase = .downloading
        guard let spec = await runtime.recommendedKernel() else {
            phase = .failed(L("Önerilen çekirdek bilgisi okunamadı (container kurulu mu?)", "Could not read recommended kernel info (is container installed?)"))
            return
        }
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        let file = Self.cacheDir.appendingPathComponent(spec.url.lastPathComponent)

        // İndir (en fazla 20 deneme, her seferinde kaldığı yerden).
        var attempt = 0
        while true {
            if Task.isCancelled { return }
            do {
                try await download(spec.url, to: file)
                break
            } catch {
                attempt += 1
                if attempt >= 20 { phase = .failed(L("İndirme başarısız: \(error.localizedDescription)", "Download failed: \(error.localizedDescription)")); return }
                try? await Task.sleep(for: .seconds(min(2 * attempt, 15)))
            }
        }

        phase = .verifying
        let expected = spec.digest.replacingOccurrences(of: "sha256:", with: "").lowercased()
        let actual = await Task.detached { Self.sha256(of: file) }.value
        guard actual == expected else {
            try? FileManager.default.removeItem(at: file)
            phase = .failed(L("SHA-256 uyuşmadı; dosya silindi, tekrar deneyin", "SHA-256 mismatch; file deleted, please try again"))
            return
        }

        phase = .installing
        let r = await runtime.installKernel(tar: file, binaryPath: spec.binaryPath)
        if runtime.hasKernel {
            try? FileManager.default.removeItem(at: file) // ~650 MB'ı geri ver
            phase = .done
            // Çekirdek beklerken boşta duran ajanı yeniden başlat.
            if runtime.isLoaded { await state.restartService() } else { await runtime.refresh(backend: state.backend) }
        } else {
            phase = .failed(String(r.combined.suffix(200)))
        }
    }

    private func download(_ url: URL, to file: URL) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let existing = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0

        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        switch http.statusCode {
        case 206:
            try handle.seekToEnd()
            received = existing
            total = existing + http.expectedContentLength
        case 200:
            try handle.truncate(atOffset: 0)
            received = 0
            total = http.expectedContentLength
        case 416:
            return // zaten tamamı inmiş
        default:
            throw URLError(.badServerResponse)
        }

        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var lastTick = Date(), lastBytes = received
        for try await chunk in bytes.chunked(1 << 20) {
            if Task.isCancelled { throw CancellationError() }
            buffer.append(contentsOf: chunk)
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            let now = Date()
            if now.timeIntervalSince(lastTick) >= 1 {
                bytesPerSecond = Double(received - lastBytes) / now.timeIntervalSince(lastTick)
                lastTick = now; lastBytes = received
            }
        }
    }

    nonisolated static func sha256(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try? h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension URLSession.AsyncBytes {
    /// Bayt bayt yazmak yerine ~1 MB'lık parçalar halinde toplar.
    func chunked(_ size: Int) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                var buf = [UInt8](); buf.reserveCapacity(size)
                do {
                    for try await b in self {
                        buf.append(b)
                        if buf.count >= size { cont.yield(buf); buf.removeAll(keepingCapacity: true) }
                    }
                    if !buf.isEmpty { cont.yield(buf) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
