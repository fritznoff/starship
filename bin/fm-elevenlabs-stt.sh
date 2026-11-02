#!/usr/bin/env bash
# Transcribe one audio file with ElevenLabs Scribe speech-to-text.
#
# Usage:
#   fm-elevenlabs-stt.sh [--json] [--keyterms <file>] <audio-file>
#   fm-elevenlabs-stt.sh --help
#
# Reads ELEVENLABS_API_KEY from the environment or the home's gitignored .env
# (see bin/fm-deepgram-lib.sh). Never logs the key; it travels to curl in a
# 0600 config file as the xi-api-key header, never in argv.
#
# Posts the file to https://api.elevenlabs.io/v1/speech-to-text as multipart
# form data and prints the transcript text on stdout (or the raw JSON answer,
# whose `text` field holds the transcript, with --json). The model is
# `elevenlabs_model` in the home's private config/stt (docs/configuration.md
# owns the file), default scribe_v2; the language is detected automatically.
# Audio events such as (laughter) are not tagged.
#
# --keyterms names a file of key terms, one per line, each sent as a
# `keyterms` form field to bias recognition. bin/fm-deepgram-stt.sh, which
# owns config/stt-vocabulary and its rewrites, writes that file when ElevenLabs
# is the selected engine; this helper applies no vocabulary of its own. Terms
# ElevenLabs would refuse (50 characters or more, more than five words, or any
# of < > { } [ ] \) are skipped, and at most 100 are sent: above 100,
# ElevenLabs bills every request as at least 20 seconds. Key terms add a
# surcharge to each request that carries them.
#
# The request is bounded like bin/fm-deepgram-stt.sh's: it gives up connecting
# after 15 seconds, in all after 120 seconds plus one second per 100 kB of
# audio, and once nothing has moved for 20 seconds plus one second per MB;
# a stalled or timed-out attempt, a dropped connection or a busy server is
# retried twice, three seconds apart. FM_ELEVENLABS_CURL replaces curl, for
# tests.
#
# Exit:
#   0  transcript printed (may be empty if ElevenLabs heard silence)
#   1  request failure or unexpected answer
#   2  missing key, missing file, or bad usage
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

CURL_BIN="${FM_ELEVENLABS_CURL:-curl}"
FM_ELEVENLABS_DEFAULT_STT_MODEL=scribe_v2

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-elevenlabs-stt: %s\n' "$*" >&2
}

refuse() {
  note "$*"
  exit 2
}

die() {
  note "$*"
  exit 1
}

# Print the key terms ElevenLabs accepts from <file>, one per line, at most 100.
accepted_keyterms() {  # <file>
  [ -n "$1" ] || return 0
  python3 - "$1" <<'PY' || true
import sys
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    raise SystemExit(0)
sent = []
for line in lines:
    term = " ".join(line.split())
    if not term or term in sent or len(term) >= 50 or len(term.split()) > 5:
        continue
    if any(c in term for c in "<>{}[]\\"):
        continue
    sent.append(term)
    if len(sent) == 100:
        break
sys.stdout.write("".join(t + "\n" for t in sent))
PY
}

main() {
  local json_out=false audio='' terms_file='' key model http tmp auth_cfg bytes max_time stall_time term quoted
  local -a form=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --json) json_out=true; shift ;;
      --keyterms)
        [ "$#" -ge 2 ] || refuse "--keyterms needs a file"
        terms_file=$2
        shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || refuse "usage: fm-elevenlabs-stt.sh [--json] [--keyterms <file>] <audio-file>"
  audio=$1
  [ -f "$audio" ] || refuse "audio file not found: $audio"

  key=$(fm_elevenlabs_api_key)
  [ -n "$key" ] || refuse "ELEVENLABS_API_KEY is not set (env or gitignored .env)"
  model=$(fm_stt_setting elevenlabs_model "$FM_ELEVENLABS_DEFAULT_STT_MODEL")

  form=(--form-string "model_id=$model" --form-string "tag_audio_events=false")
  while IFS= read -r term; do
    form+=(--form-string "keyterms=$term")
  done < <(accepted_keyterms "$terms_file")

  # Quoted so curl reads a path holding `;` or `,` as the file name.
  quoted=${audio//\\/\\\\}
  quoted=${quoted//\"/\\\"}
  bytes=$(wc -c < "$audio" | tr -d ' ')
  max_time=$(( 120 + ${bytes:-0} / 100000 ))
  stall_time=$(( 20 + ${bytes:-0} / 1000000 ))

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-elevenlabs-stt.XXXXXX") || die "cannot create a temporary file"
  auth_cfg=$(fm_elevenlabs_auth_config "$key") || {
    rm -f "$tmp"
    die "cannot create the auth config file"
  }
  trap 'rm -f "$auth_cfg"' EXIT
  http=$("$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" \
    --request POST \
    --connect-timeout 15 \
    --max-time "$max_time" \
    --speed-limit 1 \
    --speed-time "$stall_time" \
    --retry 2 \
    --retry-delay 3 \
    --retry-connrefused \
    --config "$auth_cfg" \
    "${form[@]}" \
    --form "file=@\"$quoted\"" \
    --url "https://api.elevenlabs.io/v1/speech-to-text") || {
    rm -f "$tmp"
    die "curl failed talking to ElevenLabs (no answer within ${max_time}s, nothing moving for ${stall_time}s, or the connection failed)"
  }
  rm -f "$auth_cfg"

  if [ "$http" != "200" ]; then
    note "ElevenLabs speech-to-text failed HTTP $http"
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    rm -f "$tmp"
    exit 1
  fi

  if [ "$json_out" = true ]; then
    cat "$tmp"
  elif ! python3 -c '
import json, sys
text = json.load(open(sys.argv[1], encoding="utf-8"))["text"]
if not isinstance(text, str):
    raise TypeError("text is not a string")
sys.stdout.write(text + ("\n" if text and not text.endswith("\n") else ""))
' "$tmp"; then
    rm -f "$tmp"
    die "unexpected answer from ElevenLabs"
  fi
  rm -f "$tmp"
  exit 0
}

main "$@"
