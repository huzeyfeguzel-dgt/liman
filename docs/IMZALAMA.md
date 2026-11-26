# İmzalama ve notarization

## Neden gerekli?

macOS, internetten indirilen her uygulamaya "karantina" işareti koyar. Gatekeeper o uygulamayı açmadan önce iki şeye bakar:

1. **Developer ID imzası:** uygulamayı kimin yaptığını kanıtlar. Apple'ın verdiği bir sertifikayla atılır.
2. **Notarization:** Apple'ın uygulamayı otomatik taradığı ve "zararlı yazılım yok" diye onay damgası verdiği adım.

Bu ikisi yoksa (Liman v0.1.0 şu an böyle, ad-hoc imzalı) kullanıcı *"Liman açılamıyor çünkü Apple kötü amaçlı yazılım olup olmadığını denetleyemiyor"* uyarısını görür. Bunu aşmak için terminalde `xattr -dr com.apple.quarantine` çalıştırması gerekir. Kendin için sorun değil, ama başkalarına dağıtırken güven ve kolaylık açısından kötü.

App Store gerekmez: **Developer ID**, App Store dışı (GitHub, web sitesi, Homebrew) dağıtım için tasarlanmış yoldur.

## Ne gerekiyor?

| | Nereden | Kaç kez |
|---|---|---|
| Apple Developer Program üyeliği | developer.apple.com/programs/enroll | Yıllık $99 |
| **Developer ID Application** sertifikası | Developer hesabı → Certificates | 1 kez (5 yıl geçerli) |
| **App Store Connect API anahtarı** (.p8) | App Store Connect → Users and Access → Integrations | 1 kez |

**Bireysel mi, kurum mu?**
- **Bireysel üyelik:** imzada senin adın görünür ("Developer ID Application: Ad Soyad").
- **Kurum üyeliği:** şirket adı görünür, ama D-U-N-S numarası ister ve onay süreci daha uzundur.

## Adımlar

### 0. Üyelik

developer.apple.com/programs/enroll → Apple Hesabınla kaydol, ödemeyi yap. Onay genelde 24–48 saat sürer. Onaylanınca **Team ID**'n (10 karakter, ör. `AB12CD34EF`) Membership sayfasında görünür.

### 1. Sertifika isteği (CSR)

```bash
./scripts/signing/1-make-csr.sh "Ad Soyad" eposta@ornek.com
```

- Özel anahtar yalnızca bu Mac'te, `~/.liman-signing/` altında kalır.
- Apple'a sadece CSR'ı yüklersin.

Sonra: developer.apple.com/account/resources/certificates/add → **Developer ID Application** → *Profile Type: G2 Sub-CA* → `~/.liman-signing/developer-id.csr`'ı yükle → `.cer` dosyasını indir.

### 2. Sertifikayı kur

```bash
./scripts/signing/2-import-cert.sh ~/Downloads/developer_id_application.cer
```

Betik şunları yapar:
- Apple'ın ara sertifikasını kurar (Xcode olmayan Mac'lerde eksiktir).
- Sertifikayı login anahtarlığına ekler.
- GitHub için şifreli bir `.p12` üretir.

Kontrol:

```bash
security find-identity -v -p codesigning
#  1) ABCD…  "Developer ID Application: Ad Soyad (AB12CD34EF)"
```

### 3. Notarization için API anahtarı

1. appstoreconnect.apple.com → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** → **+**
2. Ad: `liman-notary`, Access: **Developer** → Generate
3. **`AuthKey_XXXX.p8`'i indir. Yalnızca bir kez indirilebilir, güvenli bir yerde sakla.**
4. Aynı sayfadaki **Key ID** ve **Issuer ID** değerlerini not al.

### 4. GitHub secret'ları

```bash
./scripts/signing/3-set-github-secrets.sh ~/Downloads/AuthKey_XXXX.p8
```

Betik `.p12` parolasını, Key ID'yi ve Issuer ID'yi sorar, sonra depoya 6 secret yükler:

- `MACOS_CERT_P12`
- `MACOS_CERT_PASSWORD`
- `MACOS_SIGN_IDENTITY`
- `NOTARY_KEY_P8`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER_ID`

### 5. İmzalı sürüm çıkar

```bash
git tag v0.1.1 && git push origin v0.1.1
```

`release.yml` secret'ları görünce şunları yapar:
- socktainer'ı, ajanı ve uygulamayı hardened runtime ile imzalar.
- DMG'yi Apple'a notarize ettirir ve onayı DMG'ye "zımbalar" (staple).
- Release notlarından `xattr` talimatı otomatik kalkar.

### Doğrulama

İndirilen DMG'yi kontrol etmek için:

```bash
spctl -a -vvv -t install Liman-0.1.1.dmg     # "accepted  source=Notarized Developer ID"
xcrun stapler validate Liman-0.1.1.dmg       # "The validate action worked!"
codesign -dv --verbose=2 /Applications/Liman.app 2>&1 | grep -E "Authority|TeamIdentifier|Runtime"
```

## Yerelde imzalı derleme (isteğe bağlı)

```bash
xcrun notarytool store-credentials liman-notary --key ~/Downloads/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
SIGN_IDENTITY="Developer ID Application: Ad Soyad (AB12CD34EF)" NOTARY_PROFILE=liman-notary \
GITHUB_REPO=huzeyfeguzel-dgt/liman ./scripts/build-app.sh
```

## Güvenlik notları

- `~/.liman-signing/` (özel anahtar ve `.p12`) ile `.p8` dosyasını **asla** commit'leme. `.gitignore` bu uzantıları zaten dışlıyor.
- Anahtar sızarsa: developer.apple.com'dan sertifikayı **Revoke** et, App Store Connect'ten API anahtarını sil, GitHub secret'larını yenile.
- Sertifika 5 yılda bir yenilenir. Yenilemede 1, 2 ve 4. adımları tekrarla.
