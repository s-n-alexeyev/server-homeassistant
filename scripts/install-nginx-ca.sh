#!/bin/bash

set -e

if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo "===================================================="
echo "    Генератор Nginx конфигурации"
echo "    для Home Assistant"
echo "===================================================="
echo

if ! command -v nginx >/dev/null 2>&1; then
    echo "[+] Nginx не установлен. Установка..."
    $SUDO apt-get update
    $SUDO apt-get install -y nginx
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "[+] OpenSSL не установлен. Установка..."
    $SUDO apt-get update
    $SUDO apt-get install -y openssl
fi

CURRENT_HOSTNAME=$(hostname)

DEFAULT_NETBIRD="${CURRENT_HOSTNAME}.netbird.self-hosted"

if command -v netbird >/dev/null 2>&1; then
    NB_FQDN=$(netbird status 2>/dev/null \
        | grep -i "FQDN" \
        | awk '{print $2}' \
        | head -n1)

    if [ -n "$NB_FQDN" ]; then
        DEFAULT_NETBIRD="$NB_FQDN"
    fi
fi

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

DEFAULT_BACKEND="192.168.1.3"

if [ -n "$LOCAL_IP" ]; then
    SUBNET=$(echo "$LOCAL_IP" | awk -F. '
        NF == 4 {
            print $1"."$2"."$3
            exit
        }
    ')

    if [ -n "$SUBNET" ]; then
        DEFAULT_BACKEND="${SUBNET}.3"
    fi
fi

echo "[+] Обнаруженный IP: ${LOCAL_IP:-не найден}"
echo "[+] Home Assistant: $DEFAULT_BACKEND"
echo "[+] NetBird DNS: $DEFAULT_NETBIRD"
echo

read -r -p "Введите server_name [$DEFAULT_NETBIRD]: " NETBIRD_NAME
NETBIRD_NAME=${NETBIRD_NAME:-$DEFAULT_NETBIRD}

read -r -p "Введите IP Home Assistant [$DEFAULT_BACKEND]: " BACKEND_IP
BACKEND_IP=${BACKEND_IP:-$DEFAULT_BACKEND}

CONFIG_PATH="/etc/nginx/sites-available/ha"
CONFIG_LINK="/etc/nginx/sites-enabled/ha"

SSL_CERT="/etc/ssl/certs/nginx-selfsigned.crt"
SSL_KEY="/etc/ssl/private/nginx-selfsigned.key"

echo
echo "===================================================="
echo "Параметры"
echo "===================================================="
echo "Server name : $NETBIRD_NAME"
echo "Backend IP  : $BACKEND_IP"
echo "Config      : $CONFIG_PATH"
echo "SSL cert    : $SSL_CERT"
echo "SSL key     : $SSL_KEY"
echo "===================================================="
echo

echo "[+] Удаление старой конфигурации Home Assistant..."

$SUDO rm -f "$CONFIG_LINK"
$SUDO rm -f "$CONFIG_PATH"

$SUDO find /etc/nginx/sites-enabled -maxdepth 1 -type l -lname '*ha*' -delete 2>/dev/null || true
$SUDO find /etc/nginx/sites-enabled -maxdepth 1 -type f -iname '*ha*' -delete 2>/dev/null || true

$SUDO find /etc/nginx/sites-available -maxdepth 1 -type f -iname '*ha*' -delete 2>/dev/null || true

echo "[+] Проверка оставшихся конфигураций Home Assistant..."

HA_CONFIGS=$(
    $SUDO grep -RilE \
        'server_name[[:space:]]+[^;]*ha[^;]*;|proxy_pass[[:space:]]+http://[^;]*:8123' \
        /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null || true
)

if [ -n "$HA_CONFIGS" ]; then
    echo "[!] Найдены старые конфигурации Home Assistant:"
    echo "$HA_CONFIGS"
    echo
    echo "[+] Удаление найденных конфигураций..."

    while IFS= read -r FILE; do
        [ -z "$FILE" ] && continue

        case "$FILE" in
            /etc/nginx/sites-enabled/*|/etc/nginx/conf.d/*)
                $SUDO rm -f "$FILE"
                ;;
        esac
    done <<< "$HA_CONFIGS"
fi

echo "[✔] Старые конфигурации Home Assistant удалены."

echo "[+] Проверка SSL сертификата..."

if [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; then
    echo "[+] SSL сертификат уже существует."
else
    echo "[+] Генерация SSL сертификата..."

    $SUDO openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout /etc/ssl/private/nginx-selfsigned.key \
        -out /etc/ssl/certs/nginx-selfsigned.crt \
        -subj "/C=KZ/ST=Almaty/L=Almaty/O=Sarkinhome/OU=Corp/CN=Sarkinhome/emailAddress=sarkinhome@gmail.com"

    $SUDO chmod 600 "$SSL_KEY"
    $SUDO chmod 644 "$SSL_CERT"

    echo "[✔] SSL сертификат создан."
fi

echo "[+] Создание конфигурации Nginx..."

$SUDO tee "$CONFIG_PATH" >/dev/null <<EOF
# 1. SSL-сервер (слушает 443 порт для HTTPS)
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $NETBIRD_NAME;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;

    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 500m;

    location / {
        proxy_pass http://$BACKEND_IP:8123;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
    }
}

# 2. Обычный сервер (доступ по IP на порту 8123)
server {
    listen 8123 default_server;
    listen [::]:8123 default_server;

    server_name _;

    client_max_body_size 500m;
    location / {
        proxy_pass http://$BACKEND_IP:8123;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF

echo "[✔] Конфигурация создана."

echo "[+] Создание symlink..."

$SUDO mkdir -p /etc/nginx/sites-enabled
$SUDO ln -s "$CONFIG_PATH" "$CONFIG_LINK"

echo "[✔] Symlink создан:"
echo "    $CONFIG_LINK -> $CONFIG_PATH"

echo
echo "[+] Проверка конфигурации Nginx..."

if ! $SUDO nginx -t; then
    echo
    echo "[-] ОШИБКА: nginx -t завершился с ошибкой."
    echo "[-] Nginx НЕ перезапускается."
    exit 1
fi

echo "[✔] Конфигурация Nginx корректна."

echo
echo "[+] Перезапуск Nginx..."

$SUDO systemctl restart nginx

echo
echo "[+] Проверка состояния Nginx..."

if $SUDO systemctl is-active --quiet nginx; then
    echo
    echo "===================================================="
    echo "[✔] ГОТОВО"
    echo "===================================================="
    echo
    echo "HTTPS:"
    echo "https://$NETBIRD_NAME"
    echo
    echo "Home Assistant:"
    echo "http://$BACKEND_IP:8123"
    echo
    echo "Конфигурация:"
    echo "$CONFIG_PATH"
    echo
    echo "Symlink:"
    echo "$CONFIG_LINK"
    echo
    echo "Сертификат:"
    echo "$SSL_CERT"
    echo
    echo "Ключ:"
    echo "$SSL_KEY"
    echo
else
    echo
    echo "[-] Nginx не запущен."
    echo
    $SUDO journalctl -u nginx -n 30 --no-pager
    exit 1
fi
