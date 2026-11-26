#!/bin/zsh
# 3. adım: İmzalama ve notarization bilgilerini GitHub depo secret'larına yükler.
# Değerler ekrana yazılmaz; doğrudan `gh secret set`e borulanır.
#
#   ./scripts/signing/3-set-github-secrets.sh ~/Downloads/AuthKey_ABC123XYZ.p8
set -euo pipefail
P8=${1:?Kullanım: $0 AuthKey_XXXX.p8  (App Store Connect API anahtarı)}
REPO=${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
P12="$HOME/.liman-signing/developer-id.p12"
[[ -f "$P12" ]] || { echo "Önce 2-import-cert.sh çalıştırın ($P12 yok)"; exit 1; }

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { echo "Anahtarlıkta Developer ID Application kimliği yok"; exit 1; }
echo "Depo:    $REPO"
echo "Kimlik:  $IDENTITY"
read -rs "P12PASS?.p12 parolası (2. adımda belirlediğiniz): "; echo
read -r "KEYID?App Store Connect Key ID (ör. ABC123XYZ): "
read -r "ISSUER?App Store Connect Issuer ID (UUID): "

base64 -i "$P12" | gh secret set MACOS_CERT_P12 -R "$REPO"
print -rn -- "$P12PASS"  | gh secret set MACOS_CERT_PASSWORD -R "$REPO"
print -rn -- "$IDENTITY" | gh secret set MACOS_SIGN_IDENTITY -R "$REPO"
base64 -i "$P8" | gh secret set NOTARY_KEY_P8 -R "$REPO"
print -rn -- "$KEYID"    | gh secret set NOTARY_KEY_ID -R "$REPO"
print -rn -- "$ISSUER"   | gh secret set NOTARY_ISSUER_ID -R "$REPO"
echo "✓ 6 secret yüklendi:"; gh secret list -R "$REPO"
echo
echo "Yerel notarization profili de isterseniz:"
echo "  xcrun notarytool store-credentials liman-notary --key $P8 --key-id $KEYID --issuer $ISSUER"
