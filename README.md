# Liman

Colima ve Apple `container` için **arka plan servisi + masaüstü uygulaması** (ana pencere, Dock simgesi ve menü çubuğu kısayolu). Docker Desktop'ın yerine, minimum kaynakla `docker` / `docker compose` deneyimi sunar.

```
┌──────────────── Liman.app ────────────────┐
│ Liman (SwiftUI: ana pencere + menü çubuğu)│  genel bakış · konteynerler · loglar · kaynaklar
│   │  launchctl bootstrap / bootout        │  konteyner listesi · loglar · ayarlar · güncelleme
│   ▼                                       │
│ LimanAgent (launchd: app.liman.agent)     │  Liman kapalıyken de çalışır, çökerse launchd yeniden başlatır
│   ├─ container system start/stop          │  ~/.config/container/config.toml (kaynaklar)
│   ├─ Helpers/socktainer  (Docker API)     │  ~/.socktainer/container.sock
│   └─ ya da colima start/stop              │  ~/.colima/default/docker.sock
└───────────────────────────────────────────┘
     ▲ agent-config.json (uygulama yazar)   agent-status.json (ajan yazar, 5 s'de bir) ▼
       ~/Library/Application Support/Liman/
```

## Özellikler

- **Arka plan servisi (`LimanAgent`)**: `~/Library/LaunchAgents/app.liman.agent.plist` ile launchd altında çalışır.
  - Seçili çalışma zamanını ayakta tutar. socktainer ölürse 5 s içinde yeniden başlatır. Ajan çökerse launchd onu yeniden başlatır (`KeepAlive.SuccessfulExit = false`).
  - `SIGTERM` alınca (Durdur) socktainer'ı ve çalışma zamanını düzgünce kapatır.
- **Masaüstü uygulaması** (`Window` + `NavigationSplitView`):
  - **Genel bakış**:
    - Arka uç seçimi ve servis durumu.
    - Metrik kutucukları: çalışan konteyner, CPU, konteyner belleği, host'ta VM belleği.
    - Canlı CPU ve bellek grafikleri (Swift Charts, ~6 s örnekleme, son 15 dakika).
    - Çalışan konteynerler listesi, hızlı eylemlerle.
    - Konteyner başına bellek / limit grafiği.
  - **Konteynerler** (Docker Desktop benzeri tablo):
    - Onay kutularıyla çoklu seçim: tümünü seç, proje bazında seç.
    - Toplu Başlat / Durdur / Yeniden başlat / Sil.
    - Compose projesi satırları: daraltılabilir, proje toplamı CPU/bellek, projeyi başlat/durdur/sil.
    - Her satırda her zaman görünen eylemler: başlat/durdur, yeniden başlat, loglar, terminal, sil.
    - Arama ve "yalnızca çalışanlar" filtresi.
  - **Loglar**: konteyner seçimi, filtre, takip.
  - **Kaynaklar**: Apple container CPU/bellek varsayılanları (aşağıya bakın).
  - Pencere kapanınca (ya da ⌘Q / Dock'tan "Çık") Liman menü çubuğuna küçülür: Dock simgesi gizlenir, uygulama, servis ve konteynerler çalışmaya devam eder. Pencere menü çubuğundan yeniden açılır.
  - Ayarlar: kenar çubuğundaki ve menü çubuğu panelindeki dişli simgesi (⌘,).
  - "Servis" menüsü: Başlat ⇧⌘R, Durdur ⇧⌘., Yeniden başlat ⌥⌘R. Sayfalar ⌘1…⌘4.
  - Ayarlar › Genel: Dock simgesi ve menü çubuğu simgesi ayrı ayrı kapatılabilir (en az biri açık kalır). Menü çubuğu simgesi kapalıyken pencere kapanınca Liman Dock'ta kalır ve ⌘Q tam kapanış yapar.
- **Menü çubuğu**:
  - Simge durumu gösterir: dolu kutu = çalışıyor, boş kutu = durdu, oklar = geçişte, ünlem = hata. Yanında çalışan konteyner sayısı yazar.
  - Servis kontrolleri: **Başlat**, **Durdur**, **Yeniden başlat** (konteynerlere dokunmaz).
  - **Liman'ı tamamen kapat** (güç simgesi): arka plan servisini, socktainer'ı ve çalışma zamanını (`colima stop` / `container system stop`) durdurur, ardından uygulamadan çıkar. Tam kapanışın tek yolu budur.
- **İki arka uç**:
  - **Colima (varsayılan)**: tek VM, tam Docker uyumluluğu.
  - Apple container: konteyner başına mikro-VM, boşta ~50 MB. Genel bakış ya da Ayarlar'dan elle seçilir.
  - Arka uç değişince servis eski çalışma zamanını kapatıp yenisini açar ve `docker context` otomatik eşitlenir.
- **Konteynerler**: compose projelerine göre gruplanır. Canlı RAM/CPU, port linkleri, başlat/durdur/yeniden başlat/sil, loglar (filtre + takip), Terminal'de kabuk.
- **Kaynak yönetimi (Apple container)**: Liman, `~/.config/container/config.toml` içindeki `[container]` ve `[build]` bölümlerinin `cpus` / `memory` anahtarlarını yönetir. Dosyadaki diğer ayarlara dokunmaz.
  - Sorun: Apple'ın yerleşik değerleri konteyner için 4 CPU / 1 GB, BuildKit builder VM'i için 2 CPU / 2 GB. `docker build` ve devcontainer'lar (ör. `mcr.microsoft.com/dotnet/sdk`) bu builder'da derlenir ve 2 GB'ta build `StreamClosed … Cancel` ile kopuyor.
  - Önerilen değerler host'a göre hesaplanır. 8 GB / 8 çekirdekte: konteyner 4 CPU / 2 GB, builder 4 CPU / 4 GB. VM belleği tembel ayrıldığı için limit, kullanılmadıkça RAM tüketmez.
  - Uygulama: ajan config.toml'u yazar. İçerik değiştiyse `container system stop/start` yapar (çalışan konteynerler durur). Builder'ın kayıtlı kaynakları farklıysa `container builder delete --force` + `builder start --cpus --memory` ile yeniden oluşturur, sonra builder'ı durdurur.
  - Konteyner bazında `docker run --memory/--cpus` ve compose `deploy.resources.limits` yine geçerlidir. Buradaki değerler yalnızca limit verilmediğinde kullanılır.
- **Bellek bekçisi**: eşik aşılınca bildirim gönderir, istenirse konteyneri otomatik yeniden başlatır. Neden gerekli: Virtualization.framework belleği host'a tam geri vermiyor.
- **İlk kurulum**: eksik CLI'ları Homebrew ile kurar. Linux çekirdeğini kopmalara dayanıklı indirir, SHA-256 ile doğrular ve kurar.
- **GitHub'dan güncelleme kontrolü**: `releases/latest` okunur, yeni sürüm varsa menüde "İndir" bandı çıkar.
- **Loglar**:
  - `~/Library/Logs/Liman/agent.log`: servis
  - `socktainer.log`
  - `app.log`: uygulama

## Gereksinimler

- Apple Silicon, **macOS 26+**
- `brew install colima docker docker-compose` (varsayılan arka uç). Apple container isteğe bağlı: `brew install container`.
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
dist/Liman.app/Contents/MacOS/Liman --preview main|main-containers|main-logs|main-resources|menu|logs|settings-general|settings-memory|settings-diagnostics \
  [--readonly]   # servise, launchd plist'ine ve docker context'e dokunmaz \
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
