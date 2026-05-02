#!/bin/bash
set -euo pipefail

# ================================================================================================
# BASIC ENVIRONMENT
# ================================================================================================
if [[ -d /venv/main/bin ]]; then
  # shellcheck disable=SC1091
  source /venv/main/bin/activate
fi

: "${WORKSPACE:=/workspace}"
: "${COMFYUI_DIR:=${WORKSPACE}/ComfyUI}"

# ================================================================================================
# HELPER: parse pipe-separated env var into a bash array
# Sets global array VARNAME; if VARNAME_ENV is set, it overrides; VARNAME_EXTRA appends.
# ================================================================================================
parse_env_array() {
  local varname="$1"
  local env_key="${varname}_ENV"
  local extra_key="${varname}_EXTRA"

  if [[ -n "${!env_key:-}" ]]; then
    IFS='|' read -ra "$varname" <<< "${!env_key}"
  fi

  if [[ -n "${!extra_key:-}" ]]; then
    local -a _extra
    IFS='|' read -ra _extra <<< "${!extra_key}"
    # nameref append (bash 4.3+)
    declare -n _ref="$varname"
    _ref+=("${_extra[@]}")
    unset -n _ref
  fi
}

# ================================================================================================
# CONFIGURATIONS (Arrays limpos - preenchidos puramente via *_ENV / *_EXTRA env vars)
# ================================================================================================
#: "${DOWNLOAD_GDRIVE_MODELS:=false}"

APT_PACKAGES=()
PIP_PACKAGES=()
NODES=()
CHECKPOINTS_MODELS=()
TEXT_ENCODERS_MODELS=()
UNET_MODELS=()
VAE_MODELS=()
CLIP_MODELS=()
LORAS_MODELS=()
UPSCALER_MODELS=()
DIFFUSION_MODELS=()
WORKFLOWS=()

# Apply env overrides / extras for every array
parse_env_array APT_PACKAGES
parse_env_array PIP_PACKAGES
parse_env_array NODES
parse_env_array CHECKPOINTS_MODELS
parse_env_array TEXT_ENCODERS_MODELS
parse_env_array UNET_MODELS
parse_env_array VAE_MODELS
parse_env_array CLIP_MODELS
parse_env_array LORAS_MODELS
parse_env_array UPSCALER_MODELS
parse_env_array DIFFUSION_MODELS
parse_env_array WORKFLOWS

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
  PROVISION_START_TS="$(date +%s)"
  local host msg
  host="$(hostname | tg_escape_html)"
  msg="🚀 <b>Provisioning iniciado</b>\nHost: <code>${host}</code>\nHora: <code>$(date -Iseconds)</code>"
  tg_send "$msg"
}

notify_end_success() {
  local end_ts dur host msg
  end_ts="$(date +%s)"
  dur="$(( end_ts - PROVISION_START_TS ))"
  host="$(hostname | tg_escape_html)"
  msg="✅ <b>Provisioning concluído</b>\nHost: <code>${host}</code>\nDuração: <code>${dur}s</code>\nHora: <code>$(date -Iseconds)</code>"
  tg_send "$msg"
}

notify_end_failure() {
  local code="$?"
  local host msg
  host="$(hostname | tg_escape_html)"
  msg="❌ <b>Provisioning falhou</b>\nHost: <code>${host}</code>\nCódigo: <code>${code}</code>\nHora: <code>$(date -Iseconds)</code>"
  tg_send "$msg"
  exit "$code"
}
trap notify_end_failure ERR

# ================================================================================================
# UTILITIES / PRE-REQS
# ================================================================================================
ensure_tooling() {
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl; fi
  fi
  if ! command -v wget >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y wget; fi
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y unzip; fi
  fi
  if ! command -v git >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y git; fi
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y coreutils; fi
  fi
  command -v sed >/dev/null 2>&1 || true
}

# ================================================================================================
# RCLONE
# ================================================================================================
: "${RCLONE_CONF_BASE64:=}"
: "${RCLONE_REMOTE:=gdrive}"
: "${RCLONE_REMOTE_ROOT:=/ComfyUI}"
: "${RCLONE_REMOTE_WORKFLOWS_SUBDIR:=/workflows}"
: "${RCLONE_COPY_CMD:=copy}"
: "${RCLONE_FLAGS:=--progress --checkers=8 --transfers=4 --drive-chunk-size=128M --fast-list}"
: "${RCLONE_CONFIG_DIR:=${HOME:-/root}/.config/rclone}"

ensure_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo "rclone not found; trying to install..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y rclone || true
    fi
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    echo "apt install failed; downloading binary..."
    curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/rclone.zip
    command -v unzip >/dev/null 2>&1 || (apt-get update -y && apt-get install -y unzip || true)
    unzip -q /tmp/rclone.zip -d /tmp
    RCDIR=$(find /tmp -maxdepth 1 -type d -name "rclone-*-linux-amd64" | head -n1)
    install -m 0755 "$RCDIR/rclone" /usr/local/bin/rclone
    rm -rf /tmp/rclone.zip "$RCDIR"
  fi

  if [[ -n "${RCLONE_CONF_BASE64:-}" ]]; then
    echo "Creating rclone.conf from base64 environment variable..."
    mkdir -p "${RCLONE_CONFIG_DIR}"
    echo "${RCLONE_CONF_BASE64}" | base64 -d > "${RCLONE_CONFIG_DIR}/rclone.conf"
    chmod 600 "${RCLONE_CONFIG_DIR}/rclone.conf"
    echo "rclone.conf saved to ${RCLONE_CONFIG_DIR}/rclone.conf"
  else
    echo "No RCLONE_CONF_BASE64 provided. Skipping custom config."
  fi

  if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:"; then
    echo "ERROR: remote '${RCLONE_REMOTE}:' not found in rclone.conf."
    rclone listremotes || true
    exit 1
  fi
}

rclone_sync_from_drive() {
  echo "Syncing artifacts from Google Drive (${RCLONE_REMOTE})..."

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
    # shellcheck disable=SC2086
    rclone ${RCLONE_COPY_CMD} "${RCLONE_REMOTE}:${SRC}" "${DST}" ${RCLONE_FLAGS} || true
  done

  local WF_LOCAL
  WF_LOCAL="${COMFYUI_DIR}/user/default/workflows"
  mkdir -p "$WF_LOCAL"
  echo "rclone ${RCLONE_COPY_CMD} ${RCLONE_REMOTE}:${RCLONE_REMOTE_ROOT}${RCLONE_REMOTE_WORKFLOWS_SUBDIR} -> ${WF_LOCAL}"
  # shellcheck disable=SC2086
  rclone ${RCLONE_COPY_CMD} "${RCLONE_REMOTE}:${RCLONE_REMOTE_ROOT}${RCLONE_REMOTE_WORKFLOWS_SUBDIR}" "${WF_LOCAL}" ${RCLONE_FLAGS} || true

  echo "rclone sync finished."
}

# ================================================================================================
# ISOLATED COMFY-CLI
# ================================================================================================
COMFYCLI_VENV=/venv/comfycli
comfy_bin() { echo "${COMFYCLI_VENV}/bin/comfy"; }

install_comfy_cli_isolado() {
  echo "Installing comfy-cli in isolated venv: ${COMFYCLI_VENV}"
  python -m venv "${COMFYCLI_VENV}"
  "${COMFYCLI_VENV}/bin/pip" install --upgrade pip
  "${COMFYCLI_VENV}/bin/pip" install --no-cache-dir comfy-cli
}

configure_comfy_cli_isolado() {
  echo "Configuring comfy-cli (set-default or fallback cli.toml) in isolated venv..."
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
    if [[ -n "${HF_TOKEN:-}" ]]; then "$COMFY" set-default --hf-api-token "$HF_TOKEN" || true; fi
    if [[ -n "${CIVITAI_TOKEN:-}" ]]; then "$COMFY" set-default --civitai-api-token "$CIVITAI_TOKEN" || true; fi
    set -e
  else
    echo "Subcommand 'set-default' unavailable; using fallback ~/.config/comfy/cli.toml"
    local CFG_DIR="${HOME:-/root}/.config/comfy"
    local CFG_FILE="${CFG_DIR}/cli.toml"
    mkdir -p "$CFG_DIR"
    cat > "$CFG_FILE" <<EOF
# Auto-generated
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
# PROVISIONING
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
      apt-get update -y
      apt-get install -y "${APT_PACKAGES[@]}"
    else
      echo "apt not available; skipping APT_PACKAGES."
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
    path="${COMFYUI_DIR}/custom_nodes/${dir}"
    requirements="${path}/requirements.txt"
    if [[ -d $path ]]; then
      if [[ "${AUTO_UPDATE:-true}" != "false" ]]; then
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

provisioning_get_files() {
  if [[ -z ${2:-} ]]; then return 1; fi
  local dir="$1"; shift
  local arr=("$@")
  mkdir -p "$dir"
  printf "Checking/downloading %s file(s) to %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Processing: %s\n" "${url}"
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
    echo "Already exists: ${outdir}/${filename} — skipping download."
    return 0
  fi

  mkdir -p "$outdir"
  if [[ -n $auth_token ]]; then
    wget --header="Authorization: Bearer $auth_token" -qnc --trust-server-names --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$outdir" "$url"
  else
    wget -qnc --trust-server-names --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$outdir" "$url"
  fi
}

provisioning_start() {
  provisioning_print_header
  notify_start

  ensure_tooling

  if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
    export CIVITAI_API_TOKEN="$CIVITAI_TOKEN"
  fi

  # Verify workspace is writable before attempting any mkdir
  if ! mkdir -p "${WORKSPACE}" 2>/dev/null; then
    echo ""
    echo "ERROR: Cannot create workspace at '${WORKSPACE}' (read-only or no permission)."
    echo "       Set WORKSPACE to a writable path before running:"
    echo "         WORKSPACE=/tmp/comfytest bash auto_conf.sh"
    echo "       Or via Python launcher:"
    echo "         WORKSPACE=/tmp/comfytest python run_provisioning.py"
    echo ""
    exit 1
  fi

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

  # 1) rclone + Drive sync
  ensure_rclone
  # rclone_sync_from_drive

  # 2) packages, nodes, pip
  provisioning_get_apt_packages
  provisioning_get_nodes
  provisioning_get_pip_packages

  # 3) isolated comfy-cli
  install_comfy_cli_isolado
  configure_comfy_cli_isolado
  "$(comfy_bin)" --version || true
  "$(comfy_bin)" config show || true

  # 4) Download Files from ENV variables
  local workflows_dir="${COMFYUI_DIR}/user/default/workflows"
  if ((${#WORKFLOWS[@]})); then
    provisioning_get_files "${workflows_dir}" "${WORKFLOWS[@]}"
  fi

  if ((${#UNET_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/unet" "${UNET_MODELS[@]}"
  fi

  if ((${#VAE_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/vae"  "${VAE_MODELS[@]}"
  fi

  if ((${#CLIP_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/clip" "${CLIP_MODELS[@]}"
  fi

  if ((${#LORAS_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/loras" "${LORAS_MODELS[@]}"
  fi

  if ((${#UPSCALER_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/upscale_models" "${UPSCALER_MODELS[@]}"
  fi

  if ((${#CHECKPOINTS_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints" "${CHECKPOINTS_MODELS[@]}"
  fi

  if ((${#DIFFUSION_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
  fi

  if ((${#TEXT_ENCODERS_MODELS[@]})); then
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODERS_MODELS[@]}"
  fi

  provisioning_print_end
  notify_end_success
}

if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi