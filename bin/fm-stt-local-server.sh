#!/usr/bin/env bash
# Run the local speech-to-text engine (mlx-audio's OpenAI-compatible server)
# as a per-user launchd agent, so it starts at login and listens on
# 127.0.0.1 only.
#
# Usage:
#   fm-stt-local-server.sh install     write the agent and start it
#   fm-stt-local-server.sh start       start the installed agent
#   fm-stt-local-server.sh stop        stop it until the next start or login
#   fm-stt-local-server.sh uninstall   stop it and remove the agent
#   fm-stt-local-server.sh status      print running or stopped, and the URL
#   fm-stt-local-server.sh --help
#
# Needs mlx-audio installed for this user first, for example:
#   uv tool install --python 3.12 'mlx-audio[server]'
# The agent runs `mlx_audio.server --host 127.0.0.1 --port <port>`; the port
# is FM_STT_LOCAL_PORT, default 8765, matching the default local_url in
# config/stt. The model (local_model in config/stt, default Parakeet TDT 0.6B
# v3) is named by each request, downloaded from Hugging Face on first use and
# loaded on the first transcription, so the first answer is slow.
#
# Agent label com.starship.stt-local, file
# ~/Library/LaunchAgents/com.starship.stt-local.plist, log
# ~/Library/Logs/starship-stt-local.log (the server's own logs beside it in
# ~/Library/Logs/starship-stt-local/). macOS only.
#
# Exit: 0 done, 1 a launchctl or install step failed, 2 bad usage or
# mlx_audio.server not found.
set -eu

LABEL=com.starship.stt-local
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/starship-stt-local.log"
LOG_DIR="$HOME/Library/Logs/starship-stt-local"
PORT=${FM_STT_LOCAL_PORT:-8765}
DOMAIN="gui/$(id -u)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die() {
  printf 'fm-stt-local-server: %s\n' "$*" >&2
  exit "${2:-1}"
}

loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

start() {
  [ -f "$PLIST" ] || die "not installed; run: fm-stt-local-server.sh install" 2
  loaded || launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap failed"
}

stop() {
  ! loaded || launchctl bootout "$DOMAIN/$LABEL" || die "launchctl bootout failed"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    loaded || return 0
    sleep 1
  done
  die "the agent is still loaded 10 seconds after bootout"
}

install() {
  local server
  server=$(command -v mlx_audio.server) || die "mlx_audio.server not found; install mlx-audio first (see --help)" 2
  mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
  stop
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$server</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$PORT</string>
    <string>--log-dir</string><string>$LOG_DIR</string>
  </array>
  <key>WorkingDirectory</key><string>$LOG_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  start
}

case "${1:-}" in
  --help|-h) usage ;;
  install) install ;;
  start) start ;;
  stop) stop ;;
  uninstall) stop; rm -f "$PLIST" ;;
  status)
    if loaded; then state=running; else state=stopped; fi
    printf '%s http://127.0.0.1:%s/v1/audio/transcriptions\n' "$state" "$PORT"
    ;;
  *) usage; exit 2 ;;
esac
