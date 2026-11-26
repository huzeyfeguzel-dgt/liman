# Liman

Apple `container` ve Colima için **arka plan servisi + menü çubuğu (tray) uygulaması**. Docker Desktop'ın yerine, minimum kaynakla `docker` / `docker compose` deneyimi sunar.

```
┌──────────────── Liman.app ────────────────┐
│ Liman (tray, SwiftUI MenuBarExtra)        │  durum simgesi · Başlat / Durdur / Yeniden başlat
│   │  launchctl bootstrap / bootout        │  konteyner listesi · loglar · ayarlar · güncelleme
│   ▼                                       │
│ LimanAgent (launchd: app.liman.agent)     │  tray kapalıyken de çalışır, çökerse launchd yeniden başlatır
│   ├─ container system start/stop          │
│   ├─ Helpers/socktainer  (Docker API)     │  ~/.socktainer/container.sock
│   └─ ya da colima start/stop              │  ~/.colima/default/docker.sock
└───────────────────────────────────────────┘
     ▲ agent-config.json (tray yazar)   agent-status.json (ajan yazar, 5 s'de bir) ▼
       ~/Library/Application Support/Liman/
```

## Özellikler

- **Arka plan servisi (`LimanAgent`)**: `~/Library/LaunchAgents/app.liman.agent.plist` ile launchd altında çalışır.
  - Seçili çalışma zamanını ayakta tutar. socktainer ölürse 5 s içinde yeniden başlatır. Ajan çökerse launchd onu yeniden başlatır (`KeepAlive.SuccessfulExit = false`).
  - `SIGTERM` alınca (Durdur) socktainer'ı ve çalışma zamanını düzgünce kapatır.
- **Tray**:
  - Simge durumu gösterir: dolu kutu = çalışıyor, boş kutu = durdu, oklar = geçişte, ünlem = hata. Yanında çalışan konteyner sayısı yazar.
  - Servis kontrolleri: **Başlat**, **Durdur**, **Yeniden başlat** (konteynerlere dokunmaz).
  - Çıkış menüsü: "Arayüzü kapat (servis çalışmaya devam eder)" veya "Servisi durdur ve çık".
- **İki arka uç**:
  - Apple container: konteyner başına mikro-VM, boşta ~50 MB.
  - Colima: tek VM, tam Docker uyumluluğu.
  - Arka uç değişince servis eski çalışma zamanını kapatıp yenisini açar ve `docker context` otomatik eşitlenir.
- **Konteynerler**: compose projelerine göre gruplanır. Canlı RAM/CPU, port linkleri, başlat/durdur/yeniden başlat/sil, loglar (filtre + takip), Terminal'de kabuk.
- **Bellek bekçisi**: eşik aşılınca bildirim gönderir, istenirse konteyneri otomatik yeniden başlatır. Neden gerekli: Virtualization.framework belleği host'a tam geri vermiyor.
- **İlk kurulum**: eksik CLI'ları Homebrew ile kurar. Linux çekirdeğini kopmalara dayanıklı indirir, SHA-256 ile doğrular ve kurar.
- **GitHub'dan güncelleme kontrolü**: `releases/latest` okunur, yeni sürüm varsa menüde "İndir" bandı çıkar.
- **Loglar**:
  - `~/Library/Logs/Liman/agent.log`: servis
  - `socktainer.log`
  - `app.log`: tray

## Gereksinimler

- Apple Silicon, **macOS 26+**
- `brew install container`. Colima isteğe bağlı: `brew install colima docker docker-compose`.
- Derlemek için Xcode **gerekmez**: Command Line Tools + Swift 6 yeterli.

## Geliştirme

```bash
swift build                                   # Liman + LimanAgent + LimanCore
./scripts/build-app.sh                        # dist/Liman.app + dist/Liman-<sürüm>.dmg (ad-hoc imza)
```

Kurulu uygulama için otomatik duman testi (servis, Docker API, port, compose, çökme kurtarma):

```bash
./scripts/smoke-test.sh           # tümü (~40 s)
./scripts/smoke-test.sh --quick   # çökme testleri hariç
```

Önizleme ve test düzeneği, menü çubuğuna tıklamadan ekranları normal bir pencerede açar ve ekran görüntüsü alır:

```bash
dist/Liman.app/Contents/MacOS/Liman --preview menu|logs|settings-general|settings-memory|settings-diagnostics \
  [--action start|stop|restart|kernel|backend-apple|backend-colima] \
  [--snapshot out.png --delay 3 --every 5 --count 4]
```

## GitHub üzerinden dağıtım

1. Depoyu GitHub'a gönderin. `ci.yml` her push ve PR'da derler, ad-hoc DMG'yi artifact olarak yükler.
2. Sürüm çıkarmak için:
   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```
   `release.yml` şunları yapar:
   - DMG'yi derler.
   - Secret'lar varsa imzalar ve notarize eder.
   - **GitHub Release** oluşturur: `Liman-0.2.0.dmg`, `.sha256` ve hazır `liman.rb` cask'ı yüklenir.
   - Depo adı Info.plist'e (`LimanGitHubRepo`) yazılır. Uygulama içi güncelleme kontrolü bu Release'leri izler.
3. **Homebrew**: Release'teki `liman.rb`'yi bir tap deposuna (`sahip/homebrew-tap/Casks/liman.rb`) koyun. Kurulum:
   ```bash
   brew install --cask sahip/tap/liman
   ```
   Cask kaldırılırken launchd servisini de kaldırır.

### İmzalama (önerilir)

Adım adım rehber ve yardımcı betikler: **[docs/IMZALAMA.md](docs/IMZALAMA.md)**

Developer ID yoksa DMG ad-hoc imzalı çıkar. Kullanıcıların ilk açılıştan önce şu komutu çalıştırması gerekir (Release notlarına otomatik eklenir):

```bash
xattr -dr com.apple.quarantine /Applications/Liman.app
```

Gatekeeper'dan sorunsuz geçmek için Apple Developer Program üyeliğiyle aşağıdaki repo secret'larını ekleyin:

| Secret | İçerik |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application sertifikası (.p12, base64) |
| `MACOS_CERT_PASSWORD` | .p12 parolası |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Ad Soyad (TEAMID)` |
| `NOTARY_KEY_P8` | App Store Connect API anahtarı (.p8, base64) |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | API anahtar kimlikleri |

Yerelde imzalı derleme:

```bash
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=liman-notary GITHUB_REPO=sahip/liman ./scripts/build-app.sh
```

## Bilinen sınırlar

- socktainer, Docker API'sinin tamamını desteklemiyor (kapsam kısmi). Uç durumlarda Colima'ya geçin.
- Ajan aynı anda tek arka uç yönetir. Arka uç değişimi eski çalışma zamanındaki konteynerleri durdurur.
- Görüntü/volume yönetimi ekranları, `container system dns` (`*.test`) arayüzü ve otomatik güncelleme kurulumu (Sparkle) henüz yok. Güncelleme yalnızca bildirilir.
- Yalnızca arm64.
