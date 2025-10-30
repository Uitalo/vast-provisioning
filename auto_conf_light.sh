#!/bin/bash
set -Eeuo pipefail   # NOTE: -E para propagar ERR em funções/subshells

# ================================================================================================
# AMBIENTE BÁSICO
# ================================================================================================
if [[ -d /venv/main/bin ]]; then
  # shellcheck disable=SC1091
  source /venv/main/bin/activate
fi

: "${WORKSPACE:=/workspace}"
: "${COMFYUI_DIR:=${WORKSPACE}/ComfyUI}"

# ================================================================================================
# CONFIG / LOGS ENXUTOS
# ================================================================================================
: "${RCLONE_FLAGS:=--stats=0 --log-level ERROR --checkers=8 --transfers=4 --drive-chunk-size=128M --fast-list}"
APT_QUIET_OPTS=(-qq -o=Dpkg::Use-Pty=0)
PIP_QUIET_OPTS=(-q --progress-bar off --disable-pip-version-check --no-input)
GIT_QUIET_OPTS=(--quiet)

APT_PACKAGES=()
PIP_PACKAGES=('sageattention' 'deepdiff' 'aiohttp' 'huggingface-hub' 'toml' 'openai' 'blend_modes' 'gguf')
NODES=()

CHECKPOINTS_MODELS=()
TEXT_ENCODERS_MODELS=()
UNET_MODELS=(
  "https://huggingface.co/bullerwins/Wan2.2-I2V-A14B-GGUF/resolve/main/wan2.2_i2v_high_noise_14B_Q4_K_M.gguf"
  "https://huggingface.co/bullerwins/Wan2.2-I2V-A14B-GGUF/resolve/main/wan2.2_i2v_low_noise_14B_Q4_K_M.gguf"
)
VAE_MODELS=("https://huggingface.co/ratoenien/wan_2.1_vae/resolve/main/wan_2.1_vae.safetensors")
CLIP_MODELS=("https://huggingface.co/chatpig/umt5xxl-encoder-gguf/resolve/main/umt5xxl-encoder-q8_0.gguf")
LORAS_MODELS=(
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
  "https://civitai.com/api/download/models/1602715?type=Model&format=SafeTensor"
)
UPSCALER_MODELS=("https://huggingface.co/dtarnow/UPscaler/resolve/main/RealESRGAN_x2plus.pth")
DIFFUSION_MODELS=()
WORKFLOWS=()


# /workflows/ComfyUI/user/default/workflows
# Caminho do snapshot remoto/local
: "${SNAPSHOT_REMOTE:=ComfyUI/snapshots/current.json}"   # relativo ao remoto do rclone (ex.: gdrive:)
: "${SNAPSHOT_LOCAL:=${COMFYUI_DIR}/user/default/ComfyUI-Manager/snapshots/current.json}"

# (Opcional) parâmetros de launch padrão
: "${COMFY_LAUNCH_EXTRAS:=--listen 0.0.0.0 --port 8188}"

# ================================================================================================
# TELEGRAM (opcional)
# ================================================================================================
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${TELEGRAM_PARSE_MODE:=HTML}"

tg_can_notify() { [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; }
tg_send() {
  tg_can_notify || return 0
  # NOTE: usa --data-urlencode para não quebrar com caracteres especiais
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" \
    --data-urlencode "parse_mode=${TELEGRAM_PARSE_MODE}" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null || true
}
tg_escape_html() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

notify_start() {
  local host; host="$(hostname | tg_escape_html)"
  tg_send "🚀 <b>Provisioning iniciado</b>%0AHost: <code>${host}</code>%0AHora: <code>$(date -Iseconds)</code>"
}
notify_end_success() { tg_send "✅ Concluído!"; }
notify_end_failure() {
  local code="$1" host
  host="$(hostname | tg_escape_html)"
  tg_send "❌ <b>Provisioning falhou</b>%0AHost: <code>${host}</code>%0ACódigo: <code>${code}</code>%0AHora: <code>$(date -Iseconds)</code>"
  exit "$code"
}
# NOTE: passa o $? da falha para a função (evita perder o código de erro)
trap 'notify_end_failure $?' ERR

# ================================================================================================
# UTILITÁRIOS / PRÉ-REQS
# ================================================================================================
ensure_tooling() {
  if ! command -v curl >/dev/null 2>&1;  then command -v apt-get >/dev/null 2>&1 && apt-get "${APT_QUIET_OPTS[@]}" update -y && apt-get "${APT_QUIET_OPTS[@]}" install -y curl;  fi
  if ! command -v wget >/dev/null 2>&1;  then command -v apt-get >/dev/null 2>&1 && apt-get "${APT_QUIET_OPTS[@]}" install -y wget;  fi
  # NOTE: linha corrigida (antes tinha /devnull)
  if ! command -v unzip >/dev/null 2>&1; then command -v apt-get >/dev/null 2>&1 && apt-get "${APT_QUIET_OPTS[@]}" install -y unzip; fi
  if ! command -v git >/dev/null 2>&1;   then command -v apt-get >/dev/null 2>&1 && apt-get "${APT_QUIET_OPTS[@]}" install -y git;   fi
  if ! command -v sha256sum >/dev/null 2>&1; then command -v apt-get >/dev/null 2>&1 && apt-get "${APT_QUIET_OPTS[@]}" install -y coreutils; fi
}

# ================================================================================================
# RCLONE
# ================================================================================================
: "${RCLONE_CONF_URL:=https://raw.githubusercontent.com/Uitalo/vast-provisioning/refs/heads/main/rclone.conf}"
: "${RCLONE_CONF_SHA256:=}"
: "${RCLONE_REMOTE:=gdrive}"
: "${RCLONE_REMOTE_ROOT:=/ComfyUI}"
: "${RCLONE_REMOTE_WORKFLOWS_SUBDIR:=ComfyUI/user/workflows}"
: "${RCLONE_COPY_CMD:=copy}"  # ou "sync"



# Settings:
tg_send "Baixar modelos do remoto? '${DOWNLOAD_GDRIVE_MODELS}'"

ensure_rclone() {
  echo "Configurando Rclone"
  if ! command -v rclone >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 && apt-get "${APT_QUIET_OPTS[@]}" update -y && apt-get "${APT_QUIET_OPTS[@]}" install -y rclone || true
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/rclone.zip
    command -v unzip >/dev/null 2>&1 || (apt-get "${APT_QUIET_OPTS[@]}" update -y && apt-get "${APT_QUIET_OPTS[@]}" install -y unzip || true)
    unzip -q /tmp/rclone.zip -d /tmp
    RCDIR=$(find /tmp -maxdepth 1 -type d -name "rclone-*-linux-amd64" | head -n1)
    install -m 0755 "$RCDIR/rclone" /usr/local/bin/rclone
    rm -rf /tmp/rclone.zip "$RCDIR"
  fi

  if [[ -n "${RCLONE_CONF_URL:-}" ]]; then
    mkdir -p /root/.config/rclone
    curl -fsSL "${RCLONE_CONF_URL}" -o /root/.config/rclone/rclone.conf.tmp
    if [[ -n "${RCLONE_CONF_SHA256:-}" ]]; then
      echo "${RCLONE_CONF_SHA256}  /root/.config/rclone/rclone.conf.tmp" | sha256sum -c - \
        || { echo "Falha na verificação do rclone.conf"; exit 1; }
    fi
    if grep -q "^\[.*\]" /root/.config/rclone/rclone.conf.tmp && grep -q "^type\s*=" /root/.config/rclone/rclone.conf.tmp; then
      mv /root/.config/rclone/rclone.conf.tmp /root/.config/rclone/rclone.conf
      chmod 600 /root/.config/rclone/rclone.conf
    else
      echo "Conteúdo inesperado no rclone.conf"
      tg_send "Falha ao configurar Rclone: Conteúdo inesperado no rclone.conf"
      rm -f /root/.config/rclone/rclone.conf.tmp
      exit 1
    fi
  fi

  if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:"; then
    tg_send "Falha ao configurar Rclone: remoto '${RCLONE_REMOTE}:' não encontrado no rclone.conf"
    echo "ERRO: remoto '${RCLONE_REMOTE}:' não encontrado no rclone.conf."
    rclone listremotes || true
    exit 1
  fi
}

rclone_sync_from_drive() {
  tg_send "Sincronizando modelos via rclone"
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
    ["${RCLONE_REMOTE_ROOT}/models/upscale_models"]="${COMFYUI_DIR}/models/upscale_models"
  )

  for SRC in "${!MAPS[@]}"; do
    DST="${MAPS[$SRC]}"
    mkdir -p "$DST"
    rclone ${RCLONE_COPY_CMD} "${RCLONE_REMOTE}:${SRC}" "${DST}" ${RCLONE_FLAGS} || true
  done

  local WF_LOCAL="${COMFYUI_DIR}/user/default/workflows"
  mkdir -p "$WF_LOCAL"
  #rclone ${RCLONE_COPY_CMD} "/ComfyUI/user/workflows" "${WF_LOCAL}" ${RCLONE_FLAGS} || true
  rclone copy "gdrive:/ComfyUI/user/workflows" "/workspace/ComfyUI/user/default/workflows"

  echo "Sincronização via rclone finalizada."
}

restore_snapshot_from_drive() {
  local dst_dir; dst_dir="$(dirname "${SNAPSHOT_LOCAL}")"
  mkdir -p "${dst_dir}"
  echo "Restaurando snapshot do Drive: ${RCLONE_REMOTE}:${SNAPSHOT_REMOTE} -> ${SNAPSHOT_LOCAL}"
  rclone copy "${RCLONE_REMOTE}:${SNAPSHOT_REMOTE}" "${dst_dir}" ${RCLONE_FLAGS} || true
  # Renomeia para current.json se veio com outro nome
  if [[ ! -f "${SNAPSHOT_LOCAL}" ]]; then
    local first_json
    first_json="$(ls -1 "${dst_dir}"/*.json 2>/dev/null | head -n1 || true)"
    [[ -n "${first_json}" ]] && mv -f "${first_json}" "${SNAPSHOT_LOCAL}" || true
  fi
  ln -sf "$(basename "${SNAPSHOT_LOCAL}")" "${dst_dir}/latest.json" || true
}

# ================================================================================================
# COMFY-CLI ISOLADO
# ================================================================================================
COMFYCLI_VENV=/venv/comfycli
COMFY="${COMFYCLI_VENV}/bin/comfy"
comfy_bin() { echo "${COMFY}"; }


# ================================================================================================
# INSTALAÇÃO DO COMFYUI (APENAS VIA COMFY-CLI)
# ================================================================================================
is_valid_comfy_repo() {
  [[ -d "${COMFYUI_DIR}/.git" ]] || return 1
  local url; url="$(cd "${COMFYUI_DIR}" && git remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ comfyanonymous/ComfyUI ]] || return 1
}



# ================================================================================================
# DOWNLOADS DE MODELOS / WORKFLOWS
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
  local url="$1"; local outdir="$2"; local auth_token=""; local filename
  if [[ -n "${HF_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_token="$HF_TOKEN"
  elif [[ -n "${CIVITAI_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    auth_token="$CIVITAI_TOKEN"
  fi
  filename="$(basename "${url%%\?*}")"
  [[ -f "${outdir}/${filename}" ]] && { echo "Já existe: ${outdir}/${filename} — pulando download."; return 0; }
  mkdir -p "$outdir"
  if [[ -n $auth_token ]]; then
    wget --header="Authorization: Bearer $auth_token" -nv --no-clobber --trust-server-names --content-disposition \
         --tries=3 --retry-connrefused --timeout=30 -P "$outdir" "$url"
  else
    wget -nv --no-clobber --trust-server-names --content-disposition \
         --tries=3 --retry-connrefused --timeout=30 -P "$outdir" "$url"
  fi
}

# ================================================================================================
# HELPERS
# ================================================================================================
provisioning_has_valid_hf_token() {
  [[ -n "${HF_TOKEN:-}" ]] || return 1
  local code
  code=$(curl -o /dev/null -s -w "%{http_code}" -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/whoami-v2)
  [[ "$code" -eq 200 ]]
}


install_comfy_cli_isolado() {
  #echo "Instalando comfy-cli em venv isolado: ${COMFYCLI_VENV}"
 # python -m venv "${COMFYCLI_VENV}"
  pip install comfy-cli
  #//"${COMFYCLI_VENV}/bin/pip" install "${PIP_QUIET_OPTS[@]}" --upgrade pip
 # "${COMFYCLI_VENV}/bin/pip" install "${PIP_QUIET_OPTS[@]}" --no-cache-dir comfy-cli

  # Pacotes extras (sem barulho)
  #"${COMFYCLI_VENV}/bin/pip" install "${PIP_QUIET_OPTS[@]}" "sageattention" "deepdiff" "aiohttp" "huggingface-hub" "toml" "torchvision"

  [[ -d /venv/main/bin ]] && ln -sf "${COMFY}" /venv/main/bin/ || true
}

configure_comfy_cli_isolado() {
  # NOTE: set-default feito uma única vez com extras; tracking desativado
  "${COMFY}" tracking disable || true
  "${COMFY}" set-default "/workspace/ComfyUI" --launch-extras="${COMFY_LAUNCH_EXTRAS}" || true
  #"${COMFY}" set-default "${COMFYUI_DIR}" --launch-extras="${COMFY_LAUNCH_EXTRAS}" || true

 # [[ -n "${HF_TOKEN:-}" ]]      && "${COMFY}" set-default --hf-api-token "$HF_TOKEN" || true
  #[[ -n "${CIVITAI_TOKEN:-}" ]] && "${COMFY}" set-default --civitai-api-token "$CIVITAI_TOKEN" || true
}




# ================================================================================================
# FLUXO PRINCIPAL
# ================================================================================================
provisioning_print_header() {
  printf "\n##############################################\n#          Provisioning container            #\n##############################################\n\n"
}
provisioning_print_end() { printf "\nProvisioning complete.\n\n"; }

provisioning_get_apt_packages() {
  if [[ ${#APT_PACKAGES[@]} -gt 0 ]] && command -v apt-get >/dev/null 2>&1; then
    apt-get "${APT_QUIET_OPTS[@]}" update -y
    apt-get "${APT_QUIET_OPTS[@]}" install -y "${APT_PACKAGES[@]}"
  fi
}
provisioning_get_pip_packages() {
  if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
    pip install "${PIP_QUIET_OPTS[@]}" --no-cache-dir "${PIP_PACKAGES[@]}"
  fi
}
provisioning_get_nodes() {
  echo "Obtendo custom nodes.."
  for repo in "${NODES[@]}"; do
    dir="${repo##*/}"; path="${COMFYUI_DIR}/custom_nodes/${dir}"; requirements="${path}/requirements.txt"
    if [[ -d $path ]]; then
      if [[ "${AUTO_UPDATE:-true}" != "false" ]]; then
        ( cd "$path" && git pull "${GIT_QUIET_OPTS[@]}" )
        [[ -e $requirements ]] && pip install "${PIP_QUIET_OPTS[@]}" --no-cache-dir -r "$requirements"
      fi
    else
      git clone "${GIT_QUIET_OPTS[@]}" --depth 1 --filter=blob:none "${repo}" "${path}" --recursive
      [[ -e $requirements ]] && pip install "${PIP_QUIET_OPTS[@]}" --no-cache-dir -r "${requirements}"
    fi
  done
}

provisioning_start() {
  provisioning_print_header
  notify_start

  ensure_tooling

  # Espelha CIVITAI_TOKEN em CIVITAI_API_TOKEN se existir
  [[ -n "${CIVITAI_TOKEN:-}" ]] && export CIVITAI_API_TOKEN="$CIVITAI_TOKEN"

  # Estrutura de diretórios base
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
    "${COMFYUI_DIR}/custom_nodes" \
    "$(dirname "${SNAPSHOT_LOCAL}")"

  tg_send "Instalando comfy-cli"
  # 1) comfy-cli isolado + config (não-interativo; tracking off)
  install_comfy_cli_isolado
  tg_send "Comfigurandp comfy-cli"
  configure_comfy_cli_isolado

  # 2) instalar ComfyUI (não-interativo; sem fallback)

  tg_send "Instalando e configurando Rclone"
  # 3) rclone + sync de artefatos (pouco verboso)
  ensure_rclone
  rclone_sync_from_drive

  tg_send "Restaurando Snapshots"

  # 4) restaurar snapshot do Drive e aplicar no workspace
  restore_snapshot_from_drive
  "${COMFY}" --skip-prompt --workspace="${COMFYUI_DIR}" node restore-snapshot "${SNAPSHOT_LOCAL}" || true
  "${COMFY}" node update all

  tg_send "Instalando Nodes"
  # 5) nodes e pacotes adicionais
  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # 6) FLUX dev/schnell e downloads faltantes
  local workflows_dir="${COMFYUI_DIR}/user/default/workflows"



  provisioning_get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/vae"  "${VAE_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/clip" "${CLIP_MODELS[@]}"

  ((${#LORAS_MODELS[@]}))        && provisioning_get_files "${COMFYUI_DIR}/models/loras"            "${LORAS_MODELS[@]}"        || echo "Sem Loras"
  ((${#UPSCALER_MODELS[@]}))     && provisioning_get_files "${COMFYUI_DIR}/models/upscale_models"   "${UPSCALER_MODELS[@]}"     || echo "Sem Upscaler"
  ((${#CHECKPOINTS_MODELS[@]}))  && provisioning_get_files "${COMFYUI_DIR}/models/checkpoints"      "${CHECKPOINTS_MODELS[@]}"  || echo "Sem Checkpoints"
  ((${#DIFFUSION_MODELS[@]}))    && provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"    || echo "Sem Diffusion"
  ((${#TEXT_ENCODERS_MODELS[@]}))&& provisioning_get_files "${COMFYUI_DIR}/models/text_encoders"    "${TEXT_ENCODERS_MODELS[@]}"|| echo "Sem Text Encoders"

  notify_end_success
  provisioning_print_end
}

if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi