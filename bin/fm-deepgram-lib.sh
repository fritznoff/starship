#!/usr/bin/env bash
# Shared Deepgram and ElevenLabs helpers for desk speak-out and the desk
# floater.
#
# Source this file; do not execute it.
# Contract:
#   fm_deepgram_api_key / fm_elevenlabs_api_key
#     Print the API key to stdout when available. Prefer the process environment
#     (DEEPGRAM_API_KEY / ELEVENLABS_API_KEY). Otherwise read only that key from
#     the home's gitignored .env (FM_DEEPGRAM_ENV_FILE overrides its path for
#     both). Never prints the key to stderr. Exit 0 with empty stdout when absent.
#   fm_deepgram_load_dotenv_key
#     Internal: read one key from a .env-style file without sourcing it.
#   fm_deepgram_tts_model / fm_deepgram_stt_model
#     Resolve model names from the environment, then the home's gitignored
#     .env, then the documented defaults.
#   fm_deepgram_auth_config <key> / fm_elevenlabs_auth_config <key>
#     Write a 0600 curl config file carrying the provider's auth header
#     (Authorization: Token, or xi-api-key) and print its path, so the key never
#     appears in curl's argv. Caller removes it.
#   fm_stt_setting <key> <default>
#     Print one `key = value` setting from the home's private config/stt, or
#     <default> when the file or key is absent. Last assignment wins; `#`
#     comment lines are ignored. Callers validate the value.
#
# The key is a secret. Callers must never log it, put it in argv of long-lived
# processes that other users can read, or write it to state/.
set -u

FM_DEEPGRAM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_DEEPGRAM_DEFAULT_ROOT="$(cd "$FM_DEEPGRAM_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_DEEPGRAM_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

FM_DEEPGRAM_DEFAULT_TTS_MODEL="${FM_DEEPGRAM_DEFAULT_TTS_MODEL:-aura-2-thalia-en}"
FM_DEEPGRAM_DEFAULT_STT_MODEL="${FM_DEEPGRAM_DEFAULT_STT_MODEL:-nova-3}"

# Read one KEY=VALUE from a .env-style file without sourcing. Last assignment
# wins. Tolerates optional export, surrounding whitespace, and one matching
# quote layer. Prints nothing when the file or key is absent.
fm_deepgram_load_dotenv_key() {  # <key> <file>
  local key=$1 file=$2
  [ -f "$file" ] || return 0
  [ ! -L "$file" ] || return 0
  python3 - "$key" "$file" <<'PY'
import re, sys
key, path = sys.argv[1], sys.argv[2]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    raise SystemExit(0)
pat = re.compile(
    r"(?m)^(?:export\s+)?" + re.escape(key) + r"\s*=\s*(.*)$"
)
val = ""
for m in pat.finditer(text):
    raw = m.group(1).strip()
    if raw[:1] in "'\"" and raw[-1:] == raw[:1] and len(raw) >= 2:
        raw = raw[1:-1]
    # Strip an inline comment only when unquoted and preceded by space.
    if " #" in raw:
        raw = raw.split(" #", 1)[0].rstrip()
    val = raw.strip()
if val:
    sys.stdout.write(val)
PY
}

# Print one secret from the environment, else from the home's .env.
fm_voice_api_key() {  # <variable>
  local name=$1 key env_file
  if [ -n "${!name:-}" ]; then
    printf '%s' "${!name}"
    return 0
  fi
  env_file="${FM_DEEPGRAM_ENV_FILE:-$FM_HOME/.env}"
  key=$(fm_deepgram_load_dotenv_key "$name" "$env_file") || key=
  printf '%s' "$key"
}

fm_deepgram_api_key() {
  fm_voice_api_key DEEPGRAM_API_KEY
}

fm_elevenlabs_api_key() {
  fm_voice_api_key ELEVENLABS_API_KEY
}

fm_deepgram_tts_model() {
  local model env_file
  if [ -n "${DEEPGRAM_TTS_MODEL:-}" ]; then
    printf '%s' "$DEEPGRAM_TTS_MODEL"
    return 0
  fi
  env_file="${FM_DEEPGRAM_ENV_FILE:-$FM_HOME/.env}"
  model=$(fm_deepgram_load_dotenv_key DEEPGRAM_TTS_MODEL "$env_file") || model=
  printf '%s' "${model:-$FM_DEEPGRAM_DEFAULT_TTS_MODEL}"
}

fm_deepgram_stt_model() {
  local model env_file
  if [ -n "${DEEPGRAM_STT_MODEL:-}" ]; then
    printf '%s' "$DEEPGRAM_STT_MODEL"
    return 0
  fi
  env_file="${FM_DEEPGRAM_ENV_FILE:-$FM_HOME/.env}"
  model=$(fm_deepgram_load_dotenv_key DEEPGRAM_STT_MODEL "$env_file") || model=
  printf '%s' "${model:-$FM_DEEPGRAM_DEFAULT_STT_MODEL}"
}

# Write one curl config file holding <header-line>, readable only by this user.
fm_voice_auth_config() {  # <header-line>
  local header=$1 path
  path=$(umask 077 && mktemp "${TMPDIR:-/tmp}/fm-deepgram-auth.XXXXXX") || return 1
  chmod 600 "$path" 2>/dev/null || true
  printf 'header = "%s"\n' "$header" > "$path" || {
    rm -f "$path"
    return 1
  }
  printf '%s' "$path"
}

fm_deepgram_auth_config() {  # <key>
  fm_voice_auth_config "Authorization: Token $1"
}

fm_elevenlabs_auth_config() {  # <key>
  fm_voice_auth_config "xi-api-key: $1"
}

fm_stt_setting() {  # <key> <default>
  local key=$1 default=$2 file="$FM_HOME/config/stt" val=
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    val=$(awk -v k="$key" '
      /^[[:space:]]*#/ { next }
      {
        line = $0
        eq = index(line, "=")
        if (!eq) next
        name = substr(line, 1, eq - 1); gsub(/[[:space:]]/, "", name)
        if (name != k) next
        v = substr(line, eq + 1); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        found = v
      }
      END { printf "%s", found }
    ' "$file" 2>/dev/null) || val=
  fi
  printf '%s' "${val:-$default}"
}
