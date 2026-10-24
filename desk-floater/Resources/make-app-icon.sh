#!/usr/bin/env bash
# Regenerate the desk floater's app icon, AppIcon.icns, from its SVG sources.
#
# Usage:
#   desk-floater/Resources/make-app-icon.sh
#
# AppIcon.svg is the icon; AppIcon-small.svg is its simplified twin for the
# 16 and 32 px slots, where the full drawing's detail turns to mush. Both are
# rendered through WebKit by render-svg.swift and packed with iconutil, so
# only macOS and Swift are needed. The generated AppIcon.icns is committed, so
# building the floater (bin/fm-desk-floater.sh) needs no SVG tools; rerun this
# after editing either SVG and commit the new .icns.
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/render-svg" "$DIR/render-svg.swift"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
render() {  # <svg> <iconset name> <pixels>
  "$WORK/render-svg" "$DIR/$1" "$SET/$2.png" "$3"
}
render AppIcon-small.svg icon_16x16 16
render AppIcon-small.svg icon_16x16@2x 32
render AppIcon-small.svg icon_32x32 32
render AppIcon.svg icon_32x32@2x 64
render AppIcon.svg icon_128x128 128
render AppIcon.svg icon_128x128@2x 256
render AppIcon.svg icon_256x256 256
render AppIcon.svg icon_256x256@2x 512
render AppIcon.svg icon_512x512 512
render AppIcon.svg icon_512x512@2x 1024
iconutil -c icns -o "$DIR/AppIcon.icns" "$SET"
printf '%s\n' "$DIR/AppIcon.icns"
