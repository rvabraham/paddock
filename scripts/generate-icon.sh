#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/swift-environment.sh"
icon_stage="$(mktemp -d "$project_root/.build/AppIcon.XXXXXX")"
trap 'rm -rf "$icon_stage"' EXIT
iconset="$icon_stage/AppIcon.iconset"
mkdir -p "$iconset" "$project_root/Resources"
"$swift_compiler" "${swift_flags[@]}" "$project_root/scripts/generate-icon.swift" \
    -o "$icon_stage/generate-icon"
"$icon_stage/generate-icon" "$iconset"
iconutil --convert icns --output "$icon_stage/AppIcon.icns" "$iconset"
mv "$icon_stage/AppIcon.icns" "$project_root/Resources/AppIcon.icns"
printf 'Generated %s\n' "$project_root/Resources/AppIcon.icns"
