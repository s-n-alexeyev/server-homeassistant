#!/usr/bin/env bash

# ============================================================
# HAOS — смена IP + настройка обратного прокси
# ============================================================

set -u

if [ "$EUID" -ne 0 ]; then
    echo "[-] Запускать от root."
    exit 1
fi

for cmd in qm ip awk grep cut ping expect base64 timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[-] Нет команды: $cmd"; exit 1; }
done

echo "===================================================="
echo "   Home Assistant — IP + обратный прокси"
echo "===================================================="
echo

VMID="8123"
qm status "$VMID" >/dev/null 2>&1 || { echo "[-] ВМ $VMID не найдена."; exit 1; }
echo "[+] VMID: $VMID"

CONFIG=$(qm config "$VMID" 2>/dev/null) || { echo "[-] Не прочитать конфиг."; exit 1; }
BRIDGE=$(printf '%s\n' "$CONFIG" | grep -oE 'bridge=[^,]+' | head -n 1 | cut -d= -f2)
MAC=$(printf '%s\n' "$CONFIG" |
    grep -oE '(virtio|e1000|rtl8139|vmxnet3)=[0-9A-Fa-f:]{17}' |
    head -n 1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]')

[ -z "$BRIDGE" ] || [ -z "$MAC" ] && { echo "[-] Не нашёл bridge или MAC."; exit 1; }

echo "[+] Bridge: $BRIDGE"
echo "[+] MAC:    $MAC"

# ---------- Определяем живой IP ----------
CANDIDATES=$(ip neigh show dev "$BRIDGE" 2>/dev/null | awk -v m="$MAC" '
    tolower($0) ~ tolower(m) &&
    $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
    $NF != "FAILED" && $NF != "INCOMPLETE" {
        print $1
    }' | sort -u)

CURRENT_IP=""

if [ -n "$CANDIDATES" ]; then
    echo "[*] Кандидаты из ARP: $(echo $CANDIDATES | tr '\n' ' ')"
    echo "[*] Проверяю живость..."

    for ip in $CANDIDATES; do
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            if timeout 2 bash -c "echo > /dev/tcp/$ip/8123" 2>/dev/null || \
               timeout 2 bash -c "echo > /dev/tcp/$ip/80"   2>/dev/null; then
                CURRENT_IP="$ip"
                echo "[+] Живой IP: $CURRENT_IP (ping + порт)"
                break
            fi
        fi
    done

    if [ -z "$CURRENT_IP" ]; then
        for ip in $CANDIDATES; do
            if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
                CURRENT_IP="$ip"
                echo "[+] Живой IP: $CURRENT_IP (только ping)"
                break
            fi
        done
    fi
fi

if [ -z "$CURRENT_IP" ]; then
    echo "[!] Ни один из ARP-кандидатов не отвечает."
    read -e -i "192.168.1.3" -p "Введите текущий IP HAOS: " CURRENT_IP
fi

if ! [[ "$CURRENT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "[-] Некорректный IP: $CURRENT_IP"; exit 1
fi

IFS=. read -r O1 O2 O3 O4 <<< "$CURRENT_IP"
for OCTET in "$O1" "$O2" "$O3" "$O4"; do
    (( 10#$OCTET > 255 )) && { echo "[-] Некорректный IP: $CURRENT_IP"; exit 1; }
done

SUBNET="${O1}.${O2}.${O3}"
DEFAULT_IP="${SUBNET}.3"
GATEWAY=$(ip route show default | awk 'NR==1{print $3; exit}')
[ -z "$GATEWAY" ] || [[ "$GATEWAY" != "${SUBNET}."* ]] && GATEWAY="${SUBNET}.1"

echo
echo "----------------------------------------------------"
echo "Текущая конфигурация:"
echo "  VMID    : $VMID"
echo "  Bridge  : $BRIDGE"
echo "  MAC     : $MAC"
echo "  IP      : $CURRENT_IP"
echo "  Подсеть : ${SUBNET}.0/24"
echo "  Gateway : $GATEWAY"
echo "----------------------------------------------------"
echo

read -e -i "$DEFAULT_IP" -p "Новый IP Home Assistant: " NEW_IP
NEW_IP=${NEW_IP:-$DEFAULT_IP}
NEW_IP="${NEW_IP%/24}"

if ! [[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "[-] Некорректный новый IP: $NEW_IP"; exit 1
fi

IFS=. read -r N1 N2 N3 N4 <<< "$NEW_IP"
for OCTET in "$N1" "$N2" "$N3" "$N4"; do
    (( 10#$OCTET > 255 )) && { echo "[-] Некорректный IP: $NEW_IP"; exit 1; }
done

NEW_SUBNET="${N1}.${N2}.${N3}"
if [ "$NEW_SUBNET" != "$SUBNET" ]; then
    echo "[-] Новый IP в другой подсети. Разрешено: ${SUBNET}.0/24"; exit 1
fi

(( 10#$N4 == 0 || 10#$N4 == 255 )) && { echo "[-] Нельзя использовать адрес сети/broadcast."; exit 1; }

if [ "$NEW_IP" != "$CURRENT_IP" ]; then
    echo
    echo "[+] Проверяем $NEW_IP..."
    if ping -c 1 -W 1 "$NEW_IP" >/dev/null 2>&1; then
        echo "[!] Адрес отвечает на ping — возможен конфликт."
        read -e -i "N" -p "Продолжить? [y/N]: " FORCE
        [[ ! "$FORCE" =~ ^[YyДд]$ ]] && { echo "Отмена."; exit 1; }
    else
        echo "[+] Ответа на ping нет."
    fi
fi

echo
echo "===================================================="
echo "  Старый IP : $CURRENT_IP"
echo "  Новый IP  : $NEW_IP/24"
echo "  Gateway   : $GATEWAY"
echo "  DNS       : $GATEWAY"
echo "===================================================="
read -e -i "Y" -p "Применить смену IP? [Y/n]: " CONFIRM
[[ "$CONFIRM" =~ ^[NnНн]$ ]] && { echo "Отмена."; exit 0; }

# ============================================================
# БЛОК 2 — обратный прокси
# ============================================================
echo
echo "===================================================="
echo "   Обратный прокси (X-Forwarded-For)"
echo "===================================================="
read -e -i "Y" -p "Настроить обратный прокси сейчас? [Y/n]: " SET_PROXY

PROXIES=""
if [[ ! "$SET_PROXY" =~ ^[NnНн]$ ]]; then
    read -e -i "0.0.0.0/0" -p "Trusted proxies: " PROXIES
    PROXIES=${PROXIES:-0.0.0.0/0}
    PROXIES="${PROXIES//,/ }"
    echo
    echo "  use_x_forwarded_for : true"
    echo "  trusted_proxies     : $PROXIES"
    echo
fi

# ---- Скрипт смены IP ----
NET_SCRIPT=$(cat <<NETEOF
#!/bin/sh
NEW_IP="$NEW_IP/24"
GATEWAY="$GATEWAY"
IFACE=\$(ha network info 2>/dev/null | awk '/^- interface:/ {print \$3; exit}')
test -z "\$IFACE" && IFACE=\$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '\$2=="ethernet" && \$3=="connected" {print \$1; exit}')
test -z "\$IFACE" && IFACE=\$(ip -4 route show default 2>/dev/null | awk '/^default/ {print \$5; exit}')
if test -z "\$IFACE"; then
    echo IFACE_ERR
    exit 1
fi
echo "IFACE_OK=\$IFACE"
ha network update "\$IFACE" --ipv4-method static --ipv4-address "\$NEW_IP" --ipv4-gateway "\$GATEWAY" --ipv4-nameserver "\$GATEWAY" && echo NET_OK || echo NET_ERR
NETEOF
)
NET_B64=$(printf '%s' "$NET_SCRIPT" | base64 -w0)

# ---- Патчер .storage/http ----
PATCHER_B64=""
if [ -n "$PROXIES" ]; then
    PATCHER=$(cat <<'SHEOF'
#!/bin/sh
FILE="/mnt/data/supervisor/homeassistant/.storage/http"
PROXIES="__PROXIES__"
[ -f "$FILE" ] || { echo PATCH_ERR; exit 1; }
cp "$FILE" "$FILE.bak"
awk -v proxies="$PROXIES" '
BEGIN { skip_tp = 0; inserted = 0 }
{
    if (skip_tp) {
        if ($0 ~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) skip_tp = 0
        next
    }
    if ($0 ~ /"use_x_forwarded_for"[[:space:]]*:/) next
    if ($0 ~ /"trusted_proxies"[[:space:]]*:/) {
        if ($0 ~ /\[/ && $0 !~ /\][[:space:]]*,?[[:space:]]*$/) skip_tp = 1
        next
    }
    print
    if (!inserted && $0 ~ /"stable"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/) {
        print "      \"use_x_forwarded_for\": true,"
        print "      \"trusted_proxies\": ["
        n = split(proxies, arr, " ")
        for (i = 1; i <= n; i++) {
            sep = (i < n) ? "," : ""
            print "        \"" arr[i] "\"" sep
        }
        print "      ],"
        inserted = 1
    }
}
' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
echo PATCH_OK
SHEOF
)
    PATCHER="${PATCHER/__PROXIES__/$PROXIES}"
    PATCHER_B64=$(printf '%s' "$PATCHER" | base64 -w0)
fi

export HA_VMID="$VMID"
export HA_NET_B64="$NET_B64"
export HA_PATCH_B64="$PATCHER_B64"
export HA_HAS_PROXY="$([ -n "$PROXIES" ] && echo 1 || echo 0)"

echo
echo "[+] Подключение к serial-консоли..."

expect <<'EXPECT_SCRIPT'
set timeout 240
set vmid      $env(HA_VMID)
set net_b64   $env(HA_NET_B64)
set patch_b64 $env(HA_PATCH_B64)
set has_proxy $env(HA_HAS_PROXY)

match_max 5000000

# Ждём чистый prompt #
proc wait_prompt {} {
    expect {
        -re {#[[:space:]]*$} { return 1 }
        -re {ha\s*>\s*$}     { send "login\r"; exp_continue }
        -re {login:\s*$}     { send "root\r";  exp_continue }
        -re {Processing\.\.\.} { exp_continue }
        timeout              { return 0 }
        eof                  { return 0 }
    }
}

# Пишем base64 без эха, проверяем коротким маркером RESULT_OK/RESULT_FAIL
proc write_b64 {b64 tmpfile rawfile} {
    send -- "rm -f $tmpfile $rawfile\r"
    if {![wait_prompt]} { return 0 }

    send -- "stty -echo\r"
    if {![wait_prompt]} { send -- "stty echo\r"; return 0 }

    set chunks [list]
    set len [string length $b64]
    set pos 0
    while {$pos < $len} {
        set end [expr {$pos + 63}]
        if {$end >= $len} { set end [expr {$len - 1}] }
        lappend chunks [string range $b64 $pos $end]
        set pos [expr {$end + 1}]
    }

    set idx 0
    foreach c $chunks {
        incr idx
        set marker "M${idx}Z"
        send -- "printf '%s' '$c' >> $tmpfile; echo $marker\r"
        expect {
            -re $marker { }
            timeout     { send -- "stty echo\r"; return 0 }
            eof         { send -- "stty echo\r"; return 0 }
        }
    }

    # Декодирование — без эха, короткая команда
    send -- "base64 -d $tmpfile > $rawfile\r"
    if {![wait_prompt]} { send -- "stty echo\r"; return 0 }

    # Проверка длины файла — без эха, короткий маркер
    send -- "test -s $rawfile && echo RESULT_OK || echo RESULT_FAIL\r"
    set ok 0
    expect {
        -re {RESULT_OK}   { set ok 1 }
        -re {RESULT_FAIL} { set ok 0 }
        timeout           { set ok 0 }
    }

    send -- "stty echo\r"
    wait_prompt

    return $ok
}

spawn qm terminal $vmid
sleep 2
send "\r"
sleep 1

expect {
    -re {login:\s*$} { send "root\r";  sleep 3; exp_continue }
    -re {ha\s*>\s*$} { send "login\r"; sleep 3; exp_continue }
    -re {[#\$]\s*$}  { }
    timeout { puts "\n\[-\] Нет приглашения."; send "\x0f"; exit 1 }
    eof     { puts "\n\[-\] Serial закрылся."; exit 1 }
}
puts "\n\[+\] Shell активен."

# ---- БЛОК 1: смена IP ----
puts "\n\[+\] Готовлю net.sh..."
if {![write_b64 $net_b64 "/tmp/n.b64" "/tmp/net.sh"]} {
    puts "\n\[-\] net.sh не записался."
    send "\x0f"
    exit 1
}
puts "\n\[+\] net.sh готов."

puts "\n\[+\] Запускаю net.sh..."
send -- "sh /tmp/net.sh\r"

set ip_ok 0
expect {
    -re {IFACE_ERR} { puts "\n\[-\] Не нашёл интерфейс."; set ip_ok 0 }
    -re {NET_OK}    { puts "\n\[+\] IP изменён."; set ip_ok 1 }
    -re {NET_ERR}   { puts "\n\[-\] ha network update упал."; set ip_ok 0 }
    timeout         { puts "\n\[-\] Нет ответа от net.sh."; set ip_ok 0 }
}

if {$ip_ok == 0} {
    send "\x0f"
    exit 1
}

sleep 3

if {$has_proxy == 0} {
    puts "\n\[+\] Смена IP завершена. Прокси не запрашивали."
    send "\x0f"
    exit 0
}

# ---- БЛОК 2: обратный прокси ----
puts "\n\[+\] Останавливаю ha core..."
send -- "ha core stop\r"

expect {
    -re {Command completed successfully} { puts "\n\[+\] ha core остановлен." }
    -re {#[[:space:]]*$}                { puts "\n\[+\] prompt получен." }
    timeout                             { puts "\n\[-\] Нет ответа stop." }
}

# Ждём пока спиннеры улягутся
sleep 4
send -- "\r"
if {![wait_prompt]} {
    puts "\n\[-\] Prompt не подтвердился."
    send "\x0f"
    exit 1
}

puts "\n\[+\] Готовлю patch.sh..."
if {![write_b64 $patch_b64 "/tmp/p.b64" "/tmp/patch.sh"]} {
    puts "\n\[-\] patch.sh не записался."
    send "\x0f"
    exit 1
}
puts "\n\[+\] patch.sh готов."

puts "\n\[+\] Запускаю patch.sh..."
send -- "sh /tmp/patch.sh\r"
set result 1
expect {
    -re {PATCH_OK}  { puts "\n\[+\] .storage/http пропатчен."; set result 0 }
    -re {PATCH_ERR} { puts "\n\[-\] Ошибка патча."; set result 1 }
    timeout         { puts "\n\[-\] Нет ответа."; set result 1 }
}

if {$result == 0} {
    send -- "grep -E 'use_x_forwarded_for|trusted_proxies' /mnt/data/supervisor/homeassistant/.storage/http\r"
    sleep 2
    puts "\n\[+\] Запускаю ha core..."
    send -- "ha core start\r"
    sleep 10
}

send "\x0f"
sleep 1
exit $result
EXPECT_SCRIPT

STATUS=$?

echo
echo "===================================================="
if [ "$STATUS" -eq 0 ]; then
    echo "[+] Готово."
    echo "  Новый IP            : $NEW_IP"
    echo "  Gateway             : $GATEWAY"
    if [ -n "$PROXIES" ]; then
        echo "  use_x_forwarded_for : true"
        echo "  trusted_proxies     : $PROXIES"
    fi
    echo
    echo "HA перезапускается (~1–2 мин)."
    echo "Проверка: ping -c 4 $NEW_IP"
else
    echo "[-] Не удалось подтвердить успешное выполнение."
    exit "$STATUS"
fi
echo "===================================================="
