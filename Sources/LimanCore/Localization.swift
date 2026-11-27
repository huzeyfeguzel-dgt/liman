import Foundation

/// Uygulama dili. `system`, macOS'un tercih edilen dillerini izler (Türkçe değilse İngilizce).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, tr, en
    public var id: String { rawValue }

    /// Seçicide gösterilen ad. Diller kendi adlarıyla yazılır ki yanlış dile geçen kullanıcı geri dönebilsin.
    public var title: String {
        switch self {
        case .system: L("Sistem", "System")
        case .tr: "Türkçe"
        case .en: "English"
        }
    }
}

public enum Loc {
    /// UserDefaults anahtarı (uygulama tercih alanında).
    public static let prefKey = "appLanguage"
    /// Ajan (launchd) ayrı bir süreç olduğu için dili uygulamanın tercih alanından okur.
    static let appDomain = "app.liman.Liman"

    public static var selected: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: prefKey)
            ?? UserDefaults(suiteName: appDomain)?.string(forKey: prefKey)
        return raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Fiilen kullanılan dil (`system` çözülmüş hâli).
    public static var resolved: AppLanguage {
        switch selected {
        case .tr: return .tr
        case .en: return .en
        case .system:
            let first = Locale.preferredLanguages.first ?? "en"
            return first.hasPrefix("tr") ? .tr : .en
        }
    }

    public static var isTurkish: Bool { resolved == .tr }

    /// Tarih/sayı biçimlendirme için yerel ayar.
    public static var locale: Locale { Locale(identifier: isTurkish ? "tr_TR" : "en_US") }
}

/// Kullanıcıya görünen metin: Türkçe ve İngilizce karşılığı yan yana tutulur.
@inline(__always)
public func L(_ tr: String, _ en: String) -> String {
    Loc.isTurkish ? tr : en
}

/// Seçili dile göre sayı biçimleri (ondalık ayırıcı, yüzde işaretinin yeri).
public enum Fmt {
    /// `value` 0…100 aralığında. Türkçe: "%12,5" · İngilizce: "12.5%".
    public static func percent(_ value: Double, digits: Int = 0) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(digits)).locale(Loc.locale))
    }

    /// Türkçe: "1,5" · İngilizce: "1.5". Binlik ayırıcı kullanılmaz.
    public static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(Loc.locale))
    }

    /// Bellek boyutu, ör. "136,5 MB" / "136.5 MB".
    public static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory).locale(Loc.locale))
    }
}
