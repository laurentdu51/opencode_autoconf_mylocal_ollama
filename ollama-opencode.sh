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
echo "$MODELS" | while read -r m; do
  printf "  \033[1;36m•\033[0m %s\n" "$m" >&2
done

echo

# Filter out embedding-only models
GENERATIVE_MODELS=$(echo "$MODELS" | grep -iv "embed\|nomic-embed" || true)
[ -z "$GENERATIVE_MODELS" ] && GENERATIVE_MODELS="$MODELS"

# Choose primary model (prefer code models)
PREFERRED=""
for kw in "coder" "code" "llama3" "qwen3" "qwen2" "tinyllama"; do
  candidate=$(echo "$GENERATIVE_MODELS" | grep -i "$kw" | head -1)
  [ -n "$candidate" ] && { PREFERRED=$(clean_name "$candidate"); break; }
done
PRIMARY="${PREFERRED:-$(echo "$GENERATIVE_MODELS" | head -1 | while read -r m; do clean_name "$m"; done)}"

# Small model: pick the smallest model by parameter size (heuristic via version sort on tag)
SMALL=$(echo "$GENERATIVE_MODELS" | while read -r m; do clean_name "$m"; done | sort -t: -k2 -V | head -1)

[ -z "$SMALL" ] && SMALL="$PRIMARY"

# Allow interactive override
if [ -t 0 ]; then
  log "Primary model   [${PRIMARY}]: "
  read -r ans; PRIMARY="${ans:-$PRIMARY}"

  log "Small model     [${SMALL}]: "
  read -r ans; SMALL="${ans:-$SMALL}"
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
