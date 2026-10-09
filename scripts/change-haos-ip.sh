#!/usr/bin/env bash

VMID=$(qm list | grep -iE 'ha|home|haos' | awk 'NR==1{print $1}')

if [ -z "$VMID" ]; then
    echo "Ошибка: Home Assistant VM не найдена."
    exit 1
fi

echo "VMID: $VMID"

# Получаем MAC виртуальной сетевой карты
MAC=$(qm config "$VMID" |
    grep -oE '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' |
    head -n1 |
    tr '[:upper:]' '[:lower:]')

if [ -z "$MAC" ]; then
    echo "Ошибка: MAC VM не найден."
    exit 1
fi

echo "MAC: $MAC"

# Ищем IP VM в ARP/neighbor table
CURRENT_IP=""

for i in {1..5}; do
    CURRENT_IP=$(ip neigh |
        awk -v mac="$MAC" '
        tolower($0) ~ mac {
            print $1
            exit
        }')

    [ -n "$CURRENT_IP" ] && break
    sleep 1
done

# Если Proxmox не знает IP — спрашиваем
if [ -z "$CURRENT_IP" ]; then
    echo
    echo "Не удалось автоматически определить IP HAOS."
    read -r -p "Введите текущий IP HAOS: " CURRENT_IP
fi

if ! [[ "$CURRENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Ошибка: неправильный IP: $CURRENT_IP"
    exit 1
fi

# Определяем подсеть
SUBNET=$(echo "$CURRENT_IP" | awk -F. '{print $1"."$2"."$3}')

DEFAULT_IP="${SUBNET}.3"
GATEWAY="${SUBNET}.1"

echo
echo "========================================"
echo "Текущий IP : $CURRENT_IP"
echo "Подсеть    : ${SUBNET}.0/24"
echo "Шлюз       : $GATEWAY"
echo "========================================"
echo

read -r -p "Новый IP [$DEFAULT_IP]: " NEW_IP
NEW_IP=${NEW_IP:-$DEFAULT_IP}

if ! [[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Ошибка: неправильный новый IP."
    exit 1
fi

NEW_SUBNET=$(echo "$NEW_IP" | awk -F. '{print $1"."$2"."$3}')

if [ "$NEW_SUBNET" != "$SUBNET" ]; then
    echo "Ошибка: новый IP находится в другой подсети."
    echo "Разрешена подсеть: ${SUBNET}.0/24"
    exit 1
fi

echo
echo "Будет установлено:"
echo
echo "  $CURRENT_IP -> $NEW_IP/24"
echo "  Gateway     -> $GATEWAY"
echo "  DNS         -> $GATEWAY"
echo

read -r -p "Продолжить? [Y/n]: " ANSWER

if [[ "$ANSWER" =~ ^[NnНн]$ ]]; then
    echo "Отмена."
    exit 0
fi

echo
echo "Подключение к VMID $VMID..."

export HA_VMID="$VMID"
export HA_NEW_IP="$NEW_IP/24"
export HA_GATEWAY="$GATEWAY"

expect <<'EOF'
set timeout 30

spawn qm terminal $env(HA_VMID)

sleep 2

send "echo __HA_READY__\r"

expect {
    -re {__HA_READY__} {}
    timeout {
        puts "Ошибка: HAOS shell не отвечает."
        send "\x0f"
        exit 1
    }
}

sleep 1

send "ha network update enp6s18 --ipv4-method static --ipv4-address $env(HA_NEW_IP) --ipv4-gateway $env(HA_GATEWAY) --ipv4-nameserver $env(HA_GATEWAY)\r"

sleep 5

send "\x0f"

exit 0
EOF

echo
echo "========================================"
echo "Готово"
echo "========================================"
echo
echo "Новый IP Home Assistant: $NEW_IP"
echo
echo "Проверка:"
echo "ping -c 4 $NEW_IP"
