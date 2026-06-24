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
  BASE_URL="https://${OLLAMA_HOST}"
  RESPONSE=$(curl -sS --max-time 10 "${BASE_URL}/api/tags" 2>/dev/null || true)
fi

if [ -z "$RESPONSE" ]; then
  err "Cannot reach Ollama at ${BASE_URL}/api/tags
  ─ Make sure Ollama is running on the remote machine
  ─ Check that OLLAMA_HOST is set correctly (default port 11434)
  ─ Verify network connectivity (firewall / VPN)"
fi

# Parse model info from /api/tags: name|has_completion|has_tools|size_gb
# Uses capabilities[] when available (Ollama ≥0.6), else "unknown"
# Extracts size from details.parameter_size (e.g. "8.0B", "873.44M")
MODELS_DATA=$(
  echo "$RESPONSE" | python3 -c "
import json, sys, re

def parse_size(param_size):
    if not param_size:
        return ''
    param_size = param_size.strip()
    m = re.match(r'([0-9]+(?:\\.[0-9]+)?)\\s*([BbMm])', param_size)
    if not m:
        return ''
    val = float(m.group(1))
    unit = m.group(2).lower()
    if unit == 'm':
        val = val / 1000
    return f'{val:.4f}'

data = json.load(sys.stdin)
for m in data.get('models', []):
    if 'remote_host' in m:
        continue
    name = m['name']
    caps = m.get('capabilities', None)
    has_comp = 'unknown'
    has_tools = 'unknown'
    if caps is not None and isinstance(caps, list):
        has_comp = 'yes' if 'completion' in caps else 'no'
        has_tools = 'yes' if 'tools' in caps else 'no'
    size = parse_size(m.get('details', {}).get('parameter_size', ''))
    print(f'{name}|{has_comp}|{has_tools}|{size}')
  " 2>/dev/null
)

if [ -z "$MODELS_DATA" ]; then
  MODELS_DATA=$(echo "$RESPONSE" | jq -r '.models[] | select(.remote_host | not) | "\(.name)|\(if .capabilities then if .capabilities | index("completion") then "yes" else "no" end else "unknown" end)|\(if .capabilities then if .capabilities | index("tools") then "yes" else "no" end else "unknown" end)|\(.details.parameter_size // "")"' 2>/dev/null || true)
fi

if [ -z "$MODELS_DATA" ]; then
  err "No models found at ${BASE_URL}
  Raw response: $(echo "$RESPONSE" | head -c 200)"
fi

# ── parse into arrays ─────────────────────────────────────
declare -a ALL_MODELS MODEL_TYPES MODEL_TOOLS MODEL_SIZES
while IFS='|' read -r name has_comp has_tools size_gb; do
    [ -z "$name" ] && continue
    ALL_MODELS+=("$name")
    if [ "$has_comp" = "yes" ]; then
        MODEL_TYPES+=("generative")
    elif [ "$has_comp" = "no" ]; then
        MODEL_TYPES+=("embedding")
    else
        MODEL_TYPES+=("unknown")
    fi
    if [ "$has_tools" = "yes" ]; then
        MODEL_TOOLS+=("yes")
    else
        MODEL_TOOLS+=("no")
    fi
    MODEL_SIZES+=("$size_gb")
done <<< "$MODELS_DATA"

total=${#ALL_MODELS[@]}

# ── fallback: inspect unknown models via /api/show ────────
inspect_model() {
  local m="$1"
  local host="$2"

  local resp
  resp=$(curl -sS --max-time 10 \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"$m\"}" \
    "${host}/api/show" 2>/dev/null || true)

  if [ -z "$resp" ]; then
    echo "unknown|no"
    return
  fi

  echo "$resp" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    t = data.get('template', '')
    has_tmpl = 'yes' if t and t.strip() else 'no'
    has_tools = 'yes' if '.Tools' in t or '.ToolCalls' in t else 'no'
    if has_tmpl == 'yes':
        print('generative|' + has_tools)
    else:
        print('embedding|' + has_tools)
except:
    print('unknown|no')
" 2>/dev/null || echo "unknown|no"
}

NEEDS_INSPECT=false
for ((i=0; i<total; i++)); do
    [ "${MODEL_TYPES[$i]}" = "unknown" ] && { NEEDS_INSPECT=true; break; }
done

if [ "$NEEDS_INSPECT" = true ]; then
    log "Some models missing capabilities — inspecting via /api/show …"
    for ((idx=0; idx<total; idx++)); do
        [ "${MODEL_TYPES[$idx]}" != "unknown" ] && continue
        m="${ALL_MODELS[$idx]}"
        progress="\033[1;32m›\033[0m /api/show [%02d/%02d] %s\033[K"
        printf "\r${progress}" "$((idx+1))" "$total" "$m" >&2
        result=$(inspect_model "$m" "$BASE_URL")
        IFS='|' read -r type tools <<< "$result"
        MODEL_TYPES[$idx]="$type"
        MODEL_TOOLS[$idx]="$tools"
    done
    printf "\r\033[K" >&2
fi

# ── group by type and tools ──────────────────────────────
GEN_INDICES=()
EMB_INDICES=()
TOOLS_INDICES=()
for ((i=0; i<total; i++)); do
  case "${MODEL_TYPES[$i]}" in
    generative)
      GEN_INDICES+=($i)
      [ "${MODEL_TOOLS[$i]}" = "yes" ] && TOOLS_INDICES+=($i)
      ;;
    *) EMB_INDICES+=($i) ;;
  esac
done

GEN_COUNT=${#GEN_INDICES[@]}
EMB_COUNT=${#EMB_INDICES[@]}
TOOLS_COUNT=${#TOOLS_INDICES[@]}

# ── size helper (returns GB as float) ─────────────────────
get_size_gb() {
  local idx=$1
  local fallback_size
  fallback_size="${MODEL_SIZES[$idx]}"
  if [ -n "$fallback_size" ]; then
    echo "$fallback_size"
    return
  fi
  # Fallback: parse model name
  local name="${ALL_MODELS[$idx]}"
  name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  local s
  s=$(echo "$name" | grep -oE '[0-9]+\.?[0-9]*[bm]' | head -1)
  [ -z "$s" ] && echo "999" && return
  local unit="${s: -1}"
  s="${s%[bm]}"
  case "$unit" in
    m) echo "scale=4; $s / 1000" | bc -l 2>/dev/null || echo "999" ;;
    *) echo "$s" ;;
  esac
}

# ── scoring-based selection ───────────────────────────────
# Scores a model by capabilities, type, and size.
score_model() {
  local idx=$1
  local name="${ALL_MODELS[$idx]}"
  local tools="${MODEL_TOOLS[$idx]}"

  local score=0

  # Tools support: biggest bonus
  [ "$tools" = "yes" ] && score=$((score + 20))

  # Code model bonus
  local clean="${name%":latest"}"
  if [[ "$clean" =~ (coder|ccode) ]]; then
    score=$((score + 5))
  fi

  # Hermes bonus (known for reliable tool calling)
  if [[ "$clean" =~ hermes ]]; then
    score=$((score + 5))
  fi

  # Size bonus: up to +10 (capped at ~10B params)
  local size
  size=$(get_size_gb "$idx")
  local size_int
  size_int=$(echo "$size / 1" | bc -l 2>/dev/null | cut -d. -f1)
  : "${size_int:=0}"
  [ "$size_int" -gt 10 ] && size_int=10
  score=$((score + size_int))

  echo "$score"
}

# Select the best model from a set of indices by score
select_best() {
  local -a indices=("$@")
  local count=${#indices[@]}
  [ $count -eq 0 ] && { echo ""; return; }

  local best_idx="${indices[0]}"
  local best_score=0
  local current_score

  for idx in "${indices[@]}"; do
    current_score=$(score_model "$idx")
    if [ "$current_score" -gt "$best_score" ]; then
      best_score="$current_score"
      best_idx="$idx"
    fi
  done

  echo "${ALL_MODELS[$best_idx]}"
}

# Select the smallest model from a set (excluding primary)
select_small() {
  local primary="$1"
  shift
  local -a indices=("$@")

  local small=""
  local small_size="9999"
  for idx in "${indices[@]}"; do
    local name="${ALL_MODELS[$idx]}"
    [ "$name" = "$primary" ] && continue
    local size
    size=$(get_size_gb "$idx")
    if [ "$(echo "$size < $small_size" | bc -l 2>/dev/null)" = "1" ]; then
      small_size="$size"
      small="$name"
    fi
  done

  [ -z "$small" ] && small="$primary"
  echo "$small"
}

# Sort indices by score descending (for display)
sort_by_score() {
  local -a indices=("$@")
  local -a scored
  for idx in "${indices[@]}"; do
    local s
    s=$(score_model "$idx")
    scored+=("$s|$idx")
  done
  IFS=$'\n' sorted=($(sort -t'|' -k1 -rn <<< "${scored[*]}"))
  unset IFS
  for entry in "${sorted[@]}"; do
    echo "${entry#*|}"
  done
}

PRIMARY=""
SMALL=""

# Prefer tools-capable models for primary
if [ $TOOLS_COUNT -gt 0 ]; then
  PRIMARY=$(select_best "${TOOLS_INDICES[@]}")
  SMALL=$(select_small "$PRIMARY" "${TOOLS_INDICES[@]}")
elif [ $GEN_COUNT -gt 0 ]; then
  warn "No generative model supports tools — using all generative models"
  PRIMARY=$(select_best "${GEN_INDICES[@]}")
  SMALL=$(select_small "$PRIMARY" "${GEN_INDICES[@]}")
elif [ $EMB_COUNT -gt 0 ]; then
  PRIMARY="${ALL_MODELS[${EMB_INDICES[0]}]}"
  SMALL="$PRIMARY"
fi

# ── interactive override ─────────────────────────────────
if [ -t 0 ] && [ $GEN_COUNT -gt 0 ]; then
  if [ $TOOLS_COUNT -gt 0 ]; then
    log "Models with tools (sorted by score):"
    declare -a SORTED_TOOLS
    SORTED_TOOLS=($(sort_by_score "${TOOLS_INDICES[@]}"))
    for ((i=0; i<TOOLS_COUNT; i++)); do
      idx="${SORTED_TOOLS[$i]}"
      name="${ALL_MODELS[$idx]}"
      s=$(score_model "$idx")
      marker=""
      [ "$name" = "$PRIMARY" ] && marker=" ←"
      printf "  %d. [%02d] %s${marker}\n" "$((i+1))" "$s" "$name" >&2
    done
    [ $((GEN_COUNT - TOOLS_COUNT)) -gt 0 ] && warn "$((GEN_COUNT - TOOLS_COUNT)) model(s) without tools (hidden)"
    log "Select primary [1-${TOOLS_COUNT}], or 0 to accept: "
    read -r ans
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$TOOLS_COUNT" ]; then
      selected_idx="${SORTED_TOOLS[$((ans-1))]}"
      PRIMARY="${ALL_MODELS[$selected_idx]}"
      SMALL=$(select_small "$PRIMARY" "${TOOLS_INDICES[@]}")
    fi
  else
    warn "Showing all generative models (none support tools)"
    for ((i=0; i<GEN_COUNT; i++)); do
      marker=""
      [ "${ALL_MODELS[${GEN_INDICES[$i]}]}" = "$PRIMARY" ] && marker=" ←"
      printf "  %d. %s${marker}\n" "$((i+1))" "${ALL_MODELS[${GEN_INDICES[$i]}]}" >&2
    done
    log "Select primary [1-${GEN_COUNT}], or 0 to accept: "
    read -r ans
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$GEN_COUNT" ]; then
      PRIMARY="${ALL_MODELS[${GEN_INDICES[$((ans-1))]}]}"
      SMALL=$(select_small "$PRIMARY" "${GEN_INDICES[@]}")
    fi
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
