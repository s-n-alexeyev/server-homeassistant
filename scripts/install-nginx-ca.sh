#!/bin/bash
set -e

if [ "$EUID" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "===================================================="
echo "  Генератор Nginx конфигурации"
echo "  для Home Assistant"
echo "===================================================="
echo

# --- Установка Nginx и OpenSSL (без изменений) ---
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

# --- Определение server_name (NetBird) — без изменений ---
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

# --- Определение IP Home Assistant через Proxmox (логика из change-haos-ip.sh) ---
# Находим VMID виртуальной машины HA
VMID=$(qm list 2>/dev/null | grep -iE 'ha|home|haos' | awk 'NR==1{print $1}')
if [ -z "$VMID" ]; then
  echo "[!] Home Assistant VM не найдена в Proxmox."
  read -r -p "Введите IP Home Assistant вручную: " BACKEND_IP
  if [ -z "$BACKEND_IP" ]; then
    echo "[-] IP не введён. Выход."
    exit 1
  fi
else
  echo "[+] Найдена HA VM: VMID=$VMID"

  # Получаем MAC виртуальной сетевой карты
  MAC=$(qm config "$VMID" 2>/dev/null | grep -oE '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' | head -n1 | tr '[:upper:]' '[:lower:]')
  if [ -z "$MAC" ]; then
    echo "[!] MAC VM не найден."
    read -r -p "Введите IP Home Assistant вручную: " BACKEND_IP
  else
    echo "[+] MAC: $MAC"

    # Ищем IP VM в ARP/neighbor table (до 5 попыток)
    CURRENT_IP=""
    for i in {1..5}; do
      CURRENT_IP=$(ip neigh 2>/dev/null | awk -v mac="$MAC" '
        tolower($0) ~ mac { print $1; exit }
      ')
      [ -n "$CURRENT_IP" ] && break
      sleep 1
    done

    if [ -z "$CURRENT_IP" ]; then
      echo "[!] Не удалось автоматически определить IP HAOS."
      read -r -p "Введите текущий IP HAOS: " CURRENT_IP
    fi

    if ! [[ "$CURRENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "[-] Ошибка: неправильный IP: $CURRENT_IP"
      read -r -p "Введите IP Home Assistant вручную: " BACKEND_IP
    else
      BACKEND_IP="$CURRENT_IP"
    fi
  fi
fi

# Если по какой-то причине BACKEND_IP всё ещё пуст — запрашиваем принудительно
if [ -z "$BACKEND_IP" ]; then
  read -r -p "Введите IP Home Assistant: " BACKEND_IP
  if [ -z "$BACKEND_IP" ]; then
    echo "[-] IP не введён. Выход."
    exit 1
  fi
fi

echo "[+] Home Assistant: $BACKEND_IP"
echo "[+] NetBird DNS: $DEFAULT_NETBIRD"
echo

# --- Ввод server_name и подтверждение backend (оставляем возможность ручной правки) ---
read -r -p "Введите server_name [$DEFAULT_NETBIRD]: " NETBIRD_NAME
NETBIRD_NAME=${NETBIRD_NAME:-$DEFAULT_NETBIRD}

read -r -p "Введите IP Home Assistant [$BACKEND_IP]: " BACKEND_IP_INPUT
BACKEND_IP=${BACKEND_IP_INPUT:-$BACKEND_IP}

# --- Далее всё без изменений (конфигурация, SSL, Nginx) ---
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
echo

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

$SUDO ln -sf "$CONFIG_PATH" "$CONFIG_LINK"

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
