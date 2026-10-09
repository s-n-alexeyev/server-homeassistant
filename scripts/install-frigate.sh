#!/usr/bin/env bash
set -uo pipefail

# === 1. ПРОВЕРКА И УСТАНОВКА ЗАВИСИМОСТЕЙ ===
check_and_install() {
    local to_install=()

    command -v lvcreate >/dev/null 2>&1 || to_install+=("lvm2")
    command -v blkid >/dev/null 2>&1    || to_install+=("util-linux")
    command -v ffprobe >/dev/null 2>&1  || to_install+=("ffmpeg")
    command -v nmap >/dev/null 2>&1     || to_install+=("nmap")
    command -v docker >/dev/null 2>&1   || to_install+=("docker.io")
    command -v wget >/dev/null 2>&1     || to_install+=("wget")
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        to_install+=("docker-compose-v2")
    fi

    if [ ${#to_install[@]} -gt 0 ]; then
        echo "❌ Не хватает пакетов: ${to_install[*]}"
        read -rp "Установить их через apt? [Y/n]: " choice
        choice="${choice:-Y}"
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            apt update
            apt install -y "${to_install[@]}"
        else
            echo "Установка отменена."
            exit 1
        fi
    else
        echo "✔ Все необходимые пакеты уже установлены."
    fi
}
check_and_install

# === 2. ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ (AMD ROCm / Intel OpenVINO) ===
CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')
echo "ℹ️ Обнаружен процессор с вендором: $CPU_VENDOR"

FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:stable"
COMPOSE_DEVICES=""
DETECTORS_BLOCK=""
MODEL_BLOCK=""
EXTRA_ENV=""

if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    echo "✔ Обнаружена платформа AMD. Настраиваем ROCm + ONNX..."
    FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:stable-rocm"

    COMPOSE_DEVICES="    devices:
      - /dev/dri:/dev/dri
      - /dev/kfd:/dev/kfd"

    # Frigate 0.18: ROCm работает внутри ONNX-детектора через device: ROCM
    DETECTORS_BLOCK="detectors:
  onnx:
    type: onnx
    device: ROCM"

    MODEL_BLOCK="model:
  path: /config/model_cache/yolov8/yolov8s_320x320.onnx
  labelmap_path: /config/model_cache/yolov8/labels.txt
  model_type: yolo-generic
  width: 320
  height: 320
  input_tensor: nchw
  input_pixel_format: bgr
  input_dtype: float"

    # HSA_OVERRIDE_GFX_VERSION: 11.0.0 — RDNA2 (RX 6000, iGPU Ryzen 6000)
    # RDNA3 (RX 7000, iGPU Ryzen 7000/8000) → 11.0.2
    # RDNA1 (RX 5000) → 10.1.0
    # Vega (iGPU Ryzen 2000/3000, RX Vega) → 9.0.0
    EXTRA_ENV="      DOWNLOAD_YOLOV8: \"1\"
      HSA_OVERRIDE_GFX_VERSION: \"11.0.0\"
      LIBVA_DRIVER_NAME: \"radeonsi\""
else
    echo "✔ Обнаружена платформа Intel (или совместимая). Настраиваем OpenVINO GPU..."
    FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:stable"
    COMPOSE_DEVICES="    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128"
    DETECTORS_BLOCK="detectors:
  ov:
    type: openvino
    device: GPU"
    MODEL_BLOCK="model:
  width: 300
  height: 300
  input_tensor: nhwc
  input_pixel_format: bgr
  path: /openvino-model/ssdlite_mobilenet_v2.xml
  labelmap_path: /openvino-model/coco_91cl_bkgr.txt"
fi

# === 3. НАСТРОЙКА ПЕРЕМЕННЫХ ХРАНИЛИЩА ===
LV_NAME="frigate-storage"
VG_NAME="pve"
THIN_POOL="data"
BASE="/opt/frigate"
CONFIG_DIR="$BASE/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
MOUNTPOINT="$BASE/storage"
LV_PATH="/dev/$VG_NAME/$LV_NAME"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ missing dependency: $1"
    exit 1
  }
}

echo "=== Проверка зависимостей ==="
for c in lvcreate lvdisplay blkid mkfs.ext4 mount findmnt docker ffprobe nmap wget; do
  need_cmd "$c"
done

# === 4. LVM + ФАЙЛОВАЯ СИСТЕМА + МОНТИРОВАНИЕ (КОНТРОЛЬ ПОЛЬЗОВАТЕЛЯ) ===
echo "=== Настройка хранилища LVM ==="

# Проверка на наличие старых/лишних томов с запросом подтверждения
for old_lv in $(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep -E "frigate-storage" | grep -v "$LV_NAME"); do
  echo "⚠️ Обнаружен старый/лишний том LVM: $old_lv"
  read -rp "Удалить этот старый том? [y/N]: " remove_old_choice
  if [[ "$remove_old_choice" =~ ^[Yy]$ ]]; then
    umount -lf "$MOUNTPOINT" 2>/dev/null || true
    lvremove -f "$VG_NAME/$old_lv"
    echo "✔ Том $old_lv удален."
  else
    echo "ℹ️ Пропускаем удаление тома $old_lv."
  fi
done

if lvdisplay "$LV_PATH" >/dev/null 2>&1; then
  echo "✔ Том $LV_NAME уже существует."
  lvdisplay "$LV_PATH" | grep -E "LV Size"

  read -rp "Хотите изменить размер существующего тома? [y/N]: " resize_choice
  resize_choice="${resize_choice:-N}"
  if [[ "$resize_choice" =~ ^[Yy]$ ]]; then
    read -rp "Введите новый размер тома (например, 150G, +50G): " NEW_SIZE
    if [ -n "$NEW_SIZE" ]; then
      echo "Изменяю размер LV до $NEW_SIZE..."
      lvextend -L "$NEW_SIZE" -r "$LV_PATH" || lvreduce -L "$NEW_SIZE" -r "$LV_PATH"
    fi
  fi
else
  read -rp "Введите объем создаваемого тома (по умолчанию 100G): " INPUT_SIZE
  SIZE="${INPUT_SIZE:-100G}"
  echo "Используемый размер тома: $SIZE"

  echo "Создаю LV $LV_NAME..."
  lvcreate -V "$SIZE" -T "$VG_NAME/$THIN_POOL" -n "$LV_NAME"
fi

if ! blkid "$LV_PATH" >/dev/null 2>&1; then
  echo "Создаю ext4..."
  mkfs.ext4 "$LV_PATH"
fi

mkdir -p "$MOUNTPOINT"
UUID=$(blkid -s UUID -o value "$LV_PATH")

# Контроль дубликатов в fstab с вопросом
if grep -q "$MOUNTPOINT" /etc/fstab && ! grep -q "$UUID" /etc/fstab; then
  echo "⚠️ В /etc/fstab обнаружена запись для $MOUNTPOINT с другим UUID."
  cat /etc/fstab | grep "$MOUNTPOINT"
  read -rp "Очистить старые записи fstab для этой точки монтирования? [Y/n]: " fix_fstab
  fix_fstab="${fix_fstab:-Y}"
  if [[ "$fix_fstab" =~ ^[Yy]$ ]]; then
    grep -v "$MOUNTPOINT" /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
    echo "UUID=$UUID $MOUNTPOINT ext4 defaults,nofail 0 2" >> /etc/fstab
    echo "✔ Запись в fstab обновлена."
  fi
elif ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNTPOINT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

if ! mountpoint -q "$MOUNTPOINT"; then
  mount "$MOUNTPOINT" || true
fi

echo "✔ Storage ready:"
findmnt "$MOUNTPOINT" || true
df -h "$MOUNTPOINT" || true

# === 5. СКАНИРОВАНИЕ СЕТИ И ГЕНЕРАЦИЯ КОНФИГА ===
mkdir -p "$CONFIG_DIR"

# --- Предзагрузка модели YOLOv8 для AMD ROCm (проверенный источник) ---
if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    AMD_MODEL_CACHE="$CONFIG_DIR/model_cache/yolov8"
    mkdir -p "$AMD_MODEL_CACHE"
    MODEL_PATH="$AMD_MODEL_CACHE/yolov8s_320x320.onnx"

    if [ ! -f "$MODEL_PATH" ]; then
        echo "⬇ Скачиваю архив с моделями YOLOv8 для ROCm (harakas/models)...[cite: 1]"
        TMP_TAR=$(mktemp /tmp/yolov8_models.XXXXXX.tar.gz)
        if ! wget -q --show-progress -O "$TMP_TAR" \
            "https://github.com/harakas/models/releases/download/yolov8.1-1.1/yolov8.small.models.tar.gz"; then
            echo "⚠️ Не удалось скачать архив вручную[cite: 1]."
            echo "   Frigate попробует скачать модель сам при старте (DOWNLOAD_YOLOV8=1)[cite: 1]."
            rm -f "$TMP_TAR"
        else
            echo "📦 Распаковываю архив...[cite: 1]"
            tar -xzf "$TMP_TAR" -C "$AMD_MODEL_CACHE"
            rm -f "$TMP_TAR"

            if [ -f "$MODEL_PATH" ]; then
                echo "✔ Модель готова: $MODEL_PATH[cite: 1]"
                ls -lh "$AMD_MODEL_CACHE"/labels*.txt 2>/dev/null || true
            else
                echo "⚠️ Файл yolov8s_320x320.onnx не найден после распаковки[cite: 1]."
                echo "   Frigate попробует скачать модель сам при старте[cite: 1]."
            fi
        fi
    else
        echo "✔ Модель уже существует: $MODEL_PATH[cite: 1]"
    fi
fi

# --- Вспомогательные функции ---
scan_subnet() {
    local subnet="$1"
    nmap -p 554 --open -oG - "$subnet" 2>/dev/null | grep "554/open" | awk '{print $2}'
}

scan_network() {
    local subnet
    subnet=$(ip -4 route show | grep default | awk '{print $3}' | cut -d. -f1-3).0/24
    scan_subnet "$subnet"
}

probe_rtsp() {
  command -v ffprobe >/dev/null 2>&1 || return 0
  timeout 3 ffprobe -v error -rtsp_transport tcp -i "$1" >/dev/null 2>&1
}

probe_onvif() {
  local ip="$1"
  local port="$2"
  nc -z -w 2 "$ip" "$port" >/dev/null 2>&1
}

build_rtsp_list() {
  local user="$1"; local pass="$2"; local ip="$3"
  if [ -z "$user" ]; then
    cat <<EOF
rtsp://${ip}:554/ch0
rtsp://${ip}:554/ch1
rtsp://${ip}:554/live
rtsp://${ip}:554/stream1
rtsp://${ip}:554/video0
rtsp://${ip}:554/Streaming/Channels/101
rtsp://${ip}:554/Streaming/Channels/102
rtsp://${ip}:554/cam/realmonitor?channel=1&subtype=0
rtsp://${ip}:554/cam/realmonitor?channel=1&subtype=1
EOF
  else
    cat <<EOF
rtsp://${user}:${pass}@${ip}:554/ch0
rtsp://${user}:${pass}@${ip}:554/ch1
rtsp://${user}:${pass}@${ip}:554/live
rtsp://${user}:${pass}@${ip}:554/stream1
rtsp://${user}:${pass}@${ip}:554/video0
rtsp://${user}:${pass}@${ip}:554/Streaming/Channels/101
rtsp://${user}:${pass}@${ip}:554/Streaming/Channels/102
rtsp://${user}:${pass}@${ip}:554/cam/realmonitor?channel=1&subtype=0
rtsp://${user}:${pass}@${ip}:554/cam/realmonitor?channel=1&subtype=1
EOF
  fi
}

# --- Обработка одной камеры по IP (используется во всех режимах) ---
configure_camera_by_ip() {
    local ip="$1"

    echo
    echo "--- Настройка камеры: $ip ---"
    read -rp "Добавить эту камеру? [Y/n/skip]: " add_choice
    add_choice="${add_choice:-Y}"
    if [[ "$add_choice" =~ ^[Ss]$ ]] || [[ "$add_choice" =~ ^[Nn]$ ]]; then
        return 0
    fi

    local default_name="Camera${camera_index}"
    local CAM_NAME
    read -rp "Имя камеры [$default_name]: " CAM_NAME
    CAM_NAME="${CAM_NAME:-$default_name}"

    local CAM_USER CAM_PASS
    read -rp "Логин (пусто, если нет): " CAM_USER
    read -rsp "Пароль: " CAM_PASS
    echo

    # ONVIF-порты
    local ONVIF_FOUND_PORT=""
    for p in 80 8000 8899; do
        if probe_onvif "$ip" "$p"; then
            ONVIF_FOUND_PORT="$p"
            break
        fi
    done

    # Поиск рабочего RTSP
    local RTSP_FOUND=""
    for cred_pair in "${CAM_USER}:${CAM_PASS}" " : " "admin:admin" "root:root"; do
        local u p
        IFS=':' read -r u p <<< "$cred_pair"
        while read -r RTSP; do
            if probe_rtsp "$RTSP"; then
                RTSP_FOUND="$RTSP"
                break 2
            fi
        done < <(build_rtsp_list "$u" "$p" "$ip")
    done
    [ -z "$RTSP_FOUND" ] && RTSP_FOUND="rtsp://${CAM_USER:+$CAM_USER${CAM_PASS:+:$CAM_PASS}@}${ip}:554/ch0"

    # Выбор протокола
    local PROTOCOL_CHOICE="rtsp"
    if [ -n "$ONVIF_FOUND_PORT" ] && [ -n "$RTSP_FOUND" ]; then
        local proto_input
        read -rp "Протокол для $ip [ONVIF/rtsp]: " proto_input
        PROTOCOL_CHOICE="${proto_input:-onvif}"
    elif [ -n "$ONVIF_FOUND_PORT" ]; then
        PROTOCOL_CHOICE="onvif"
    fi

    if [[ "$PROTOCOL_CHOICE" =~ ^[Oo][Nn][Vv][Ii][Ff]$ ]]; then
        cat >> "$CONFIG_FILE" <<EOF
  $CAM_NAME:
    enabled: true
    ffmpeg:
      inputs:
        - path: $RTSP_FOUND
          roles: [detect, record]
    onvif:
      host: $ip
      port: $ONVIF_FOUND_PORT
      user: "$CAM_USER"
      password: "$CAM_PASS"
      autotracking:
        enabled: false
    detect:
      enabled: true
      width: 1280
      height: 720
    objects:
      track: [person, car]
    record:
      enabled: true
    zones: {}
    motion:
      mask: 0,0.037,0.242,0.038,0.242,0,0,0
EOF
    else
        cat >> "$CONFIG_FILE" <<EOF
  $CAM_NAME:
    enabled: true
    ffmpeg:
      inputs:
        - path: $RTSP_FOUND
          roles: [detect, record]
    detect:
      enabled: true
      width: 1280
      height: 720
    objects:
      track: [person, car]
    record:
      enabled: true
    zones: {}
    motion:
      mask: 0,0.037,0.242,0.038,0.242,0,0,0
EOF
    fi

    camera_index=$((camera_index+1))
}

# --- Шапка конфига ---
cat > "$CONFIG_FILE" <<EOF
mqtt:
  enabled: false
${DETECTORS_BLOCK}
ffmpeg:
  hwaccel_args: preset-vaapi
  output_args:
    record: preset-record-generic-audio-aac
${MODEL_BLOCK}
record:
  enabled: true
  continuous:
    days: 0
  motion:
    days: 30
cameras:
EOF

# --- Первичное сканирование сети ---
discovered_ips=()
if command -v nmap >/dev/null 2>&1; then
    read -rp "Запустить сканирование сети для поиска камер? [Y/n]: " scan_choice
    scan_choice="${scan_choice:-Y}"
    if [[ "$scan_choice" =~ ^[Yy]$ ]]; then
        echo "=== Сканирование сети ==="
        mapfile -t discovered_ips < <(scan_network)
        if [ ${#discovered_ips[@]} -gt 0 ]; then
            echo "✔ Найдены IP с открытым портом 554: ${discovered_ips[*]}"
        else
            echo "⚠️ Устройств с открытым портом 554 не найдено."
        fi
    fi
fi

# --- Обработка камер ---
camera_index=1

if [ ${#discovered_ips[@]} -gt 0 ]; then
    echo "=== Настройка найденных камер ==="
    for ip in "${discovered_ips[@]}"; do
        configure_camera_by_ip "$ip"
    done
else
    read -rp "Количество камер: " CAMERA_COUNT
    if ! [[ "$CAMERA_COUNT" =~ ^[0-9]+$ ]] || [ "$CAMERA_COUNT" -le 0 ]; then
      echo "Нужно минимум 1 камера"
      exit 1
    fi

    i=1
    while [ "$i" -le "$CAMERA_COUNT" ]; do
      echo; echo "=== Камера $i ==="
      read -rp "IP: " CAM_IP
      if [ -z "$CAM_IP" ]; then
          echo "❌ пропуск (нет IP)"
          i=$((i+1))
          continue
      fi
      configure_camera_by_ip "$CAM_IP"
      i=$((i+1))
    done
fi

# --- Цикл поиска камер в дополнительных сетях ---
while true; do
    echo
    read -rp "Поискать камеры в другой сети? [y/N]: " more_networks
    more_networks="${more_networks:-N}"
    [[ "$more_networks" =~ ^[Yy]$ ]] || break

    read -rp "Введите подсеть (например, 192.168.20.0/24): " user_subnet
    if [ -z "$user_subnet" ]; then
        echo "⚠️ Подсеть не указана, пропускаю."
        continue
    fi

    echo "=== Сканирование $user_subnet ==="
    more_ips=()
    mapfile -t more_ips < <(scan_subnet "$user_subnet")
    if [ ${#more_ips[@]} -eq 0 ]; then
        echo "⚠️ Устройств с открытым портом 554 не найдено в $user_subnet."
        continue
    fi

    echo "✔ Найдены IP: ${more_ips[*]}"
    for ip in "${more_ips[@]}"; do
        configure_camera_by_ip "$ip"
    done
done

echo "version: 0.18" >> "$CONFIG_FILE"
echo "✔ Config ready"

# === 6. СОЗДАНИЕ DOCKER COMPOSE И ЗАПУСК ===
mkdir -p "$BASE"; cd "$BASE"
cat > docker-compose.yml <<EOF
services:
  frigate:
    container_name: frigate
    image: $FRIGATE_IMAGE
    restart: unless-stopped
    privileged: true
    shm_size: "512mb"
${COMPOSE_DEVICES}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config:/config
      - ./storage:/media/frigate
    ports:
      - "8971:8971"
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
    environment:
      FRIGATE_RTSP_PASSWORD: "password"
${EXTRA_ENV}
EOF

echo "=== Запуск Docker Compose ==="
docker compose down || true
docker compose up -d
echo "✔ ГОТОВО! Используемый образ: $FRIGATE_IMAGE"
echo "UI: http://<server>:5000"
echo
echo "Проверьте логи:  docker logs -f frigate"
