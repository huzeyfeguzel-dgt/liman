# Değişiklik günlüğü

## [0.2.0] — yayımlanmadı

### Değişti
- **Varsayılan arka uç artık Colima.** Yeni kurulumlar Colima ile başlar; Apple container'a Genel bakış ya da Ayarlar'dan elle geçilebilir. Arka ucu hiç elle seçmemiş mevcut kullanıcılar kullandıkları arka uçta kalır.
- İlk kurulum ekranı Colima için `colima docker docker-compose` paketlerini birlikte kurar.
- Homebrew cask'ı `container` yerine `colima` ve `docker`'a bağımlı.
- Ana pencere kapanınca (ya da ⌘Q / Dock'tan "Çık") Liman menü çubuğuna küçülür; Dock simgesi pencere kapalıyken gizlenir. Servis ve konteynerler çalışmaya devam eder.
- Menü çubuğundaki güç menüsü tek seçeneğe indi: **Liman'ı tamamen kapat**. Servis, socktainer ve çalışma zamanı ("çalışma zamanını kapat" tercihinden bağımsız olarak) durdurulur, ardından uygulama çıkar.

### Eklendi
- Ayarlar'a ana pencerenin kenar çubuğundan ve menü çubuğu panelinden dişli simgesiyle (⌘,) erişim.
- Arayüz metinleri Türkçe / İngilizce.
<!-- TODO: v0.1.0'dan bu yana gelen diğer değişiklikler (ana pencere, Konteynerler sayfası vb.) eklenecek. -->

## [0.1.0]
- İlk sürüm.
