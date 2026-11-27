# Değişiklik günlüğü

## [0.2.0] — 2026-11-27

Liman artık yalnızca bir menü çubuğu uygulaması değil: ana penceresi, Dock simgesi ve menü çubuğu kısayolu olan bir masaüstü uygulaması. Varsayılan çalışma zamanı Colima.

### Değişti
- **Varsayılan arka uç artık Colima.** Yeni kurulumlar Colima ile başlar; Apple container'a Genel bakış ya da Ayarlar'dan elle geçilebilir. Arka ucu hiç elle seçmemiş mevcut kullanıcılar kullandıkları arka uçta kalır.
- İlk kurulum ekranı Colima için `colima`, `docker` ve `docker-compose` paketlerini birlikte kurar.
- Homebrew cask'ı `container` yerine `colima` ve `docker`'a bağımlı.
- Uygulama artık Dock'ta görünür (`LSUIElement` kaldırıldı). Ayarlar'dan Dock simgesi ve menü çubuğu simgesi ayrı ayrı kapatılabilir; en az biri açık kalır.
- **Pencereyi kapatmak uygulamayı kapatmaz.** Ana pencere kapanınca (ya da ⌘Q / Dock'tan "Çık") Liman menü çubuğuna küçülür, Dock simgesi gizlenir. Servis ve konteynerler çalışmaya devam eder. Menü çubuğu simgesi kapalıysa Liman Dock'ta kalır ve ⌘Q tam kapanış yapar.
- **Tam kapanış menü çubuğundan yapılır.** Güç menüsündeki "Liman'ı tamamen kapat" arka plan servisini, socktainer'ı ve çalışma zamanını (`colima stop` / `container system stop`) durdurur, ardından uygulamadan çıkar. "Servis durunca çalışma zamanını da kapat" tercihi kapalı olsa bile bu kapanışta çalışma zamanı durur. Eski "Arayüzü kapat" ve "Servisi durdur ve çık" seçenekleri kaldırıldı.
- Ayrı "Liman Logları" penceresi kaldırıldı; loglar ana pencerenin Loglar sayfasında.
- Menü çubuğu paneli yenilendi: "Liman'ı aç" kısayolu (⌘O), servis başlat/durdur ve Ayarlar düğmeleri alt çubukta.

### Eklendi
- **Ana pencere** (kenar çubuğuyla dört sayfa, ⌘1…⌘4):
  - **Genel bakış**: arka uç seçimi, servis durumu, metrik kutucukları (çalışan konteyner, CPU, konteyner belleği, host'ta VM belleği), son 15 dakikanın canlı CPU ve bellek grafikleri, çalışan konteynerler ve konteyner başına bellek / limit grafiği.
  - **Konteynerler**: Docker Desktop benzeri tablo. Çoklu seçim, toplu başlat / durdur / yeniden başlat / sil, daraltılabilir compose projesi satırları (proje toplamı CPU/bellek), arama ve "yalnızca çalışanlar" filtresi.
  - **Loglar**: konteyner seçimi, filtre ve takip.
  - **Kaynaklar**: çalışma zamanının kaynak ayarları.
- **"Servis" menüsü**: Başlat ⇧⌘R, Durdur ⇧⌘., Yeniden başlat ⌥⌘R, tüm konteynerleri durdur, servis logunu aç.
- **Apple container kaynak yönetimi**: Liman, `~/.config/container/config.toml` içindeki konteyner ve BuildKit builder CPU/bellek varsayılanlarını host'a göre önerilen değerlerle yönetir. Builder'ın yerleşik 2 GB sınırı yüzünden kopan `docker build` / devcontainer derlemeleri (`StreamClosed … Cancel`) bununla düzelir. Builder'ın kayıtlı kaynakları farklıysa yeniden oluşturulur.
- **Colima VM kaynak yönetimi** (isteğe bağlı, varsayılan kapalı): CPU, bellek ve disk; VM boyutu farklıysa Colima yeni değerlerle yeniden başlatılır. Disk yalnızca büyütülebilir.
- Ayarlar'a yeni **Kaynaklar** sekmesi. Ayarlar'a ana pencerenin kenar çubuğundan ve menü çubuğu panelinden dişli simgesiyle (⌘,) erişilir.
- **Türkçe / İngilizce arayüz**: Ayarlar › Genel'den seçilir ya da macOS dil tercihini izler.
- Önizleme düzeneğine ana pencere sayfaları (`--preview main|main-containers|main-logs|main-resources`) ve servise dokunmayan `--readonly` kipi.

### Geliştirme
- Developer ID imzalama ve notarization için adım adım rehber ([docs/IMZALAMA.md](docs/IMZALAMA.md)) ve yardımcı betikler (`scripts/signing/`).
- İmzalama malzemesi (`*.p12`, `*.p8`, `*.cer`, `*.csr`, `*.key`, `*.pem`) `.gitignore`'a eklendi.
- `build-app.sh` varsayılan sürümü 0.2.0.

## [0.1.0]
- İlk sürüm: Apple container ve Colima için menü çubuğu uygulaması ve launchd arka plan servisi (`LimanAgent`), socktainer ile Docker API, bellek bekçisi, ilk kurulum ve Linux çekirdeği indirme, GitHub'dan güncelleme kontrolü.
