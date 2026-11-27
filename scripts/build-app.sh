#!/bin/zsh
# Liman.app + Liman-<sürüm>.dmg üretir.
#
#   ./scripts/build-app.sh                       # ad-hoc imzalı (yalnızca bu Mac / test)
#   SIGN_IDENTITY="Developer ID Application: Ad (TEAMID)" \
#   NOTARY_PROFILE=liman-notary ./scripts/build-app.sh   # dağıtıma hazır: imzalı + notarize + staple
#
# NOTARY_PROFILE bir kez şöyle oluşturulur:
#   xcrun notarytool store-credentials liman-notary --apple-id <id> --team-id <TEAMID>
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="${VERSION:-0.2.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"          # "-" = ad-hoc
GITHUB_REPO="${GITHUB_REPO:-${GITHUB_REPOSITORY:-__GITHUB_REPO__}}"   # güncelleme kontrolü için sahip/depo
SOCKTAINER="${SOCKTAINER:-$(command -v socktainer || echo /opt/homebrew/opt/socktainer/bin/socktainer)}"
DIST="$ROOT/dist"
APP="$DIST/Liman.app"

echo "▸ Derleniyor (release, arm64)…"
swift build -c release --arch arm64
BINDIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Paket oluşturuluyor…"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BINDIR/Liman" "$APP/Contents/MacOS/Liman"
cp "$BINDIR/LimanAgent" "$APP/Contents/MacOS/LimanAgent"   # launchd arka plan servisi
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s|__GITHUB_REPO__|$GITHUB_REPO|" Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# socktainer'ı göm (Apache-2.0; lisans metni pakete eklenir)
if [[ -x "$SOCKTAINER" ]]; then
  cp "$(readlink -f "$SOCKTAINER")" "$APP/Contents/Helpers/socktainer"
  chmod 755 "$APP/Contents/Helpers/socktainer"
  SOCK_LICENSE="$(dirname "$(readlink -f "$SOCKTAINER")")/../LICENSE"
  mkdir -p "$APP/Contents/Resources/Licenses"
  [[ -f "$SOCK_LICENSE" ]] && cp "$SOCK_LICENSE" "$APP/Contents/Resources/Licenses/socktainer-LICENSE.txt"
  echo "  socktainer gömüldü: $("$APP/Contents/Helpers/socktainer" --version 2>/dev/null | head -1 || echo '?')"
else
  echo "  ⚠️  socktainer bulunamadı; uygulama çalışırken Homebrew kurulumunu arayacak."
fi

echo "▸ Simge…"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ İmzalanıyor ($SIGN_IDENTITY)…"
SIGN_OPTS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_OPTS+=(--options runtime --timestamp); fi
# İçten dışa: önce yardımcı, sonra uygulama
[[ -f "$APP/Contents/Helpers/socktainer" ]] && codesign "${SIGN_OPTS[@]}" "$APP/Contents/Helpers/socktainer"
codesign "${SIGN_OPTS[@]}" --identifier app.liman.agent "$APP/Contents/MacOS/LimanAgent"
codesign "${SIGN_OPTS[@]}" --entitlements Packaging/Liman.entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "  imza doğrulandı"

echo "▸ DMG…"
DMG="$DIST/Liman-$VERSION.dmg"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Liman $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
[[ "$SIGN_IDENTITY" != "-" ]] && codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  echo "▸ Notarize ediliyor…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $APP"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
[[ "$SIGN_IDENTITY" == "-" ]] && echo "ℹ︎  Ad-hoc imza: başka Mac'lerde Gatekeeper engeller. Dağıtım için SIGN_IDENTITY + NOTARY_PROFILE verin."
exit 0
