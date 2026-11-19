#!/usr/bin/env bash
# Установка прокси Music Player на сервер (Ubuntu 22.04/24.04, Debian 12).
#
# Запуск на сервере под root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/neco-ars/Player-non-prottect-/main/proxy-vps/install.sh)
#
# Необязательные переменные:
#   ALLOWED_ORIGIN=https://nick.github.io   — с какого сайта принимать запросы (по умолчанию — сайт проекта)
#   DOMAIN=proxy.example.ru                 — свой домен; без него берётся адрес вида 1-2-3-4.sslip.io
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/neco-ars/Player-non-prottect-/main/proxy-vps"
ALLOWED_ORIGIN="${ALLOWED_ORIGIN:-https://neco-ars.github.io}"
APP_DIR=/opt/music-proxy

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти от root (sudo -i)." >&2
  exit 1
fi

echo "==> Обновляю список пакетов"
apt-get update -qq

echo "==> Ставлю python3, curl, caddy (HTTPS с бесплатным сертификатом)"
apt-get install -y -qq python3 curl ca-certificates >/dev/null
if ! apt-get install -y -qq caddy >/dev/null 2>&1; then
  # в старых системах caddy нет в стандартных пакетах — берём из официального репозитория Caddy
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi

echo "==> Скачиваю прокси"
mkdir -p "$APP_DIR"
if [ -f "$(dirname "$0")/server.py" ]; then
  cp "$(dirname "$0")/server.py" "$APP_DIR/server.py"
else
  curl -fsSL "$REPO_RAW/server.py" -o "$APP_DIR/server.py"
fi

echo "==> Автозапуск (systemd)"
cat > /etc/systemd/system/music-proxy.service <<EOF
[Unit]
Description=Music Player proxy
After=network-online.target
Wants=network-online.target

[Service]
Environment=ALLOWED_ORIGIN=$ALLOWED_ORIGIN
Environment=PORT=8787
ExecStart=/usr/bin/python3 $APP_DIR/server.py
Restart=always
RestartSec=3
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now music-proxy >/dev/null
systemctl restart music-proxy

echo "==> Адрес сервера"
if [ -z "${DOMAIN:-}" ]; then
  IP="$(curl -fsS4 --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')"
  DOMAIN="$(echo "$IP" | tr . -).sslip.io"
fi

echo "==> HTTPS для $DOMAIN"
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  encode gzip
  reverse_proxy 127.0.0.1:8787
}
EOF
systemctl enable --now caddy >/dev/null
systemctl reload caddy || systemctl restart caddy

# открыть порты, если включён файрвол
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi

echo "==> Проверка (сертификат выдаётся до минуты)"
for i in $(seq 1 30); do
  if [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null)" = "400" ]; then
    break
  fi
  sleep 3
done
STATUS="$(curl -sS --max-time 10 "https://$DOMAIN/" 2>&1 || true)"

echo
if [ "$STATUS" = "Bad url" ]; then
  echo "✅ Прокси работает: https://$DOMAIN"
else
  echo "⚠️  Прокси запущен, но проверка по HTTPS не прошла: $STATUS"
  echo "   Проверь, что у сервера открыты порты 80 и 443 (в панели хостинга), и подожди пару минут."
fi
echo
echo "Дальше: в репозитории GitHub → Settings → Secrets and variables → Actions → Variables"
echo "        переменная PROXY_URL = https://$DOMAIN  — и выпусти новую версию (или перезапусти сборку)."
