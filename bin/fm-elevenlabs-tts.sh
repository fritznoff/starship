#!/usr/bin/env bash
# Synthesize one line with ElevenLabs text-to-speech and play it on this Mac.
#
# Usage:
#   fm-elevenlabs-tts.sh [--dry-run] [--to <audio-file>] [--voice <id>] [--model <id>] <text>
#   fm-elevenlabs-tts.sh --help
#
# Reads ELEVENLABS_API_KEY from the environment or the home's gitignored .env
# (see bin/fm-deepgram-lib.sh). Never logs the key; it travels to curl in a
# 0600 config file as the xi-api-key header, never in argv.
#
# Default voice: JBFqnCBsd6RMkjVDRZzb (an ElevenLabs premade voice); default
# model: eleven_flash_v2_5 (low latency, so a spoken reply is not held up
# waiting for synthesis). bin/fm-speak.sh passes the `elevenlabs_voice` and
# `elevenlabs_model` keys from config/speak as --voice and --model. A voice id
# is letters, digits, `_` and `-` only, since it is part of the request path.
# Output encoding: mp3_44100_128. Played with /usr/bin/afplay unless --to
# writes the bytes and skips playback, or FM_DEEPGRAM_AFPLAY names another
# player. FM_ELEVENLABS_CURL replaces curl, for tests.
#
# Exit:
#   0  synthesized (and played, unless --to / --dry-run)
#   1  request or playback failure
#   2  missing key, empty text, or bad usage
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

AFPLAY_BIN="${FM_DEEPGRAM_AFPLAY:-/usr/bin/afplay}"
CURL_BIN="${FM_ELEVENLABS_CURL:-curl}"
DEFAULT_VOICE=JBFqnCBsd6RMkjVDRZzb
DEFAULT_MODEL=eleven_flash_v2_5

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-elevenlabs-tts: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

refuse() {
  note "$*"
  exit 2
}

main() {
  local dry_run=false out_file='' text='' key voice=$DEFAULT_VOICE model=$DEFAULT_MODEL
  local tmp http body auth_cfg
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) dry_run=true; shift ;;
      --to|--voice|--model)
        [ "$#" -ge 2 ] || refuse "$1 needs a value"
        case "$1" in
          --to) out_file=$2 ;;
          --voice) [ -z "$2" ] || voice=$2 ;;
          --model) [ -z "$2" ] || model=$2 ;;
        esac
        shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  case "$voice" in
    *[!A-Za-z0-9_-]*) refuse "voice id must be letters, digits, _ or - only: $voice" ;;
  esac
  [ "$#" -gt 0 ] || refuse "nothing to speak"
  text=$*
  case "$text" in
    *[![:space:]]*) ;;
    *) refuse "nothing to speak" ;;
  esac

  key=$(fm_elevenlabs_api_key)
  [ -n "$key" ] || refuse "ELEVENLABS_API_KEY is not set (env or gitignored .env)"

  if [ "$dry_run" = true ]; then
    printf 'elevenlabs-tts voice=%s model=%s chars=%s\n' "$voice" "$model" "${#text}"
    exit 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-elevenlabs-tts.XXXXXX") || die "cannot create a temporary file"
  # Rename to .mp3 so afplay sniffs correctly on some macOS builds.
  mv "$tmp" "$tmp.mp3"
  tmp=$tmp.mp3
  body=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "model_id": sys.argv[2]}))' \
    "$text" "$model") || {
    rm -f "$tmp"
    die "cannot encode request body"
  }

  auth_cfg=$(fm_elevenlabs_auth_config "$key") || {
    rm -f "$tmp"
    die "cannot create the auth config file"
  }
  trap 'rm -f "$auth_cfg"' EXIT
  http=$("$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" \
    --request POST \
    --connect-timeout 15 \
    --max-time 60 \
    --config "$auth_cfg" \
    --header "Content-Type: application/json" \
    --header "Accept: audio/mpeg" \
    --data "$body" \
    --url "https://api.elevenlabs.io/v1/text-to-speech/${voice}?output_format=mp3_44100_128") || {
    rm -f "$tmp"
    die "curl failed talking to ElevenLabs"
  }
  rm -f "$auth_cfg"

  if [ "$http" != "200" ]; then
    note "ElevenLabs text-to-speech failed HTTP $http"
    # Body may be an error JSON; never echo headers that could carry the key.
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    rm -f "$tmp"
    exit 1
  fi

  if [ -n "$out_file" ]; then
    mv "$tmp" "$out_file" || die "cannot write $out_file"
    printf '%s\n' "$out_file"
    exit 0
  fi

  if [ ! -x "$AFPLAY_BIN" ]; then
    rm -f "$tmp"
    die "no audio player at $AFPLAY_BIN (set FM_DEEPGRAM_AFPLAY)"
  fi
  "$AFPLAY_BIN" "$tmp" || {
    rm -f "$tmp"
    die "afplay failed"
  }
  rm -f "$tmp"
  exit 0
}

main "$@"
