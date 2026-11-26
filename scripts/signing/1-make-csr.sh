#!/bin/zsh
# 1. adım: Developer ID sertifikası için özel anahtar + CSR (sertifika imzalama isteği) üretir.
# Özel anahtar YALNIZCA bu Mac'te, ~/.liman-signing içinde kalır (git'e girmez).
#
#   ./scripts/signing/1-make-csr.sh "Ad Soyad" eposta@ornek.com
set -euo pipefail
NAME=${1:?Kullanım: $0 "Ad Soyad" eposta}
EMAIL=${2:?Kullanım: $0 "Ad Soyad" eposta}
DIR="$HOME/.liman-signing"
mkdir -p "$DIR"; chmod 700 "$DIR"
if [[ -f "$DIR/developer-id.key" ]]; then
  echo "Zaten bir anahtar var: $DIR/developer-id.key (üzerine yazılmadı)"; exit 1
fi
openssl genrsa -out "$DIR/developer-id.key" 2048 2>/dev/null
chmod 600 "$DIR/developer-id.key"
openssl req -new -key "$DIR/developer-id.key" -out "$DIR/developer-id.csr" \
  -subj "/emailAddress=$EMAIL/CN=$NAME/C=TR"
echo "✓ CSR hazır: $DIR/developer-id.csr"
echo
echo "Şimdi: https://developer.apple.com/account/resources/certificates/add"
echo "  → 'Developer ID Application' seç → Profile Type: G2 Sub-CA → bu CSR'ı yükle"
echo "  → indirilen developer_id_application.cer dosyasıyla 2. adımı çalıştır."
