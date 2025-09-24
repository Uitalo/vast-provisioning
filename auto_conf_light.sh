#!/bin/bash
set -euo pipefail

# ================================================================================================
# AMBIENTE BÁSICO
# ================================================================================================
# Ativa venv principal, se existir
if [[ -d /venv/main/bin ]]; then
  # shellcheck disable=SC1091
  source /venv/main/bin/activate
fi

# Define WORKSPACE/COMFYUI_DIR com fallback seguro
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_DIR:=${WORKSPACE}/ComfyUI}"

# ================================================================================================
# CONFIGURAÇÕES / LOGS ENXUTOS
# ================================================================================================
# Verbosidade dos downloads/sync
: "${RCLONE_FLAGS:=--stats=0 --log-level ERROR --checkers=8 --transfers=4 --drive-chunk-size=128M --fast-list}"
APT_QUIET_OPTS=(-qq -o=Dpkg::Use-Pty=0)
PIP_QUIET_OPTS=(-q --progress-bar off --disable-pip-version-check --no-input)
GIT_QUIET_OPTS=(--quiet)

# (mantido para compat; atualmente não usado)
: "${DOWNLOAD_GDRIVE_MODELS:=false}"

# Pacotes APT adicionais (se apt existir)
APT_PACKAGES=()

# Pacotes pip do seu script + comfy-cli (remove duplicatas)
PIP_PACKAGES=('sageattention' 'deepdiff' 'aiohttp' 'huggingface-hub' 'toml')

# Nodes custom (repositórios git)
NODES=()

# Listas de modelos
CHECKPOINTS_MODELS=()
TEXT_ENCODERS_MODELS=()
UNET_MODELS=(
  "https://huggingface.co/bullerwins/Wan2.2-I2V-A14B-GGUF/resolve/main/wan2.2_i2v_high_noise_14B_Q4_K_M.gguf"
  "https://huggingface.co/bullerwins/Wan2.2-I2V-A14B-GGUF/resolve/main/wan2.2_i2v_low_noise_14B_Q4_K_M.gguf"
)
VAE_MODELS=(
  "https://huggingface.co/ratoenien/wan_2.1_vae/resolve/main/wan_2.1_vae.safetensors"
)
CLIP_MODELS=(
  "https://huggingface.co/chatpig/umt5xxl-encoder-gguf/resolve/main/umt5xxl-encoder-q8_0.gguf"
)
LORAS_MODELS=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
  "https://civitai.com/api/download/models/1602715?type=Model&format=SafeTensor"
)
UPSCALER_MODELS=(
  "https://huggingface.co/dtarnow/UPscaler/resolve/main/RealESRGAN_x2plus.pth"
)
DIFFUSION_MODELS=()  # estava sendo usado sem declarar
WORKFLOWS=()

# ================================================================================================
# TELEGRAM NOTIFY
# ================================================================================================
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${TELEGRAM_PARSE_MODE:=HTML}"  # HTML|MarkdownV2|None

tg_can_notify() {
  [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]
}

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

tg_escape_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

PROVISION_START_TS=""

notify_start() {
  echo "enviando notificação de inicío de instalação"
  PROVISION_START_TS="$(date +%s)"
  local host
  host="$(hostname | tg_escape_html)"
  local msg="🚀 <b>Provisioning iniciado</b>\nHost: <code>${host}</code>\nHora: <code>$(date -Iseconds)</code>"
  tg_send "$msg"
}

notify_end_success() {
  tg_send "Concluído!"
}

notify_end_failure() {
  local code="$?"
  local host
  host="$(hostname | tg_escape_html)"
  local msg="❌ <b>Provisioning falhou</b>\nHost: <code>${host}</code>\nCódigo: <code>${code}</code>\nHora: <code>$(date -Iseconds)</code>"
  tg_send "$msg"
  exit "$code"
}
trap notify_end_failure ERR

# ================================================================================================
# UTILITÁRIOS / PRÉ-REQS
# ================================================================================================
ensure_tooling() {
  # Garante ferramentas comuns sem depender exclusivamente de apt
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get "${APT_QUIET_OPTS[@]}" update -y && apt-get "${APT_QUIET_OPTS[@]}" install -y curl; fi
  fi
  if ! command -v wget >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get "${APT_QUIET_OPTS[@]}" install -y wget; fi
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get "${APT_QUIET_OPTS[@]}" install -y unzip; fi
  fi
  if ! command -v git >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get "${APT_QUIET_OPTS[@]}" install -y git; fi
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get "${APT_QUIET_OPTS[@]}" install -y coreutils; fi
  fi
  command -v sed >/dev/null 2>&1 || true
}

# ================================================================================================
# RCLONE
# ================================================================================================
: "${RCLONE_CONF_URL:=https://raw.githubusercontent.com/Uitalo/vast-provisioning/refs/heads/main/rclone.conf}"
: "${RCLONE_CONF_SHA256:=}"   # opcional
: "${RCLONE_REMOTE:=gdrive}"
: "${RCLONE_REMOTE_ROOT:=/ComfyUI}"
: "${RCLONE_REMOTE_WORKFLOWS_SUBDIR:=/workflows}"
: "${RCLONE_COPY_CMD:=copy}"  # use "sync" para espelhar

ensure_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo "rclone não encontrado; tentando instalar..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get "${APT_QUIET_OPTS[@]}" update -y && apt-get "${APT_QUIET_OPTS[@]}" install -y rclone || true
    fi
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    echo "Instalação via apt falhou; baixando binário..."
    curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/rclone.zip
    command -v unzip >/dev/null 2>&1 || (apt-get "${APT_QUIET_OPTS[@]}" update -y && apt-get "${APT_QUIET_OPTS[@]}" install -y unzip || true)
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
      echo "Conteúdo inesperado no rclone.conf baixado."
      rm -f /root/.config/rclone/rclone.conf.tmp
      exit 1
    fi
  fi

  # Remoto deve existir
  if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:"; then
    echo "ERRO: remoto '${RCLONE_REMOTE}:' não encontrado no rclone.conf."
    rclone listremotes || true
    exit 1
  fi
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
    mkdir -p "$DST"  # garante criação local antes do copy
    echo "rclone ${RCLONE_COPY_CMD} ${RCLONE_REMOTE}:${SRC} -> ${DST}"
    rclone ${RCLONE_COPY_CMD} "${RCLONE_REMOTE}:${SRC}" "${DST}" ${RCLONE_FLAGS} || true
  done

  local WF_LOCAL="${COMFYUI_DIR}/user/default/workflows"
  mkdir -p "$WF_LOCAL"
  echo "rclone ${RCLONE_COPY_CMD} ${RCLONE_REMOTE}:${RCLONE_REMOTE_ROOT}${RCLONE_REMOTE_WORKFLOWS_SUBDIR} -> ${WF_LOCAL}"
  rclone ${RCLONE_COPY_CMD} "${RCLONE_REMOTE}:${RCLONE_REMOTE_ROOT}${RCLONE_REMOTE_WORKFLOWS_SUBDIR}" "${WF_LOCAL}" ${RCLONE_FLAGS} || true

  echo "Sincronização via rclone finalizada."
}

# ================================================================================================
# COMFY-CLI ISOLADO
# ================================================================================================
COMFYCLI_VENV=/venv/comfycli
comfy_bin() { echo "${COMFYCLI_VENV}/bin/comfy"; }

install_comfy_cli_isolado() {
  echo "Instalando comfy-cli em venv isolado: ${COMFYCLI_VENV}"
  python -m venv "${COMFYCLI_VENV}"
  "${COMFYCLI_VENV}/bin/pip" install "${PIP_QUIET_OPTS[@]}" --upgrade pip
  "${COMFYCLI_VENV}/bin/pip" install "${PIP_QUIET_OPTS[@]}" --no-cache-dir comfy-cli

  echo "Criando link simbólico do comfy-cli para env do ComfyUI"
  if [[ -d /venv/main/bin ]]; then
    ln -sf "${COMFYCLI_VENV}/bin/comfy" /venv/main/bin/
  else
    echo "Aviso: /venv/main/bin não existe; pulando criação do symlink do comfy-cli."
  fi
}

configure_comfy_cli_isolado() {
  echo "Configurando comfy-cli (set-default ou fallback cli.toml) no venv isolado..."
  local COMFY
  COMFY="$(comfy_bin)"
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

# ================================================================================================
# INSTALAÇÃO DO COMFYUI (SUBSTITUI PADRÃO)
# ================================================================================================
is_valid_comfy_repo() {
  [[ -d "${COMFYUI_DIR}/.git" ]] || return 1
  local url
  url="$(cd "${COMFYUI_DIR}" && git remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ comfyanonymous/ComfyUI ]] || return 1
}

prepare_clean_comfy_dir() {
  # Se existir e for repositório "ruim", remove; se não existir, cria
  if [[ -d "${COMFYUI_DIR}" ]]; then
    if ! is_valid_comfy_repo; then
      echo "Removendo diretório inválido de ComfyUI em ${COMFYUI_DIR}..."
      rm -rf "${COMFYUI_DIR}"
    fi
  fi
  mkdir -p "${COMFYUI_DIR}"
}

install_comfyui_via_cli() {
  local COMFY; COMFY="$(comfy_bin)"
  prepare_clean_comfy_dir

  echo "Instalando ComfyUI com comfy-cli (não-interativo)..."
  if "$COMFY" install --workspace "${COMFYUI_DIR}" --yes --quiet >/dev/null 2>&1; then
    return 0
  fi

  # Fallback 1: tentar pipar respostas / forçar yes
  if command -v yes >/dev/null 2>&1; then
    echo "Repetindo instalação com respostas automáticas..."
    { printf 'n\ny\n' | "$COMFY" install --workspace "${COMFYUI_DIR}" >/dev/null 2>&1; } && return 0
    yes | "$COMFY" install --workspace "${COMFYUI_DIR}" >/dev/null 2>&1 && return 0
  fi

  return 1
}

fallback_install_comfyui_git() {
  echo "Fazendo fallback para instalação padrão (git clone)..."
  rm -rf "${COMFYUI_DIR}"
  git clone "${GIT_QUIET_OPTS[@]}" --depth 1 https://github.com/comfyanonymous/ComfyUI "${COMFYUI_DIR}"
  if [[ -f "${COMFYUI_DIR}/requirements.txt" ]]; then
    pip install "${PIP_QUIET_OPTS[@]}" --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt"
  fi
}

install_comfyui_replacing_standard() {
  echo "==> ComfyUI: instalação substitutiva via comfy-cli"
  if install_comfyui_via_cli; then
    echo "ComfyUI instalado via comfy-cli."
  else
    echo "comfy-cli falhou ou foi interativo demais; usando fallback git..."
    fallback_install_comfyui_git
  fi
}

# ================================================================================================
# DOWNLOADS DE MODELOS
# ================================================================================================
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
  local filename

  if [[ -n "${HF_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_token="$HF_TOKEN"
  elif [[ -n "${CIVITAI_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    auth_token="$CIVITAI_TOKEN"
  fi

  filename="$(basename "${url%%\?*}")"
  if [[ -f "${outdir}/${filename}" ]]; then
    echo "Já existe: ${outdir}/${filename} — pulando download."
    return 0
  fi

  mkdir -p "$outdir"
  if [[ -n $auth_token ]]; then
    wget --header="Authorization: Bearer $auth_token" -nv --no-clobber --trust-server-names --content-disposition \
         --tries=3 --retry-connrefused --timeout=30 \
         -P "$outdir" "$url"
  else
    wget -nv --no-clobber --trust-server-names --content-disposition \
         --tries=3 --retry-connrefused --timeout=30 \
         -P "$outdir" "$url"
  fi
}

# ================================================================================================
# HELPERS DIVERSOS
# ================================================================================================
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

# ================================================================================================
# FLUXO PRINCIPAL
# ================================================================================================
provisioning_print_header() {
  printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

provisioning_print_end() {
  printf "\nProvisioning complete:  Application will start now\n\n"
}

provisioning_get_apt_packages() {
  if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get "${APT_QUIET_OPTS[@]}" update -y
      apt-get "${APT_QUIET_OPTS[@]}" install -y "${APT_PACKAGES[@]}"
    else
      echo "apt não disponível; pulando APT_PACKAGES."
    fi
  fi
}

provisioning_get_pip_packages() {
  if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    pip install "${PIP_QUIET_OPTS[@]}" --no-cache-dir "${PIP_PACKAGES[@]}"
  fi
}

provisioning_get_nodes() {
  echo "Obtendo modelos.."
  for repo in "${NODES[@]}"; do
    dir="${repo##*/}"
    path="${COMFYUI_DIR}/custom_nodes/${dir}"
    requirements="${path}/requirements.txt"
    if [[ -d $path ]]; then
      if [[ "${AUTO_UPDATE:-true}" != "false" ]]; then
        printf "Updating node: %s...\n" "${repo}"
        ( cd "$path" && git pull "${GIT_QUIET_OPTS[@]}" )
        if [[ -e $requirements ]]; then
           pip install "${PIP_QUIET_OPTS[@]}" --no-cache-dir -r "$requirements"
        fi
      fi
    else
      printf "Downloading node: %s...\n" "${repo}"
      git clone "${GIT_QUIET_OPTS[@]}" --depth 1 --filter=blob:none "${repo}" "${path}" --recursive
      if [[ -e $requirements ]]; then
        pip install "${PIP_QUIET_OPTS[@]}" --no-cache-dir -r "${requirements}"
      fi
    fi
  done
}

provisioning_start() {
  echo "Iniciando instalação"
  provisioning_print_header
  notify_start

  ensure_tooling

  # Espelha CIVITAI_TOKEN em CIVITAI_API_TOKEN (para ferramentas que esperam esse nome)
  if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
    export CIVITAI_API_TOKEN="$CIVITAI_TOKEN"
  fi

  # Garante estrutura de pastas principal do ComfyUI (antes da instalação)
  mkdir -p \
    "${COMFYUI_DIR}/models/checkpoints" \
    "${COMFYUI_DIR}/models/unet" \
    "${COMFYUI_DIR}/models/vae" \
    "${COMFYUI_DIR}/models/clip" \
    "${COMFYUI_DIR}/models/loras" \
    "${COMFYUI_DIR}/models/controlnet" \
    "${COMFYUI_DIR}/models/ipadapter" \
    "${COMFYUI_DIR}/models/embeddings" \
    "${COMFYUI_DIR}/models/upscale_models" \
    "${COMFYUI_DIR}/models/diffusion_models" \
    "${COMFYUI_DIR}/models/text_encoders" \
    "${COMFYUI_DIR}/user/default/workflows" \
    "${COMFYUI_DIR}/custom_nodes"

  # 1) comfy-cli isolado e configuração
  install_comfy_cli_isolado
  configure_comfy_cli_isolado

  # 2) Instala ComfyUI substituindo a instalação padrão
 # install_comfyui_replacing_standard

  # 3) rclone + sync do Drive (agora a pasta existe corretamente)
  ensure_rclone
  rclone_sync_from_drive

  # 4) pacotes, nodes, pip (do ambiente ComfyUI)
  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # 5) workflows default (se não vieram do Drive)
  local workflows_dir="${COMFYUI_DIR}/user/default/workflows"
  provisioning_get_files "${workflows_dir}" "${WORKFLOWS[@]}"

  # 6) escolhe dev/schnell e completa downloads faltantes
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

  if ((${#LORAS_MODELS[@]})); then
    echo "Baixando modelos Loras"
    provisioning_get_files "${COMFYUI_DIR}/models/loras" "${LORAS_MODELS[@]}"
  else
    echo "Sem modelos Loras definidos"
  fi

  if ((${#UPSCALER_MODELS[@]})); then
    echo "Baixando modelos Upscaler"
    provisioning_get_files "${COMFYUI_DIR}/models/upscale_models" "${UPSCALER_MODELS[@]}"
  else
    echo "Sem modelos Upscaler definidos"
  fi

  if ((${#CHECKPOINTS_MODELS[@]})); then
    echo "Baixando modelos Checkpoints"
    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints" "${CHECKPOINTS_MODELS[@]}"
  else
    echo "Sem modelos Checkpoints definidos"
  fi

  if ((${#DIFFUSION_MODELS[@]})); then
    echo "Baixando modelos Diffusion"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
  else
    echo "Sem modelos Diffusion definidos"
  fi

  if ((${#TEXT_ENCODERS_MODELS[@]})); then
    echo "Baixando Text Encoders"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODERS_MODELS[@]}"
  else
    echo "Sem Text Encoders definidos"
  fi

  notify_end_success
  provisioning_print_end
}

if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi