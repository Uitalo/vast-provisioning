#!/bin/bash

set -euo pipefail


# echo 'export NOME_VARIAVEL="valor_desejado"' >> ~/.bashrc

# =================================================================================================
# Settings
# =================================================================================================
export DOWNLOAD_GDRIVE_MODELS=false

#lora
# https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors
# https://civitai.com/api/download/models/1602715?type=Model&format=SafeTensor

# Pacotes adicionais (se quiser usar apt para deps do comfy-cli futuramente)
APT_PACKAGES=()
# Pacotes pip do seu script + comfy-cli
# shellcheck disable=SC2054
PIP_PACKAGES=('sageattention', 'deepdiff', 'aiohttp','huggingface_hub' )



NODES=()



WORKFLOWS=(
 #"https://gist.githubusercontent.com/robballantyne/f8cb692bdcd89c96c0bd1ec0c969d905/raw/2d969f732d7873f0e1ee23b2625b50f201c722a5/flux_dev_example.json"
)



# shellcheck disable=SC2054
UNET_MODELS=(
"https://huggingface.co/bullerwins/Wan2.2-I2V-A14B-GGUF/resolve/main/wan2.2_i2v_high_noise_14B_Q4_K_M.gguf",
"https://huggingface.co/bullerwins/Wan2.2-I2V-A14B-GGUF/resolve/main/wan2.2_i2v_high_noise_14B_Q4_K_M.gguf"
)
VAE_MODELS=(
"https://huggingface.co/ratoenien/wan_2.1_vae/resolve/main/wan_2.1_vae.safetensors"
)
CLIP_MODELS=(
  #"https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"
 # "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
 "https://huggingface.co/chatpig/umt5xxl-encoder-gguf/resolve/main/umt5xxl-encoder-q8_0.gguf"
)

LORAS_MODELS=(

)

UPSCALER_MODELS=(
'https://huggingface.co/dtarnow/UPscaler/resolve/main/RealESRGAN_x2plus.pth'

)


CHECKPOINTS_MODELS=(

)


  # text_encoders, diffusion_models

DIFFUSION_MODELS=(


)


TEXTENCODERS_MODELS=(

)




#!/bin/bash

set -euo pipefail

# Ativa o venv principal (ComfyUI)
source /venv/main/bin/activate

# Diretórios base
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# =========================
# RCLONE (BEGIN)
# =========================
: "${RCLONE_CONF_URL:=https://raw.githubusercontent.com/Uitalo/vast-provisioning/refs/heads/main/rclone.conf}"
: "${RCLONE_CONF_SHA256:=}"   # opcional, para checagem de integridade
: "${RCLONE_REMOTE:=gdrive}"
: "${RCLONE_REMOTE_ROOT:=/ComfyUI}"
: "${RCLONE_REMOTE_WORKFLOWS_SUBDIR:=/workflows}"
: "${RCLONE_COPY_CMD:=copy}"  # mude para "sync" se quiser espelhar
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

  # rclone.conf por URL
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
      echo "rclone.conf salvo em /root/.config/rclone/rclone.conf"
    else
      echo "Conteúdo inesperado no rclone.conf baixado."; rm -f /root/.config/rclone/rclone.conf.tmp; exit 1
    fi
  fi

  # Remoto deve existir
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
# =========================
# RCLONE (END)
# =========================

# Pacotes (apt/pip) do seu ambiente
APT_PACKAGES=( )
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

# =========================
# COMFY-CLI ISOLADO (BEGIN)
# =========================
COMFYCLI_VENV=/venv/comfycli

comfy_bin() {
  echo "${COMFYCLI_VENV}/bin/comfy"
}

install_comfy_cli_isolado() {
  echo "Instalando comfy-cli em venv isolado: ${COMFYCLI_VENV}"
  python -m venv "${COMFYCLI_VENV}"
  "${COMFYCLI_VENV}/bin/pip" install --upgrade pip
  # Fixe a versão se quiser estabilidade (ex.: comfy-cli==0.9.0)
  "${COMFYCLI_VENV}/bin/pip" install --no-cache-dir comfy-cli
}

configure_comfy_cli_isolado() {
  echo "Configurando comfy-cli (set-default ou fallback cli.toml) no venv isolado..."

  # shellcheck disable=SC2155
  local COMFY="$("comfy_bin")"
  local WORKFLOWS_DIR="${COMFYUI_DIR}/user/default/workflows"
  local MODELS_DIR="${COMFYUI_DIR}/models"

  mkdir -p "$WORKFLOWS_DIR" "$MODELS_DIR"

  if "$COMFY" --help >/dev/null 2>&1 && "$COMFY" set-default --help >/dev/null 2>&1; then
    set +e
    "$COMFY" set-default --workspace "${COMFYUI_DIR}" || true
    "$COMFY" set-default --workflows-dir "${WORKFLOWS_DIR}" || true
    "$COMFY" set-default --models-dir "${MODELS_DIR}" || true
    "$COMFY" set-default --unet-dir       "${COMFYUI_DIR}/models/unet" || true
    "$COMFY" set-default --vae-dir        "${COMFYUI_DIR}/models/vae" || true
    "$COMFY" set-default --clip-dir       "${COMFYUI_DIR}/models/clip" || true
    "$COMFY" set-default --loras-dir      "${COMFYUI_DIR}/models/loras" || true
    "$COMFY" set-default --controlnet-dir "${COMFYUI_DIR}/models/controlnet" || true
    "$COMFY" set-default --ipadapter-dir  "${COMFYUI_DIR}/models/ipadapter" || true
    "$COMFY" set-default --embeddings-dir "${COMFYUI_DIR}/models/embeddings" || true
    [[ -n "${HF_TOKEN:-}" ]] && "$COMFY" set-default --hf-api-token "$HF_TOKEN" || true
    [[ -n "${CIVITAI_TOKEN:-}" ]] && "$COMFY" set-default --civitai-api-token "$CIVITAI_TOKEN" || true
    set -e
  else
    echo "Subcomando 'set-default' indisponível; usando fallback em ~/.config/comfy/cli.toml"
    local CFG_DIR="/root/.config/comfy"
    local CFG_FILE="${CFG_DIR}/cli.toml"
    mkdir -p "$CFG_DIR"
    cat > "$CFG_FILE" <<EOF
# Gerado automaticamente
workspace_dir = "${COMFYUI_DIR}"
workflows_dir = "${WORKFLOWS_DIR}"
models_dir    = "${MODELS_DIR}"

[models]
unet        = "${COMFYUI_DIR}/models/unet"
vae         = "${COMFYUI_DIR}/models/vae"
clip        = "${COMFYUI_DIR}/models/clip"
loras       = "${COMFYUI_DIR}/models/loras"
controlnet  = "${COMFYUI_DIR}/models/controlnet"
ipadapter   = "${COMFYUI_DIR}/models/ipadapter"
embeddings  = "${COMFYUI_DIR}/models/embeddings"

[tokens]
hf      = "${HF_TOKEN:-}"
civitai = "${CIVITAI_TOKEN:-}"
EOF
    chmod 600 "$CFG_FILE"
  fi
}
# =========================
# COMFY-CLI ISOLADO (END)
# =========================

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

provisioning_print_header() {
  printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

provisioning_print_end() {
  printf "\nProvisioning complete:  Application will start now\n\n"
}

provisioning_get_apt_packages() {
  if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y "${APT_PACKAGES[@]}"
    else
      echo "apt não disponível; pulando APT_PACKAGES."
    fi
  fi
}

provisioning_get_pip_packages() {
  if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    pip install --no-cache-dir "${PIP_PACKAGES[@]}"
  fi
}

provisioning_get_nodes() {
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

provisioning_has_valid_hf_token() {
  [[ -n "${HF_TOKEN:-}" ]] || return 1
  local url="https://huggingface.co/api/whoami-v2"
  local response
  response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
    -H "Authorization: Bearer $HF_TOKEN" \
    -H "Content-Type: application/json")
  [[ "$response" -eq 200 ]]
}

provisioning_has_valid_civitai_token() {
  [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
  local url="https://civitai.com/api/v1/models?hidden=1&limit=1"
  local response
  response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
    -H "Authorization: Bearer $CIVITAI_TOKEN" \
    -H "Content-Type: application/json")
  [[ "$response" -eq 200 ]]
}

provisioning_get_files() {
  if [[ -z ${2:-} ]]; then return 1; fi
  local dir="$1"; shift
  mkdir -p "$dir"
  local arr=("$@")
  printf "Verificando/baixando %s arquivo(s) para %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Processando: %s\n" "${url}"
    provisioning_download "${url}" "${dir}"
    printf "\n"
  done
}

provisioning_download() {
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

provisioning_start() {
  provisioning_print_header

  # Espelha CIVITAI_TOKEN em CIVITAI_API_TOKEN (para ferramentas que esperam esse nome)
  if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
    export CIVITAI_API_TOKEN="$CIVITAI_TOKEN"
  fi

  # 1) rclone + sync do Drive
  ensure_rclone
  rclone_sync_from_drive

  # 2) pacotes, nodes, pip (do ambiente ComfyUI)
  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # 3) comfy-cli isolado e configuração
  install_comfy_cli_isolado
  configure_comfy_cli_isolado
  "$("comfy_bin")" --version || true
  "$("comfy_bin")" config show || true

  # 4) workflows default (se não vieram do Drive)
  local workflows_dir="${COMFYUI_DIR}/user/default/workflows"
  mkdir -p "${workflows_dir}"
  provisioning_get_files "${workflows_dir}" "${WORKFLOWS[@]}"

  # 5) escolhe dev/schnell e completa downloads faltantes
  if provisioning_has_valid_hf_token; then
    UNET_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors")
    VAE_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors")
  else
    UNET_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors")
    VAE_MODELS+=("https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors")
    sed -i 's/flux1-dev\.safetensors/flux1-schnell.safetensors/g' "${workflows_dir}/flux_dev_example.json" || true
  fi


  provisioning_get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/vae"  "${VAE_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/clip" "${CLIP_MODELS[@]}"

  # Adiiconado

  if (( LORAS_MODELS )); then
    echo "Baixando modelos loras"
    provisioning_get_files "${COMFYUI_DIR}/models/loras" "${LORAS_MODELS[@]}"
  else
    echo "Sem modelos loras definidos"
  fi

  if (( UPSCALER_MODELS )); then
    echo "Baixando modelos Upscaler"
    provisioning_get_files "${COMFYUI_DIR}/models/upscaler_models" "${UPSCALER_MODELS[@]}"
  else
    echo "Sem modelos Upscaler definidos"
  fi

  if (( CHECKPOINTS_MODELS )); then
    echo "Baixando modelos Upscaler"
    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints" "${CHECKPOINTS_MODELS[@]}"
  else
    echo "Sem modelos Upscaler definidos"
  fi

  if (( DIFFUSION_MODELS )); then
    echo "Baixando modelos Upscaler"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
  else
    echo "Sem modelos Upscaler definidos"
  fi

   if (( TEXTENCODERS_MODELS )); then
    echo "Baixando modelos Upscaler"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXTENCODERS_MODELS[@]}"
  else
    echo "Sem modelos Upscaler definidos"
  fi



  provisioning_print_end
}

if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi