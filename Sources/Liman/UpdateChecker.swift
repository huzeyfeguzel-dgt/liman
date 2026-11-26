import Foundation
import Observation

/// GitHub Releases üzerinden yeni sürüm kontrolü (App Store dışı dağıtım).
/// Depo, derleme sırasında Info.plist'e yazılan `LimanGitHubRepo` anahtarından okunur ("sahip/depo").
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Decodable, Sendable {
        let tag_name: String
        let html_url: String
        let name: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
        struct Asset: Decodable, Sendable { let name: String; let browser_download_url: String }
    }

    private(set) var latest: Release?
    private(set) var lastChecked: Date?
    private(set) var error: String?

    var repo: String? {
        let r = Bundle.main.object(forInfoDictionaryKey: "LimanGitHubRepo") as? String
        guard let r, r.contains("/"), !r.contains("__") else { return nil }
        return r
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.compare(latest.tag_name, currentVersion) == .orderedDescending
    }

    var downloadURL: URL? {
        guard let latest else { return nil }
        let dmg = latest.assets?.first { $0.name.hasSuffix(".dmg") }?.browser_download_url
        return URL(string: dmg ?? latest.html_url)
    }

    var releasePage: URL? { latest.flatMap { URL(string: $0.html_url) } }

    func check() async {
        guard let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Liman/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "GitHub yanıtı: \((resp as? HTTPURLResponse)?.statusCode ?? 0)"; return }
            let r = try JSONDecoder().decode(Release.self, from: data)
            if r.draft != true, r.prerelease != true { latest = r }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        lastChecked = Date()
    }

    /// "v1.2.10" ile "1.2.9" gibi sürümleri sayısal karşılaştırır.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(whereSeparator: { $0 == "." || $0 == "-" })
                .map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
