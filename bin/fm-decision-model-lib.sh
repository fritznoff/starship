# shellcheck shell=bash
# Shared shell entry for fm_decision_model.py.
# Usage: source this before launching children, then fm_decision_model --enabled
# or fm_decision_model --output FILE --timeout SECONDS < request.json.
# Capture private copies for the client descriptor, never secret argv.
# Preserve legacy handling of unrelated ambient credentials; the Python entry
# clears every provider key from curl's environment before sending its header.
FM_DECISION_TYPESAFE_PRIVATE=${TYPESAFE_API_KEY:-}
FM_DECISION_CLOUDFLARE_PRIVATE=${CLOUDFLARE_API_KEY:-}
FM_DECISION_OPENROUTER_PRIVATE=${OPENROUTER_API_KEY:-}
export -n FM_DECISION_TYPESAFE_PRIVATE FM_DECISION_CLOUDFLARE_PRIVATE FM_DECISION_OPENROUTER_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY
FM_DECISION_CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-env-lib.sh
. "$FM_DECISION_CLIENT_DIR/fm-env-lib.sh"

fm_decision_model() {
  local typesafe=$FM_DECISION_TYPESAFE_PRIVATE
  [ -n "$typesafe" ] || typesafe=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  python3 "$FM_DECISION_CLIENT_DIR/fm_decision_model.py" --home "$FM_HOME" --key-fd 3 "$@" \
    3< <(printf '%s\n' "$typesafe" "$FM_DECISION_CLOUDFLARE_PRIVATE" "$FM_DECISION_OPENROUTER_PRIVATE")
}
