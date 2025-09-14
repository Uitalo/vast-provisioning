#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# Pacotes básicos
# ============================================================
apt-get update -y
apt-get install -y --no-install-recommends \
  curl unzip git ffmpeg ca-certificates python3 python3-pip
rm -rf /var/lib/apt/lists/*

# ============================================================
# Instala rclone (com fallback)
# ============================================================
if ! command -v rclone >/dev/null 2>&1; then
  if ! curl -fsSL https://rclone.org/install.sh | bash; then
    curl -fsSLO https://downloads.rclone.org/rclone-current-linux-amd64.zip
    unzip -o rclone-current-linux-amd64.zip
    cd rclone-*-linux-amd64
    install -m 0755 rclone /usr/bin/rclone
    cd -
  fi
fi

# ============================================================
# Configuração opcional do rclone.conf via variável base64
# ============================================================
if [ -n "${RCLONE_CONF_B64:-}" ]; then
  mkdir -p /root/.config/rclone
  printf "%s" "$RCLONE_CONF_B64" | base64 -d > /root/.config/rclone/rclone.conf
  chmod 600 /root/.config/rclone/rclone.conf
fi

# ============================================================
# Instala comfy-cli
# ============================================================
echo "Instalando comfy-cli e dependências Python…"
python3 -m pip install --upgrade pip
python3 -m pip install --upgrade comfy-cli

# comfy-cli costuma ficar em ~/.local/bin
export PATH="$PATH:/root/.local/bin"

# ============================================================
# Diretório padrão do Comfy
# ============================================================
echo "Configurando comfy-cli e instalando o ComfyUI..."
COMFY_PATH="/workspace/ComfyUI"
mkdir -p "$COMFY_PATH"
echo "O Comfy será instalado em: $COMFY_PATH"

# ============================================================
# Instalação via comfy-cli
# ============================================================

# Imagino que não irá pedir confirmações
# comfy --install-completion
# Instala o ComfyUI e dependências dentro de $COMFY_PATH
comfy --workspace=$COMFY_PATH  install --nvidia

comfy set-default "$COMFY_PATH" --yes
comfy install --yes --no-tracking




# Define o diretório padrão, depois de instalado?
#comfy set-default "$COMFY_PATH"
# ============================================================
# Inicializa em background
# ============================================================
# Altere --port se quiser outra porta (padrão 8080 abaixo)
comfy launch --background -- --listen 0.0.0.0 --port 8080



tg_send() {
  tg_can_notify || return 0
  local text="$1"
  local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
  curl -sS -X POST "$url" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${text}" \
    -d "parse_mode=${TELEGRAM_PARSE_MODE}" \
    -d "disable_web_page_preview=true" >/dev/null || true
}