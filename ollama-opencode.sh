#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
# ollama-opencode.sh
#
# Scan a remote Ollama instance for available models,
# generate opencode.json with the correct provider config,
# and optionally launch opencode.
#
# Usage:
#   ./ollama-opencode.sh [OLLAMA_HOST] [options]
#
# Examples:
#   ./ollama-opencode.sh                        # prompt for host interactively
#   ./ollama-opencode.sh 192.168.1.50           # scan & generate config
#   ./ollama-opencode.sh 192.168.1.50 --launch  # scan, generate, launch opencode
#   ./ollama-opencode.sh 192.168.1.50:11434     # with explicit port
# ──────────────────────────────────────────────────────────

LAUNCH=false
OLLAMA_HOST=""

# Determine config file path (absolute)
if [ -n "${OPENCODE_CONFIG:-}" ]; then
  CONFIG_FILE="$OPENCODE_CONFIG"
else
  CONFIG_FILE="$(cd "$(dirname "$0")" && pwd)/opencode.json"
fi

# ── helpers ───────────────────────────────────────────────
usage() {
  sed -n '/^# ──/,/^# ──/p' "$0" | grep '^#  ' | sed 's/^# //'
  exit 0
}

log()  { printf "\033[1;32m›\033[0m %s\n" "$*" >&2; }
warn() { printf "\033[1;33m›\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m›\033[0m %s\n" "$*" >&2; exit 1; }

clean_name() {
  local n="$1"
  n="${n%":latest"}"
  echo "$n"
}

# ── parse args ────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --launch) LAUNCH=true ;;
    --help|-h) usage ;;
    *) OLLAMA_HOST="$arg" ;;
  esac
done

# ── discover Ollama host ──────────────────────────────────
if [ -z "$OLLAMA_HOST" ]; then
  read -rp "Ollama host (IP or hostname) [192.168.1.100]: " ans
  OLLAMA_HOST="${ans:-192.168.1.100}"
fi

# Strip protocol prefix if accidentally pasted
OLLAMA_HOST="${OLLAMA_HOST#http://}"
OLLAMA_HOST="${OLLAMA_HOST#https://}"

# Add port if missing
if [[ "$OLLAMA_HOST" != *:* ]]; then
  OLLAMA_HOST="${OLLAMA_HOST}:11434"
fi

BASE_URL="http://${OLLAMA_HOST}"

# Determine provider name based on host
HOST_ONLY="${OLLAMA_HOST%:*}"
if [[ "$HOST_ONLY" =~ ^(localhost|127\.0\.0\.1|0\.0\.0\.0)$ ]]; then
  PROVIDER_ID="local"
  PROVIDER_NAME="Local Ollama"
else
  PROVIDER_ID="ollama-srv"
  PROVIDER_NAME="Ollama (${HOST_ONLY})"
fi

log "Scanning Ollama at ${BASE_URL} …"

# ── fetch model list ──────────────────────────────────────
RESPONSE=$(curl -sS --max-time 10 "${BASE_URL}/api/tags" 2>/dev/null || true)

if [ -z "$RESPONSE" ]; then
  # Fallback: try https
  BASE_URL="https://${OLLAMA_HOST}"
  RESPONSE=$(curl -sS --max-time 10 "${BASE_URL}/api/tags" 2>/dev/null || true)
fi

if [ -z "$RESPONSE" ]; then
  err "Cannot reach Ollama at ${BASE_URL}/api/tags
  ─ Make sure Ollama is running on the remote machine
  ─ Check that OLLAMA_HOST is set correctly (default port 11434)
  ─ Verify network connectivity (firewall / VPN)"
fi

# Parse model names from JSON response using python3 or jq
MODELS=$(
  echo "$RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('models', []):
    # skip remote-only models (they have a remote_host)
    if 'remote_host' not in m:
        print(m['name'])
  " 2>/dev/null
)

if [ -z "$MODELS" ]; then
  # fallback: try jq
  MODELS=$(echo "$RESPONSE" | jq -r '.models[] | select(.remote_host | not) | .name' 2>/dev/null || true)
fi

if [ -z "$MODELS" ]; then
  err "No local models found at ${BASE_URL}
  Raw response: $(echo "$RESPONSE" | head -c 200)"
fi

# ── display & select ─────────────────────────────────────
COUNT=$(echo "$MODELS" | grep -c . || true)
log "Found ${COUNT} model(s):"
i=0
echo "$MODELS" | while read -r m; do
  ((++i))
  [ $i -eq 1 ] && first=1
  printf "  \033[1;36m%02d.\033[0m %s\n" "$i" "$m"
done && echo

# ── detect model type via /api/show ───────────────────────────
detect_type() {
  local m="$1"
  local host="$2"

  local resp
  resp=$(curl -sS --max-time 5 \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"$m\"}" \
    "${host}/api/show" 2>/dev/null || true)

  if [ -z "$resp" ]; then
    echo "unknown"
    return
  fi

  local has_template
  has_template=$(echo "$resp" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    t = data.get('template', '')
    print('yes' if t and t.strip() else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

  if [ "$has_template" = "yes" ]; then
    echo "generative"
  else
    echo "embedding"
  fi
}

# ── classify models ──────────────────────────────────────────
log "Inspecting models via /api/show …"

declare -a ALL_MODELS
declare -a MODEL_TYPES

while IFS= read -r m; do
  [ -z "$m" ] && continue
  ALL_MODELS+=("$m")
done <<< "$MODELS"

total=${#ALL_MODELS[@]}
for ((idx=0; idx<total; idx++)); do
  m="${ALL_MODELS[$idx]}"
  printf "\033[1;32m›\033[0m [%02d/%02d] Checking %s …\r" "$((idx+1))" "$total" "$m" >&2
  type=$(detect_type "$m" "$BASE_URL")
  MODEL_TYPES+=("$type")
done
printf "\033[K" >&2
echo >&2

log "Results:"
for ((i=0; i<total; i++)); do
  color="\033[1;36m"
  [ "${MODEL_TYPES[$i]}" = "embedding" ] && color="\033[1;33m"
  [ "${MODEL_TYPES[$i]}" = "unknown" ] && color="\033[1;31m"
  printf "  ${color}%02d.\033[0m %s \033[2m(%s)\033[0m\n" \
    "$((i+1))" "${ALL_MODELS[$i]}" "${MODEL_TYPES[$i]}"
done
echo >&2

# ── group by type ────────────────────────────────────────────
GEN_INDICES=()
EMB_INDICES=()
for ((i=0; i<total; i++)); do
  case "${MODEL_TYPES[$i]}" in
    generative) GEN_INDICES+=($i) ;;
    *)          EMB_INDICES+=($i) ;;
  esac
done

GEN_COUNT=${#GEN_INDICES[@]}
EMB_COUNT=${#EMB_INDICES[@]}

# ── size helpers ──────────────────────────────────────────────
get_size() {
  local name="$1"
  local s
  s=$(echo "$name" | grep -oE '[0-9]+\.?[0-9]*b' | head -1)
  [ -z "$s" ] && echo "999" && return
  echo "${s%b}"
}

# ── auto-select primary ──────────────────────────────────────
select_primary() {
  local -a indices=("$@")
  local count=${#indices[@]}
  [ $count -eq 0 ] && { echo ""; return; }

  # Pass 1: code model (coder, ccode)
  for idx in "${indices[@]}"; do
    local name="${ALL_MODELS[$idx]}"
    local clean="${name%":latest"}"
    if [[ "$clean" =~ (coder|ccode) ]]; then
      echo "${ALL_MODELS[$idx]}"
      return
    fi
  done

  # Pass 2: largest by parameter size
  local best_name="${ALL_MODELS[${indices[0]}]}"
  local best_size=$(get_size "$best_name")
  for idx in "${indices[@]}"; do
    local name="${ALL_MODELS[$idx]}"
    local size=$(get_size "$name")
    if [ "$(echo "$size > $best_size" | bc -l 2>/dev/null)" = "1" ]; then
      best_size="$size"
      best_name="$name"
    fi
  done

  echo "$best_name"
}

select_small() {
  local primary="$1"
  shift
  local -a indices=("$@")
  local count=${#indices[@]}

  local small=""
  local small_size="9999"
  for idx in "${indices[@]}"; do
    local name="${ALL_MODELS[$idx]}"
    [ "$name" = "$primary" ] && continue
    local size=$(get_size "$name")
    if [ "$(echo "$size < $small_size" | bc -l 2>/dev/null)" = "1" ]; then
      small_size="$size"
      small="$name"
    fi
  done

  [ -z "$small" ] && small="$primary"
  echo "$small"
}

PRIMARY=""
SMALL=""

if [ $GEN_COUNT -gt 0 ]; then
  PRIMARY=$(select_primary "${GEN_INDICES[@]}")
  SMALL=$(select_small "$PRIMARY" "${GEN_INDICES[@]}")
elif [ $EMB_COUNT -gt 0 ]; then
  PRIMARY="${ALL_MODELS[${EMB_INDICES[0]}]}"
  SMALL="$PRIMARY"
fi

# ── interactive override ─────────────────────────────────────
if [ -t 0 ] && [ $GEN_COUNT -gt 0 ]; then
  echo >&2
  log "Generative models:"
  for ((i=0; i<GEN_COUNT; i++)); do
    marker=""
    [ "${ALL_MODELS[${GEN_INDICES[$i]}]}" = "$PRIMARY" ] && marker=" \033[1;32m← primary\033[0m"
    log "    $(printf "%3d." $((i+1))) ${ALL_MODELS[${GEN_INDICES[$i]}]}${marker}"
  done
  log "Select primary model index [1-${GEN_COUNT}], or 0 to accept defaults: "
  read -r ans
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$GEN_COUNT" ]; then
    PRIMARY="${ALL_MODELS[${GEN_INDICES[$((ans-1))]}]}"
    SMALL=$(select_small "$PRIMARY" "${GEN_INDICES[@]}")
  fi
fi

# ── write config ──────────────────────────────────────────
log "Generating ${CONFIG_FILE} …"

MODELS_TMP=$(mktemp)
trap "rm -f $MODELS_TMP" EXIT
for ((i=0; i<total; i++)); do
  if [ "${MODEL_TYPES[$i]}" = "generative" ]; then
    echo "${ALL_MODELS[$i]}" >> "$MODELS_TMP"
  fi
done

export OC_PROVIDER_ID="$PROVIDER_ID"
export OC_PROVIDER_NAME="$PROVIDER_NAME"
export OC_BASE_URL="${BASE_URL}/v1"
export OC_PRIMARY="$PRIMARY"
export OC_SMALL="$SMALL"
export OC_MODELS_FILE="$MODELS_TMP"

python3 -c "
import json, os

with open(os.environ['OC_MODELS_FILE']) as f:
    models = [line.strip() for line in f if line.strip()]

config = {
    '\$schema': 'https://opencode.ai/config.json',
    'model': os.environ['OC_PROVIDER_ID'] + '/' + os.environ['OC_PRIMARY'],
    'small_model': os.environ['OC_PROVIDER_ID'] + '/' + os.environ['OC_SMALL'],
    'provider': {
        os.environ['OC_PROVIDER_ID']: {
            'npm': '@ai-sdk/openai-compatible',
            'name': os.environ['OC_PROVIDER_NAME'],
            'options': {
                'baseURL': os.environ['OC_BASE_URL']
            },
            'models': {m: {'name': m} for m in models}
        }
    }
}

print(json.dumps(config, indent=2))
" > "$CONFIG_FILE"

log "Wrote ${CONFIG_FILE}"
echo "  model:       ${PROVIDER_ID}/${PRIMARY}" >&2
echo "  small_model: ${PROVIDER_ID}/${SMALL}" >&2
echo "  baseURL:     ${BASE_URL}/v1" >&2
echo "  provider:    ${PROVIDER_NAME}" >&2
echo "  models in config: all generative models" >&2
echo >&2

# ── launch ────────────────────────────────────────────────
if [ "$LAUNCH" = true ]; then
  if command -v opencode &>/dev/null; then
    log "Launching opencode …"
    OPENCODE_CONFIG="$CONFIG_FILE" exec opencode
  else
    warn "opencode not found in PATH; check your installation"
  fi
else
  log "Done. Run opencode with this config:
  OPENCODE_CONFIG=${CONFIG_FILE} opencode"
fi
