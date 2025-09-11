#!/bin/bash

set -euo pipefail

# Irá instalar no venv?

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

  # Alias persistente e imediato
#echo "alias comfy='/venv/comfycli/bin/comfy'" >> /root/.bashrc
#alias comfy='/venv/comfycli/bin/comfy'
#export PATH="/venv/comfycli/bin:$PATH"

# Configurações para comfy-ui
if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
  alias CIVITAI_API_TOKEN=CIVITAI_TOKEN
  export CIVITAI_API_TOKEN=CIVITAI_TOKEN
fi
if [[ -n "${HF_TOKEN:-}" ]]; then
  alias HF_API_TOKEN=HF_API_TOKEN
  export HF_API_TOKEN=HF_TOKEN
fi

# =========================
# RCLONE INTEGRAÇÃO (BEGIN)
# =========================
: "${RCLONE_CONF_URL:=https://raw.githubusercontent.com/Uitalo/vast-provisioning/refs/heads/main/rclone.conf}"
: "${RCLONE_CONF_SHA256:=}"
: "${RCLONE_REMOTE:=gdrive}"
: "${RCLONE_REMOTE_ROOT:=/ComfyUI}"
: "${RCLONE_REMOTE_WORKFLOWS_SUBDIR:=/workflows}"
: "${RCLONE_COPY_CMD:=copy}"
: "${RCLONE_FLAGS:=--progress --checkers=8 --transfers=4 --drive-chunk-size=128M --fast-list}"

ensure_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo "rclone não encontrado; tentando instalar..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y rclone || true
    fi
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    echo "Instalação via apt falhou; baixando binário..."
    curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/rclone.zip
    apt-get update -y && apt-get install -y unzip || true
    unzip -q /tmp/rclone.zip -d /tmp
    RCDIR=$(find /tmp -maxdepth 1 -type d -name "rclone-*-linux-amd64" | head -n1)
    install -m 0755 "$RCDIR/rclone" /usr/local/bin/rclone
    rm -rf /tmp/rclone.zip "$RCDIR"
  fi

  # Baixa rclone.conf
  if [[ -n "${RCLONE_CONF_URL:-}" ]]; then
    echo "Baixando rclone.conf de ${RCLONE_CONF_URL}..."
    mkdir -p /root/.config/rclone
    curl -fsSL "${RCLONE_CONF_URL}" -o /root/.config/rclone/rclone.conf.tmp

    if [[ -n "${RCLONE_CONF_SHA256:-}" ]]; then
      echo "${RCLONE_CONF_SHA256}  /root/.config/rclone/rclone.conf.tmp" | sha256sum -c - \
        || { echo "Falha na verificação de integridade do rclone.conf"; exit 1; }
    fi

    if grep -q "^\[.*\]" /root/.config/rclone/rclone.conf.tmp && grep -q "^type\s*=" /root/.config/rclone/rclone.conf.tmp; then
      mv /root/.config/rclone/rclone.conf.tmp /root/.config/rclone/rclone.conf
      chmod 600 /root/.config/rclone/rclone.conf
      echo "rclone.conf salvo."
    else
      echo "Conteúdo inesperado em rclone.conf baixado."; rm -f /root/.config/rclone/rclone.conf.tmp
      exit 1
    fi
  fi

  rclone listremotes | grep -q "^${RCLONE_REMOTE}:" || {
    echo "ERRO: remoto '${RCLONE_REMOTE}:' não encontrado no rclone.conf."
    rclone listremotes || true
    exit 1
  }
}

rclone_sync_from_drive() {
  echo "Sincronizando artefatos do Google Drive (${RCLONE_REMOTE})..."

  declare -A MAPS=(
    ["${RCLONE_REMOTE_ROOT}/models/checkpoints"]="${COMFYUI_DIR}/models/checkpoints"
    ["${RCLONE_REMOTE_ROOT}/models/unet"]="${COMFYUI_DIR}/models/unet"
    ["${RCLONE_REMOTE_ROOT}/models/vae"]="${COMFYUI_DIR}/models/vae"
    ["${RCLONE_REMOTE_ROOT}/models/clip"]="${COMFYUI_DIR}/models/clip"
    ["${RCLONE_REMOTE_ROOT}/models/loras"]="${COMFYUI_DIR}/models/loras"
    ["${RCLONE_REMOTE_ROOT}/models/controlnet"]="${COMFYUI_DIR}/models/controlnet"
    ["${RCLONE_REMOTE_ROOT}/models/ipadapter"]="${COMFYUI_DIR}/models/ipadapter"
    ["${RCLONE_REMOTE_ROOT}/models/embeddings"]="${COMFYUI_DIR}/models/embeddings"
  )

  for SRC in "${!MAPS[@]}"; do
    DST="${MAPS[$SRC]}"
    mkdir -p "$DST"
    echo "rclone ${RCLONE_COPY_CMD} ${RCLONE_REMOTE}:${SRC} -> ${DST}"
    rclone ${RCLONE_COPY_CMD} "${RCLONE_REMOTE}:${SRC}" "${DST}" ${RCLONE_FLAGS} || true
  done

  local WF_LOCAL="${COMFYUI_DIR}/user/default/workflows"
  mkdir -p "$WF_LOCAL"
  echo "rclone ${RCLONE_COPY_CMD} ${RCLONE_REMOTE}:${RCLONE_REMOTE_ROOT}${RCLONE_REMOTE_WORKFLOWS_SUBDIR} -> ${WF_LOCAL}"
  rclone ${RCLONE_COPY_CMD} "${RCLONE_REMOTE}:${RCLONE_REMOTE_ROOT}${RCLONE_REMOTE_WORKFLOWS_SUBDIR}" "${WF_LOCAL}" ${RCLONE_FLAGS} || true

  echo "Sincronização via rclone finalizada."
}
# =======================
# RCLONE INTEGRAÇÃO (END)
# =======================

# Pacotes adicionais (se quiser usar apt para deps do comfy-cli futuramente)
APT_PACKAGES=( )

# Pacotes pip do seu script + comfy-cli
PIP_PACKAGES=( )

NODES=( )

WORKFLOWS=(
  "https://gist.githubusercontent.com/robballantyne/f8cb692bdcd89c96c0bd1ec0c969d905/raw/2d969f732d7873f0e1ee23b2625b50f201c722a5/flux_dev_example.json"
)

CLIP_MODELS=(
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
)

UNET_MODELS=( )
VAE_MODELS=( )

# ================
# COMFY-CLI (BEGIN)
# ================
install_comfy_cli() {
  echo "Instalando comfy-cli no venv ativo..."
  # Pode fixar versão se quiser, ex: comfy-cli==0.8.2
  pip install --no-cache-dir comfy-cli
}

configure_comfy_cli() {
  echo "Configurando comfy-cli "


  comfy set-default "$COMFYUI_DIR"



}
# ==============
# COMFY-CLI (END)
# ==============

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
  provisioning_print_header

  # 1) rclone + sync do Drive
  ensure_rclone
  rclone_sync_from_drive

  # 2) pacotes, nodes, pip
  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # 3) Instala e configura comfy-cli
  install_comfy_cli_isolado
  configure_comfy_cli_isolado

  # Alias persistente e imediato
  echo "alias comfy='/venv/comfycli/bin/comfy'" >> /root/.bashrc
  alias comfy='/venv/comfycli/bin/comfy'
  export PATH="/venv/comfycli/bin:$PATH"


  # 4) workflows default (caso não tenham vindo do Drive)
  workflows_dir="${COMFYUI_DIR}/user/default/workflows"
  mkdir -p "${workflows_dir}"
  provisioning_get_files "${workflows_dir}" "${WORKFLOWS[@]}"

  # 5) decide dev/schnell
  if provisioning_has_valid_hf_token; then
    UNET_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors")
    VAE_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors")
  else
    UNET_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors")
    VAE_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors")
    sed -i 's/flux1-dev\.safetensors/flux1-schnell.safetensors/g' "${workflows_dir}/flux_dev_example.json" || true
  fi

  # 6) completa downloads faltantes
  provisioning_get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/vae"  "${VAE_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/clip" "${CLIP_MODELS[@]}"

  provisioning_print_end
}

function provisioning_get_apt_packages() {
  if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y "${APT_PACKAGES[@]}"
    else
      echo "apt não disponível; pulando APT_PACKAGES."
    fi
  fi
}

function provisioning_get_pip_packages() {
  if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    pip install --no-cache-dir "${PIP_PACKAGES[@]}"
  fi
}

function provisioning_get_nodes() {
  for repo in "${NODES[@]}"; do
    dir="${repo##*/}"
    path="${COMFYUI_DIR}custom_nodes/${dir}"
    requirements="${path}/requirements.txt"
    if [[ -d $path ]]; then
      if [[ ${AUTO_UPDATE:-true,,} != "false" ]]; then
        printf "Updating node: %s...\n" "${repo}"
        ( cd "$path" && git pull )
        if [[ -e $requirements ]]; then
          pip install --no-cache-dir -r "$requirements"
        fi
      fi
    else
      printf "Downloading node: %s...\n" "${repo}"
      git clone "${repo}" "${path}" --recursive
      if [[ -e $requirements ]]; then
        pip install --no-cache-dir -r "${requirements}"
      fi
    fi
  done
}

function provisioning_get_files() {
  if [[ -z ${2:-} ]]; then return 1; fi
  dir="$1"; shift
  mkdir -p "$dir"
  arr=("$@")
  printf "Verificando/baixando %s arquivo(s) para %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Processando: %s\n" "${url}"
    provisioning_download "${url}" "${dir}"
    printf "\n"
  done
}

function provisioning_print_header() {
  printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
  printf "\nProvisioning complete:  Application will start now\n\n"
}

function provisioning_has_valid_hf_token() {
  [[ -n "${HF_TOKEN:-}" ]] || return 1
  url="https://huggingface.co/api/whoami-v2"
  response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
    -H "Authorization: Bearer $HF_TOKEN" \
    -H "Content-Type: application/json")
  [[ "$response" -eq 200 ]]
}

function provisioning_has_valid_civitai_token() {
  [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
  url="https://civitai.com/api/v1/models?hidden=1&limit=1"
  response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
    -H "Authorization: Bearer $CIVITAI_TOKEN" \
    -H "Content-Type: application/json")
  [[ "$response" -eq 200 ]]
}

function provisioning_download() {
  local url="$1"
  local outdir="$2"
  local auth_token=""
  local filename=""

  if [[ -n "${HF_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_token="$HF_TOKEN"
  elif [[ -n "${CIVITAI_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    auth_token="$CIVITAI_TOKEN"
  fi

  filename=$(basename "${url%%\?*}")
  if ls -1 "${outdir}/${filename}" >/dev/null 2>&1; then
    echo "Já existe: ${outdir}/${filename} — pulando download."
    return 0
  fi

  if [[ -n $auth_token ]]; then
    wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$outdir" "$url"
  else
    wget -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$outdir" "$url"
  fi
}

if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi