#!/bin/zsh
# 2. adım: Apple'dan indirilen .cer dosyasını 1. adımdaki anahtarla birleştirir,
# login anahtarlığına kurar ve GitHub Actions için şifreli bir .p12 üretir.
#
#   ./scripts/signing/2-import-cert.sh ~/Downloads/developer_id_application.cer
set -euo pipefail
CER=${1:?Kullanım: $0 indirilen.cer}
DIR="$HOME/.liman-signing"
KEY="$DIR/developer-id.key"
[[ -f "$KEY" ]] || { echo "Önce 1-make-csr.sh çalıştırın ($KEY yok)"; exit 1; }

# Apple'ın ara sertifikası (CLT kurulumlarında eksik olabilir; codesign zinciri için gerekli)
if ! security find-certificate -c "Developer ID Certification Authority" >/dev/null 2>&1; then
  curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$DIR/DeveloperIDG2CA.cer"
  security import "$DIR/DeveloperIDG2CA.cer" -k ~/Library/Keychains/login.keychain-db >/dev/null
  echo "✓ Apple Developer ID G2 ara sertifikası kuruldu"
fi

openssl x509 -inform DER -in "$CER" -out "$DIR/developer-id.pem"
read -rs "P12PASS?.p12 için bir parola belirleyin (GitHub secret'ı olacak): "; echo
# -legacy: macOS `security`, OpenSSL 3'ün varsayılan .p12 şifrelemesini okuyamıyor
openssl pkcs12 -export -legacy -inkey "$KEY" -in "$DIR/developer-id.pem" \
  -out "$DIR/developer-id.p12" -passout "pass:$P12PASS"
chmod 600 "$DIR/developer-id.p12"
security import "$DIR/developer-id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P "$P12PASS" -T /usr/bin/codesign >/dev/null
echo "✓ Anahtarlığa kuruldu. İmzalama kimliği:"
security find-identity -v -p codesigning | grep "Developer ID Application" || {
  echo "✗ Kimlik görünmüyor — ara sertifika veya .cer dosyasını kontrol edin"; exit 1; }
echo
echo "Yerel imzalı derleme:"
echo '  SIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./scripts/build-app.sh'
