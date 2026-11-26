#!/bin/zsh
# Liman yerel duman testi: servis, Docker API, compose ve çökme kurtarma.
#
#   ./scripts/smoke-test.sh            # tüm testler
#   ./scripts/smoke-test.sh --quick    # çökme testlerini atla
#
# Gereken: Liman.app kurulu ve servis çalışıyor (menüden "Başlat"), docker CLI + docker compose.
# Test kendi konteynerlerini (liman-smoke-*) oluşturur ve sonunda siler.
set -u
QUICK=${1:-}
U="gui/$(id -u)"
SVC="$U/app.liman.agent"
STATUS="$HOME/Library/Application Support/Liman/agent-status.json"
SOCK="$HOME/.socktainer/container.sock"
PASS=0; FAIL=0
ok()   { print -P "  %F{green}✓%f $1"; PASS=$((PASS+1)); }
bad()  { print -P "  %F{red}✗%f $1"; FAIL=$((FAIL+1)); }
step() { print -P "\n%B$1%b"; }
state(){ python3 -c "import json;print(json.load(open('$STATUS'))['state'])" 2>/dev/null || echo yok; }
backend(){ python3 -c "import json;print(json.load(open('$STATUS'))['backend'])" 2>/dev/null || echo yok; }
agent_pid(){ launchctl print "$SVC" 2>/dev/null | awk '/^\tpid =/{print $3}'; }
wait_state(){ for _ in {1..40}; do [[ "$(state)" == "$1" ]] && return 0; sleep 1; done; return 1; }
cleanup(){ docker rm -f liman-smoke-web >/dev/null 2>&1; [[ -n "${STACK:-}" ]] && docker compose -f "$STACK/compose.yaml" -p liman-smoke down -v >/dev/null 2>&1; rm -rf "${STACK:-/nonexistent}"; }
trap cleanup EXIT

step "1. Servis (launchd)"
launchctl print "$SVC" >/dev/null 2>&1 && ok "app.liman.agent yüklü (pid $(agent_pid))" || { bad "servis yüklü değil — Liman menüsünden Başlat'a basın"; exit 1; }
[[ "$(state)" == running ]] && ok "ajan durumu: running ($(backend))" || bad "ajan durumu: $(state)"
PROG=$(launchctl print "$SVC" | awk '/^\tprogram =/{print $3}')
[[ "$PROG" == /Applications/* ]] && ok "ajan /Applications'tan çalışıyor" || bad "ajan yolu beklenmedik: $PROG"

step "2. Docker API ve CLI"
if [[ "$(backend)" == apple ]]; then
  curl -s -m 3 --unix-socket "$SOCK" http://d/_ping | grep -q OK && ok "socktainer soketi yanıt veriyor" || bad "socktainer soketi yanıt vermiyor"
fi
[[ "$(docker context show)" == "$(backend)" ]] && ok "docker context = $(docker context show)" || bad "docker context $(docker context show), beklenen $(backend)"
docker run --rm alpine:latest true >/dev/null 2>&1 && ok "docker run çalışıyor" || bad "docker run başarısız"

step "3. Port yayınlama"
docker run -d --name liman-smoke-web -p 18080:80 --memory 256m nginx:alpine >/dev/null 2>&1
for _ in {1..15}; do code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' localhost:18080); [[ $code == 200 ]] && break; sleep 1; done
[[ $code == 200 ]] && ok "localhost:18080 → 200" || bad "nginx yanıtı: $code"

step "4. docker compose (nginx + redis)"
STACK=$(mktemp -d)
cat > "$STACK/compose.yaml" <<'EOF'
services:
  web: { image: "nginx:alpine", ports: ["18081:80"], depends_on: [cache] }
  cache: { image: "redis:7-alpine" }
EOF
docker compose -f "$STACK/compose.yaml" -p liman-smoke up -d >/dev/null 2>&1 && ok "compose up" || bad "compose up başarısız"
sleep 3
[[ "$(docker compose -f "$STACK/compose.yaml" -p liman-smoke exec -T cache redis-cli ping 2>/dev/null)" == PONG ]] && ok "redis PONG (compose exec)" || bad "redis yanıt vermedi"

if [[ "$QUICK" != --quick ]]; then
  step "5. Çökme kurtarma: socktainer öldürülüyor"
  if [[ "$(backend)" == apple ]]; then
    pkill -9 -f "Liman.app/Contents/Helpers/socktainer"
    sleep 8
    curl -s -m 3 --unix-socket "$SOCK" http://d/_ping | grep -q OK && ok "socktainer 8 s içinde geri geldi" || bad "socktainer geri gelmedi"
  else
    ok "Colima arka ucu — atlandı"
  fi

  step "6. Çökme kurtarma: ajan kill -9"
  OLD=$(agent_pid); kill -9 "$OLD"; sleep 13
  NEW=$(agent_pid)
  [[ -n "$NEW" && "$NEW" != "$OLD" ]] && ok "launchd ajanı yeniden başlattı ($OLD → $NEW)" || bad "ajan yeniden başlamadı"
  wait_state running && ok "durum tekrar running" || bad "durum: $(state)"
  code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' localhost:18080)
  [[ $code == 200 ]] && ok "konteyner çökmeden etkilenmedi (18080 → 200)" || bad "konteyner erişilemiyor: $code"
fi

step "Sonuç"
print -P "  %F{green}$PASS geçti%f, %F{red}$FAIL başarısız%f"
print "  Loglar: ~/Library/Logs/Liman/{agent,socktainer,app}.log"
exit $(( FAIL > 0 ))
