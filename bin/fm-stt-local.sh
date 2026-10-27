#!/usr/bin/env bash
# Transcribe one audio file with the local OpenAI-compatible speech-to-text
# engine (by default mlx-audio serving Parakeet TDT 0.6B v3 on this Mac).
#
# Usage:
#   fm-stt-local.sh [--json] <audio-file>
#   fm-stt-local.sh --help
#
# Posts the file to the endpoint's /v1/audio/transcriptions route as
# multipart form data with response_format=json, and prints the transcript
# text on stdout (or the raw `{"text": ...}` JSON with --json). Vocabulary
# rewrites are not applied here; bin/fm-deepgram-stt.sh applies them when the
# local engine is the primary provider.
#
# Settings, from the home's private config/stt (docs/configuration.md owns
# the file):
#   local_url    default http://127.0.0.1:8765/v1/audio/transcriptions
#   local_model  default mlx-community/parakeet-tdt-0.6b-v3
#
# A file that is not .wav is first converted to 16 kHz mono WAV with ffmpeg,
# or macOS afconvert when ffmpeg is absent, because mlx-audio reads WAV, FLAC
# and MP3 but not M4A. Nothing leaves this Mac unless local_url names another
# host.
#
# The request gives up connecting after 3 seconds and in all after 300
# seconds plus one second per 50 kB of audio.
#
# Exit:
#   0  transcript printed (may be empty)
#   1  request failure or unexpected answer
#   2  missing file or bad usage
#   3  the local engine is not reachable (not running)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

CURL_BIN="${FM_STT_LOCAL_CURL:-curl}"
FM_STT_LOCAL_DEFAULT_URL=http://127.0.0.1:8765/v1/audio/transcriptions
FM_STT_LOCAL_DEFAULT_MODEL=mlx-community/parakeet-tdt-0.6b-v3

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-stt-local: %s\n' "$*" >&2
}

refuse() {
  note "$*"
  exit 2
}

die() {
  note "$*"
  exit 1
}

to_wav() {  # <in> <out>
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -nostdin -loglevel error -y -i "$1" -ac 1 -ar 16000 "$2"
  else
    afconvert -f WAVE -d LEI16@16000 -c 1 "$1" "$2"
  fi
}

main() {
  local json_out=false audio send url model tmp wav='' http rc bytes max_time
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --json) json_out=true; shift ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || refuse "usage: fm-stt-local.sh [--json] <audio-file>"
  audio=$1
  [ -f "$audio" ] || refuse "audio file not found: $audio"
  url=$(fm_stt_setting local_url "$FM_STT_LOCAL_DEFAULT_URL")
  model=$(fm_stt_setting local_model "$FM_STT_LOCAL_DEFAULT_MODEL")

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-stt-local.XXXXXX") || die "cannot create a temporary file"
  trap 'rm -f "$tmp" ${wav:+"$wav"}' EXIT
  send=$audio
  case "$audio" in
    *.wav|*.WAV) ;;
    *)
      wav=$(mktemp "${TMPDIR:-/tmp}/fm-stt-local-wav.XXXXXX") || die "cannot create a temporary file"
      mv "$wav" "$wav.wav"
      wav=$wav.wav
      to_wav "$audio" "$wav" || die "cannot convert $audio to WAV"
      send=$wav
      ;;
  esac

  bytes=$(wc -c < "$send" | tr -d ' ')
  max_time=$(( 300 + ${bytes:-0} / 50000 ))
  rc=0
  http=$("$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" \
    --connect-timeout 3 \
    --max-time "$max_time" \
    -F "file=@${send};type=audio/wav" \
    -F "model=${model}" \
    -F "response_format=json" \
    --url "$url") || rc=$?
  case "$rc" in
    0) ;;
    6|7) note "local engine not reachable at $url"; exit 3 ;;
    *) die "curl failed talking to the local engine (exit $rc, limit ${max_time}s)" ;;
  esac
  if [ "$http" != "200" ]; then
    note "local engine failed HTTP $http"
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    exit 1
  fi
  if [ "$json_out" = true ]; then
    cat "$tmp"
    exit 0
  fi
  python3 -c '
import json, sys
text = json.load(open(sys.argv[1], encoding="utf-8")).get("text", "")
sys.stdout.write(text + ("\n" if text and not text.endswith("\n") else ""))
' "$tmp" || die "could not parse the local engine JSON"
}

main "$@"
