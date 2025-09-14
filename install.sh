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
COMFY_PATH="/workspace/ComfyUI"
mkdir -p "$COMFY_PATH"
echo "O Comfy será instalado em: $COMFY_PATH"

# ============================================================
# Instalação via comfy-cli
# ============================================================
# Define o diretório padrão
comfy set-default "$COMFY_PATH"

# Instala o ComfyUI e dependências dentro de $COMFY_PATH
comfy install

# ============================================================
# Inicializa em background
# ============================================================
# Altere --port se quiser outra porta (padrão 8080 abaixo)
comfy launch --background -- --listen 0.0.0.0 --port 8080