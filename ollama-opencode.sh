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

# ── detect model type ────────────────────────────────────────────────
detect_type() {
  local m="$1"
  local name=$(clean_name "$m")
  # Check model name patterns
  if [[ "$name" =~ (llama|qwen|codellama|phi|granite|mistral) ]] && [[ "$name" != *embed* ]]; then
    echo "generative"
  elif [[ "$name" =~ (embed|nomic) ]]; then
    echo "embedding"
  elif [[ "$name" =~ coder ]]; then
    echo "generative"
  else
    echo "ambiguous"
  fi
}

# ── classify models ───────────────────────────────────────────────────
MODELS_WITH_TYPES=$(echo "$MODELS" | while read -r m; do echo "0\t$m"; done | paste -d'\t' <(seq 1 1))
CLASSIFIED=$(echo "$MODELS_WITH_TYPES" | while IFS=$'\t' read -r idx m; do
  type=$(detect_type "$m")
  case "$type" in
    generative) echo "$idx\tgenerative\t$m" ;;
    embedding) echo "$idx\tembedding\t$m" ;;
    *)         echo "$idx\tambiguous\t$m" ;;
  esac
done)

# ── build indexed array ───────────────────────────────────────────────
declare -A TYPE_MAP
declare -a ALL_MODELS
idx=0
while IFS=$'\t' read -r i type name; do
  ALL_MODELS[$idx]="$name"
  TYPE_MAP[$idx]="$type"
  ((++idx))
done <<< "$CLASSIFIED"

# ── select models ────────────────────────────────────────────────────
# Generative model takes priority
GEN_INDICES=()
EMB_INDICES=()
for ((i=0; i<${#ALL_MODELS[@]}; i++)); do
  type="${TYPE_MAP[$i]}"
  case "$type" in
    generative) GEN_INDICES+=($i) ;;
    embedding) EMB_INDICES+=($i) ;;
  esac
done

# Auto-select primary: generative (prefer recent one)
if [[ $GEN_COUNT -gt 0 ]]; then
  # Prefer models with "3", "2", "latest" in the name (more recent)
  best_idx=0
  for ((i=0; i<GEN_COUNT; i++)); do
    curr_idx=$i
    [[ -z "${GEN_INDICES[$curr_idx]}" ]] && continue
    curr="${ALL_MODELS[${GEN_INDICES[$curr_idx]}]}"
    if [[ "$curr" == *"3"* || "$curr" == *"2"* || "$curr" == *"latest"* ]]; then
      # Check if this is the best so far
      best_idx=$curr_idx
    fi
  done
  PRIMARY="${ALL_MODELS[${GEN_INDICES[$best_idx]}]}"
else
  PRIMARY="${ALL_MODELS[${EMB_INDICES[0]}]}"
fi

# Select small: generative if possible, otherwise from embedding
SMALL_MODEL=""
SMALL_IDX=-1
for ((i=0; i<${#GEN_INDICES[@]}; i++)); do
  idx=${GEN_INDICES[$i]}
  if [[ $idx -ne $PRIMARY_IDX ]]; then
    SMALL="${ALL_MODELS[$idx]}"
    SMALL_IDX=$idx
    break
  fi
done
if [[ -z "$SMALL" ]] || [[ -1 == $SMALL_IDX ]]; then
  for ((i=0; i<${#EMB_INDICES[@]}; i++)); do
    idx=$i
    if [[ -z "$SMALL" ]]; then
      SMALL="${ALL_MODELS[$idx]}"
      SMALL_IDX=$idx
      break
    fi
  done
fi

# Allow interactive override with numeric index for generative models
if [ -t 0 ]; then
  GEN_COUNT=${#GEN_INDICES[@]}
  EMB_COUNT=${#EMB_INDICES[@]}
  if [ $GEN_COUNT -gt 0 ]; then
    log "Generative models (${GEN_COUNT}):"
    for ((i=0; i<GEN_COUNT; i++)); do
      log "    $(printf "%3d." $((i+1))) ${ALL_MODELS[${GEN_INDICES[$i]}]}"
    done
    log "Skip embeddings with ' (e.g. 'q' or 0): "
    read -r opts
    if ! [[ "$opts" == "q" || "$opts" == "0" ]]; then
      # User wants generative
      log "Select generative model index [1-${GEN_COUNT}]: "
      opt_idx=1
      read -r ans
      [[ ! "$ans" =~ ^[0-9]+$ ]] && { log "Invalid"; exit 0; }
      opt_idx=$((ans + 0))
      if [[ $opt_idx -lt 1 || $opt_idx -gt $GEN_COUNT ]]; then
        log "Invalid index (1-${GEN_COUNT})"
        exit 0
      fi
      PRIMARY="${ALL_MODELS[${GEN_INDICES[$((opt_idx-1))]}]}"
    else
      # User chose embeddings for small_model
      SMALL_IDX=$EMB_IDX=0
      for ((i=0; i<${#EMB_INDICES[@]}; i++)); do
        SMALL="${ALL_MODELS[${EMB_INDICES[$i]}]}"
        EMB_IDX=$i
        break
      done
      if [[ -z "$SMALL" ]]; then
        SMALL="${ALL_MODELS[${PRIMARY_IDX}]}"; EMB_IDX=$PRIMARY_IDX
      fi
    fi
  elif [ $EMB_COUNT -gt 0 ]; then
    log "No generative models found, using embedding: ${ALL_MODELS[${EMB_INDICES[0]}]}"
    PRIMARY="${ALL_MODELS[${EMB_INDICES[0]}]}"
    SMALL="${ALL_MODELS[${EMB_INDICES[0]}]:-}"
  fi
fi

# ── write config ──────────────────────────────────────────
log "Generating ${CONFIG_FILE} …"

cat > "$CONFIG_FILE" <<CONFEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "${PROVIDER_ID}/${PRIMARY}",
  "small_model": "${PROVIDER_ID}/${SMALL}",
  "provider": {
    "${PROVIDER_ID}": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "${PROVIDER_NAME}",
      "options": {
        "baseURL": "${BASE_URL}/v1"
      },
      "models": {
        "${PRIMARY}": {
          "name": "${PRIMARY}"
        },
        "${SMALL}": {
          "name": "${SMALL}"
        }
      }
    }
  }
}
CONFEOF

log "Wrote ${CONFIG_FILE}"
echo "  model:       ${PROVIDER_ID}/${PRIMARY}" >&2
echo "  small_model: ${PROVIDER_ID}/${SMALL}" >&2
echo "  baseURL:     ${BASE_URL}/v1" >&2
echo "  provider:    ${PROVIDER_NAME}" >&2
echo

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
