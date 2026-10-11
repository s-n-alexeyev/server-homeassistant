#!/usr/bin/env bash

# ============================================================
# HAOS — интерактивное добавление репозиториев
# ============================================================

set -u

if [ "$EUID" -ne 0 ]; then
    echo "[-] Запускать от root."
    exit 1
fi

for cmd in qm ip awk grep cut expect base64 timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[-] Нет команды: $cmd"; exit 1; }
done

echo "===================================================="
echo "   Home Assistant — Интерактивное добавление репозиториев"
echo "===================================================="
echo

VMID="8123"
qm status "$VMID" >/dev/null 2>&1 || { echo "[-] ВМ $VMID не найдена."; exit 1; }
echo "[+] VMID: $VMID"

# Скрипт для проверки текущих репозиториев внутри HAOS
CHECK_SCRIPT=$(cat <<'CHECKEOF'
#!/bin/sh
ha store info 2>/dev/null | grep -A 20 "Repositories:" || true
CHECKEOF
)
CHECK_B64=$(printf '%s' "$CHECK_SCRIPT" | base64 -w0)

export HA_VMID="$VMID"
export HA_CHECK_B64="$CHECK_B64"

echo
echo "[+] Получаем текущий список репозиториев из HA..."

# Получаем текущие репозитории через expect
CURRENT_REPOS=$(expect <<'EXPECT_CHECK'
set timeout 60
set vmid     $env(HA_VMID)
set check_b64 $env(HA_CHECK_B64)

match_max 5000000

proc wait_prompt {} {
    expect {
        -re {#[[:space:]]*$} { return 1 }
        -re {ha\s*>\s*$}     { send "login\r"; exp_continue }
        -re {login:\s*$}     { send "root\r";  exp_continue }
        timeout              { return 0 }
        eof                  { return 0 }
    }
}

spawn qm terminal $vmid
sleep 2
send "\r"
sleep 1

expect {
    -re {login:\s*$} { send "root\r";  sleep 3; exp_continue }
    -re {ha\s*>\s*$} { send "login\r"; sleep 3; exp_continue }
    -re {[#\$]\s*$}  { }
    timeout { send "\x0f"; exit 1 }
    eof     { send "\x0f"; exit 1 }
}

send -- "rm -f /tmp/c.b64 /tmp/check.sh\r"
wait_prompt

set chunks [list]
set len [string length $check_b64]
set pos 0
while {$pos < $len} {
    set end [expr {$pos + 63}]
    if {$end >= $len} { set end [expr {$len - 1}] }
    lappend chunks [string range $check_b64 $pos $end]
    set pos [expr {$end + 1}]
}

foreach c $chunks {
    send -- "printf '%s' '$c' >> /tmp/c.b64\r"
    wait_prompt
}

send -- "base64 -d /tmp/c.b64 > /tmp/check.sh && sh /tmp/check.sh\r"
expect {
    -re {Repositories:([\s\S]*?)(ha\s*>|#|\n\n\n)} {
        puts "$expect_out(1,string)"
    }
    timeout { }
}

send "\x0f"
sleep 1
EXPECT_CHECK
)

echo
echo "----------------------------------------------------"
echo "Уже установленные репозитории:"
echo "$CURRENT_REPOS"
echo "----------------------------------------------------"
echo

# Список заготовленных репозиториев для выбора
PRESET_REPOS=(
    "https://github.com/hacs/addons|HACS Addons"
    "https://github.com/zigbee2mqtt/hassio-zigbee2mqtt|Zigbee2MQTT"
    "https://github.com/vineetchoudhary/home-assistant-beszel-agent|Beszel Agent"
)

SELECTED_REPOS=()

echo "Выберите репозитории для добавления:"
for item in "${PRESET_REPOS[@]}"; do
    url="${item%%|*}"
    name="${item##*|}"
    
    # Проверяем, есть ли уже этот репозиторий в выводе
    if echo "$CURRENT_REPOS" | grep -q "$url"; then
        echo "  [i] $name ($url) — УЖЕ УСТАНОВЛЕН"
        continue
    fi

    read -e -i "Y" -p "  Добавить $name? [Y/n]: " choice
    if [[ ! "$choice" =~ ^[NnНн]$ ]]; then
        SELECTED_REPOS+=("$url")
    fi
done

echo
read -e -p "Хотите указать свой кастомный репозиторий (URL)? [y/N]: " add_custom
if [[ "$add_custom" =~ ^[YyДд]$ ]]; then
    while true; do
        read -e -p "Введите URL репозитория (или оставьте пустым для завершения): " custom_url
        [ -z "$custom_url" ] && break
        SELECTED_REPOS+=("$custom_url")
        echo "[+] Добавлен в очередь: $custom_url"
    done
fi

if [ ${#SELECTED_REPOS[@]} -eq 0 ]; then
    echo "[-] Не выбрано ни одного нового репозитория для добавления."
    exit 0
fi

echo
echo "[+] Будут добавлены следующие репозитории:"
for r in "${SELECTED_REPOS[@]}"; do
    echo "    - $r"
done
echo
read -e -i "Y" -p "Применить изменения? [Y/n]: " confirm
[[ "$confirm" =~ ^[NnНн]$ ]] && { echo "Отмена."; exit 0; }

# Генерируем команды для добавления выбранных репозиториев
INSTALL_COMMANDS=""
for r in "${SELECTED_REPOS[@]}"; do
    INSTALL_COMMANDS="${INSTALL_COMMANDS}ha store add \"$r\" || true\n"
done

ADD_SCRIPT=$(cat <<ADDEOF
#!/bin/sh
echo "[*] Добавление выбранных репозиториев..."
$INSTALL_COMMANDS
ha store reload || true
echo REPO_OK
ADDEOF
)
ADD_B64=$(printf '%s' "$ADD_SCRIPT" | base64 -w0)

export HA_ADD_B64="$ADD_B64"

echo
echo "[+] Подключение к serial-консоли для установки..."

expect <<'EXPECT_INSTALL'
set timeout 120
set vmid     $env(HA_VMID)
set add_b64  $env(HA_ADD_B64)

match_max 5000000

proc wait_prompt {} {
    expect {
        -re {#[[:space:]]*$} { return 1 }
        -re {ha\s*>\s*$}     { send "login\r"; exp_continue }
        -re {login:\s*$}     { send "root\r";  exp_continue }
        timeout              { return 0 }
        eof                  { return 0 }
    }
}

spawn qm terminal $vmid
sleep 2
send "\r"
sleep 1

expect {
    -re {login:\s*$} { send "root\r";  sleep 3; exp_continue }
    -re {ha\s*>\s*$} { send "login\r"; sleep 3; exp_continue }
    -re {[#\$]\s*$}  { }
    timeout { send "\x0f"; exit 1 }
    eof     { send "\x0f"; exit 1 }
}

send -- "rm -f /tmp/a.b64 /tmp/add.sh\r"
wait_prompt

set chunks [list]
set len [string length $add_b64]
set pos 0
while {$pos < $len} {
    set end [expr {$pos + 63}]
    if {$end >= $len} { set end [expr {$len - 1}] }
    lappend chunks [string range $add_b64 $pos $end]
    set pos [expr {$end + 1}]
}

foreach c $chunks {
    send -- "printf '%s' '$c' >> /tmp/a.b64\r"
    wait_prompt
}

send -- "base64 -d /tmp/a.b64 > /tmp/add.sh && sh /tmp/add.sh\r"

set success 0
expect {
    -re {REPO_OK} { set success 1 }
    timeout       { set success 0 }
}

send "\x0f"
sleep 1
exit [expr {$success ? 0 : 1}]
EXPECT_INSTALL

STATUS=$?

echo
echo "===================================================="
if [ "$STATUS" -eq 0 ]; then
    echo "[+] Готово! Все выбранные репозитории успешно добавлены."
else
    echo "[-] Произошла ошибка при добавлении."
    exit "$STATUS"
fi
echo "===================================================="
