import Foundation
import Darwin

public enum DockerError: LocalizedError {
    case socket(String)
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .socket(let m): return "Soket hatası: \(m)"
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .badResponse: return "Geçersiz yanıt"
        }
    }
}

/// Docker Engine API'sine Unix soketi üzerinden konuşan küçük, bağımlılıksız istemci.
/// Hem socktainer (Apple container) hem Colima'nın dockerd'si için aynı kod çalışır.
public struct DockerClient: Sendable {
    public let socketPath: String
    public var apiVersion = "v1.51"

    public init(socketPath: String) { self.socketPath = socketPath }

    /// Senkron ping (launchd ajanı gibi async olmayan bağlamlar için).
    public func pingSync(timeout: TimeInterval = 2) -> Bool {
        (try? Self.blockingRequest(socket: socketPath, method: "GET", path: "/\(apiVersion)/_ping", timeout: timeout).status) == 200
    }

    // MARK: Yüksek seviye API

    public func ping() async -> Bool {
        (try? await request("GET", "/_ping", timeout: 2).status) == 200
    }

    public func containers() async throws -> [ContainerSummary] {
        try await decode("/containers/json?all=true")
    }

    public func stats(_ id: String) async throws -> ContainerStats {
        try await decode("/containers/\(id)/stats?stream=false", timeout: 10)
    }

    public func start(_ id: String) async throws { try await expectOK("POST", "/containers/\(id)/start") }
    public func stop(_ id: String) async throws { try await expectOK("POST", "/containers/\(id)/stop", timeout: 30) }
    public func restart(_ id: String) async throws { try await expectOK("POST", "/containers/\(id)/restart", timeout: 45) }
    public func remove(_ id: String) async throws { try await expectOK("DELETE", "/containers/\(id)?force=true", timeout: 30) }

    public func logs(_ id: String, tail: Int = 500) async throws -> String {
        let r = try await request("GET", "/containers/\(id)/logs?stdout=1&stderr=1&timestamps=0&tail=\(tail)", timeout: 10)
        guard r.status == 200 else { throw DockerError.http(r.status, String(decoding: r.body, as: UTF8.self)) }
        return Self.demuxLogs(r.body)
    }

    // MARK: Yardımcılar

    private func decode<T: Decodable>(_ path: String, timeout: TimeInterval = 8) async throws -> T {
        let r = try await request("GET", path, timeout: timeout)
        guard r.status == 200 else { throw DockerError.http(r.status, String(decoding: r.body, as: UTF8.self)) }
        return try JSONDecoder().decode(T.self, from: r.body)
    }

    private func expectOK(_ method: String, _ path: String, timeout: TimeInterval = 15) async throws {
        let r = try await request(method, path, timeout: timeout)
        guard (200..<300).contains(r.status) || r.status == 304 else {
            throw DockerError.http(r.status, Self.message(r.body))
        }
    }

    private static func message(_ body: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let m = o["message"] as? String { return m }
        return String(decoding: body, as: UTF8.self)
    }

    public func request(_ method: String, _ path: String, timeout: TimeInterval = 15) async throws -> (status: Int, body: Data) {
        let sock = socketPath, version = apiVersion
        return try await Task.detached(priority: .utility) {
            try Self.blockingRequest(socket: sock, method: method, path: "/\(version)\(path)", timeout: timeout)
        }.value
    }

    /// HTTP/1.1 isteğini düz POSIX soketiyle gönderir (Connection: close), yanıtı EOF'a kadar okur.
    private static func blockingRequest(socket path: String, method: String, path reqPath: String, timeout: TimeInterval) throws -> (status: Int, body: Data) {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw DockerError.socket("soket yolu çok uzun") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw DockerError.socket(String(cString: strerror(errno))) }

        let req = "\(method) \(reqPath) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Liman\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let bytes = Array(req.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            guard n > 0 else { throw DockerError.socket("yazma başarısız") }
            sent += n
        }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(buf, count: n) }
            else if n == 0 { break }
            else {
                if errno == EINTR { continue }
                if errno == EAGAIN && !data.isEmpty { break } // zaman aşımı ama veri var
                throw DockerError.socket("okuma zaman aşımı")
            }
        }
        return try parseHTTP(data)
    }

    private static func parseHTTP(_ data: Data) throws -> (status: Int, body: Data) {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { throw DockerError.badResponse }
        let head = String(decoding: data[..<r.lowerBound], as: UTF8.self)
        var body = Data(data[r.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw DockerError.badResponse }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw DockerError.badResponse }
        let chunked = lines.contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        if chunked { body = dechunk(body) }
        return (status, body)
    }

    private static func dechunk(_ d: Data) -> Data {
        var out = Data()
        var i = d.startIndex
        let crlf = Data("\r\n".utf8)
        while i < d.endIndex {
            guard let lineEnd = d.range(of: crlf, in: i..<d.endIndex) else { break }
            let sizeStr = String(decoding: d[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = min(d.index(start, offsetBy: size, limitedBy: d.endIndex) ?? d.endIndex, d.endIndex)
            out.append(d[start..<end])
            i = min(d.index(end, offsetBy: 2, limitedBy: d.endIndex) ?? d.endIndex, d.endIndex)
        }
        return out
    }

    /// TTY'siz konteynerlerde Docker logları 8 baytlık başlıklı çerçevelerle gelir.
    public static func demuxLogs(_ d: Data) -> String {
        let b = [UInt8](d)
        guard b.count >= 8, [0, 1, 2].contains(b[0]), b[1] == 0, b[2] == 0, b[3] == 0 else {
            return String(decoding: d, as: UTF8.self)
        }
        var out = [UInt8]()
        var i = 0
        while i + 8 <= b.count {
            let size = Int(b[i+4]) << 24 | Int(b[i+5]) << 16 | Int(b[i+6]) << 8 | Int(b[i+7])
            let s = i + 8, e = min(s + size, b.count)
            out.append(contentsOf: b[s..<e])
            i = e
        }
        return String(decoding: out, as: UTF8.self)
    }
}
