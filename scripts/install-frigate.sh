#!/usr/bin/env bash
set -uo pipefail
export LVM_SUPPRESS_FD_WARNINGS=1

# === 1. ПРОВЕРКА И УСТАНОВКА ЗАВИСИМОСТЕЙ ===
check_and_install() {
    local to_install=()

    command -v lvcreate >/dev/null 2>&1 || to_install+=("lvm2")
    command -v blkid >/dev/null 2>&1    || to_install+=("util-linux")
    command -v ffprobe >/dev/null 2>&1  || to_install+=("ffmpeg")
    command -v nmap >/dev/null 2>&1     || to_install+=("nmap")
    command -v docker >/dev/null 2>&1   || to_install+=("docker.io")
    command -v wget >/dev/null 2>&1     || to_install+=("wget")
    command -v lspci >/dev/null 2>&1    || to_install+=("pciutils")
    command -v nc >/dev/null 2>&1       || to_install+=("netcat-openbsd")
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

# === 2. ОПРЕДЕЛЕНИЕ МОДЕЛИ GPU ===
detect_amd_gpu() {
    local gpu_info
    gpu_info=$(lspci -nn 2>/dev/null | grep -E 'VGA|3D|Display' | grep -i 'AMD' || true)

    if echo "$gpu_info" | grep -qi 'Phoenix'; then
        echo "phoenix"
    elif echo "$gpu_info" | grep -qi 'Renoir'; then
        echo "renoir"
    elif echo "$gpu_info" | grep -qiE 'Cezanne|Barcelo|Lucienne'; then
        echo "cezanne"
    elif echo "$gpu_info" | grep -qiE 'Raphael|Granite Ridge'; then
        echo "raphael"
    elif echo "$gpu_info" | grep -qiE 'Rembrandt'; then
        echo "rembrandt"
    else
        echo "unknown"
    fi
}

# === 3. ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ (AMD ROCm / Intel OpenVINO) ===
CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')
echo "ℹ️ Обнаружен процессор с вендором: $CPU_VENDOR"

FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:stable"
COMPOSE_DEVICES=""
DETECTORS_BLOCK=""
MODEL_BLOCK=""
EXTRA_ENV=""
AMD_GPU_MODEL=""
AMD_MODEL_FILE=""

if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    AMD_GPU_MODEL=$(detect_amd_gpu)
    echo "ℹ️ Обнаружена AMD GPU: $AMD_GPU_MODEL"

    # Общие настройки для всех AMD ROCm
    COMPOSE_DEVICES="    devices:
      - /dev/dri:/dev/dri
      - /dev/kfd:/dev/kfd"

    AMD_MODEL_CACHE="$CONFIG_DIR/model_cache/yolov8"

    case "$AMD_GPU_MODEL" in
        phoenix)
            # Phoenix1 — RDNA3, gfx1103
            echo "✔ Phoenix1 (RDNA3). Настраиваем ROCm + ONNX..."
            FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:stable-rocm"

            DETECTORS_BLOCK="detectors:
  onnx:
    type: onnx
    device: ROCM"

            EXTRA_ENV="      DOWNLOAD_YOLOV8: \"1\"
      HSA_OVERRIDE_GFX_VERSION: \"11.0.0\"
      LIBVA_DRIVER_NAME: \"radeonsi\""

            AMD_MODEL_FILE="yolov8s_320x320.onnx"
            ;;

        renoir|cezanne|lucienne)
            # Renoir / Cezanne / Lucienne — Vega, gfx90c
            echo "✔ Renoir/Cezanne (Vega 6/7/8). Настраиваем ROCm + MIGraphX..."
            FRIGATE_IMAGE="ghcr.io/garymathews/frigate:latest-rocm-7.2.0"

            DETECTORS_BLOCK="detectors:
  rocm:
    type: migraphx
    device: GPU
    conserve_cpu: true
    fast_math: true
    exhaustive_tune: false"

            EXTRA_ENV="      LIBVA_DRIVER_NAME: \"radeonsi\"
      HSA_OVERRIDE_GFX_VERSION: \"9.0.0\"
      HSA_ENABLE_SDMA: \"0\"
      MIGRAPHX_DISABLE_MIOPEN_FUSION: \"1\""

            AMD_MODEL_FILE="yolov8n_320x320.onnx"
            ;;

        rembrandt)
            # Rembrandt — RDNA2, gfx1035
            echo "✔ Rembrandt (RDNA2). Настраиваем ROCm + ONNX..."
            FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:stable-rocm"

            DETECTORS_BLOCK="detectors:
  onnx:
    type: onnx
    device: ROCM"

            EXTRA_ENV="      DOWNLOAD_YOLOV8: \"1\"
      HSA_OVERRIDE_GFX_VERSION: \"10.3.0\"
      LIBVA_DRIVER_NAME: \"radeonsi\""

            AMD_MODEL_FILE="yolov8s_320x320.onnx"
            ;;

        raphael)
            # Raphael — RDNA2, gfx1036
            echo "✔ Raphael (RDNA2). Настраиваем ROCm + ONNX..."
            FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:stable-rocm"

            DETECTORS_BLOCK="detectors:
  onnx:
    type: onnx
    device: ROCM"

            EXTRA_ENV="      DOWNLOAD_YOLOV8: \"1\"
      HSA_OVERRIDE_GFX_VERSION: \"10.3.0\"
      LIBVA_DRIVER_NAME: \"radeonsi\""

            AMD_MODEL_FILE="yolov8s_320x320.onnx"
            ;;

        *)
            # Неизвестная AMD GPU — используем безопасный профиль Renoir (Vega)
            echo "⚠️ Неизвестная AMD GPU. Используем конфигурацию по умолчанию (ROCm + MIGraphX, gfx9)..."
            FRIGATE_IMAGE="ghcr.io/garymathews/frigate:latest-rocm-7.2.0"

            DETECTORS_BLOCK="detectors:
  rocm:
    type: migraphx
    device: GPU
    conserve_cpu: true
    fast_math: true
    exhaustive_tune: false"

            EXTRA_ENV="      LIBVA_DRIVER_NAME: \"radeonsi\"
      HSA_OVERRIDE_GFX_VERSION: \"9.0.0\"
      HSA_ENABLE_SDMA: \"0\"
      MIGRAPHX_DISABLE_MIOPEN_FUSION: \"1\""

            AMD_MODEL_FILE="yolov8n_320x320.onnx"
            ;;
    esac

    # Модель для config.yaml
    MODEL_BLOCK="model:
  path: /config/model_cache/yolov8/${AMD_MODEL_FILE}
  labelmap_path: /config/model_cache/yolov8/labels.txt
  model_type: yolo-generic
  width: 320
  height: 320
  input_tensor: nchw
  input_pixel_format: bgr
  input_dtype: float"

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

# === 4. НАСТРОЙКА ПЕРЕМЕННЫХ ХРАНИЛИЩА ===
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

# === 5. LVM + ФАЙЛОВАЯ СИСТЕМА + МОНТИРОВАНИЕ ===
echo "=== Настройка хранилища LVM ==="

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

if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNTPOINT ext4 defaults,nofail 0 2" >> /etc/fstab
  echo "✔ Добавлена запись в /etc/fstab"
else
  echo "✔ Запись для хранилища уже присутствует в /etc/fstab"
fi

if ! mountpoint -q "$MOUNTPOINT"; then
  mount "$MOUNTPOINT" || true
fi

echo "✔ Storage ready:"
findmnt "$MOUNTPOINT" || true
df -h "$MOUNTPOINT" || true

# === 6. СКАНИРОВАНИЕ СЕТИ И ГЕНЕРАЦИЯ КОНФИГА ===
mkdir -p "$CONFIG_DIR"

# Скачивание модели YOLOv8 для AMD
if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    AMD_MODEL_CACHE="$CONFIG_DIR/model_cache/yolov8"
    mkdir -p "$AMD_MODEL_CACHE"
    MODEL_PATH="$AMD_MODEL_CACHE/${AMD_MODEL_FILE}"

    if [ ! -f "$MODEL_PATH" ]; then
        echo "⬇ Скачиваю архив с моделями YOLOv8 для ROCm (harakas/models)..."
        TMP_TAR=$(mktemp /tmp/yolov8_models.XXXXXX.tar.gz)
        if ! wget -q --show-progress -O "$TMP_TAR" \
            "https://github.com/harakas/models/releases/download/yolov8.1-1.1/yolov8.small.models.tar.gz"; then
            echo "⚠️ Не удалось скачать архив вручную."
            rm -f "$TMP_TAR"
        else
            echo "📦 Распаковываю архив..."
            tar -xzf "$TMP_TAR" -C "$AMD_MODEL_CACHE"
            rm -f "$TMP_TAR"

            # Если распакованные имена отличаются — переименуем под ожидаемое
            if [ ! -f "$MODEL_PATH" ]; then
                shopt -s nullglob
                for f in "$AMD_MODEL_CACHE"/*.onnx; do
                    base=$(basename "$f")
                    # Приводим типовые имена к нужному
                    if [[ "$AMD_MODEL_FILE" == "yolov8n_320x320.onnx" && "$base" == *yolov8n*320*.onnx ]]; then
                        mv "$f" "$MODEL_PATH"
                        break
                    fi
                    if [[ "$AMD_MODEL_FILE" == "yolov8s_320x320.onnx" && "$base" == *yolov8s*320*.onnx ]]; then
                        mv "$f" "$MODEL_PATH"
                        break
                    fi
                done
                shopt -u nullglob
            fi
        fi
    else
        echo "✔ Модель уже существует: $MODEL_PATH"
    fi
fi

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

    local ONVIF_FOUND_PORT=""
    for p in 80 8000 8899; do
        if probe_onvif "$ip" "$p"; then
            ONVIF_FOUND_PORT="$p"
            break
        fi
    done

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

camera_index=1

if [ ${#discovered_ips[@]} -gt 0 ]; then
    echo "=== Настройка найденных камер ==="
    for ip in "${discovered_ips[@]}"; do
        configure_camera_by_ip "$ip"
    done
else
    read -rp "Количество камер: " CAMERA_COUNT
    if ! [[ "$CAMERA_COUNT" =~ ^[0-9]+$ ]] || [ "$CAMERA_COUNT" -le 0 ]; then
      echo "❌ Нужно минимум 1 камера"
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

mkdir -p "$BASE"; cd "$BASE"
cat > docker-compose.yml <<EOF
services:
  frigate:
    container_name: frigate
    image: $FRIGATE_IMAGE
    restart: unless-stopped
    privileged: true
    shm_size: "512mb"
    ulimits:
      core:
        soft: 0
        hard: 0
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
