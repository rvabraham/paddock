#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/swift-environment.sh"
configuration="${1:-release}"
case "$configuration" in
    release|debug) ;;
    *) printf 'Usage: %s [release|debug]\n' "$0" >&2; exit 2 ;;
esac

cd "$project_root"
mkdir -p "$project_root/build"

stage_directory="$(mktemp -d "$project_root/build/.Paddock-stage.XXXXXX")"
trap 'rm -rf "$stage_directory"' EXIT
app_directory="$stage_directory/Paddock.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources" \
    "$app_directory/Contents/Frameworks" "$stage_directory/modules"

if [[ "$configuration" == release ]]; then
    swift_flags+=(-O)
else
    swift_flags+=(-Onone -g -enable-testing)
fi

printf 'Building PaddockCore (%s)…\n' "$configuration"
"$swift_compiler" "${swift_flags[@]}" -parse-as-library -emit-library -emit-module \
    -module-name PaddockCore \
    -emit-module-path "$stage_directory/modules/PaddockCore.swiftmodule" \
    -Xlinker -install_name -Xlinker '@rpath/libPaddockCore.dylib' \
    "$project_root"/Sources/PaddockCore/*.swift \
    -o "$app_directory/Contents/Frameworks/libPaddockCore.dylib"
printf 'Building Paddock…\n'
"$swift_compiler" "${swift_flags[@]}" -parse-as-library \
    -I "$stage_directory/modules" -L "$app_directory/Contents/Frameworks" -lPaddockCore \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    "$project_root"/Sources/PaddockApp/*.swift \
    -o "$app_directory/Contents/MacOS/Paddock"

if [[ ! -f "$project_root/Resources/AppIcon.icns" ]]; then
    "$project_root/scripts/generate-icon.sh"
fi
cp "$project_root/Resources/Info.plist" "$app_directory/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_directory/Contents/Resources/AppIcon.icns"
cp "$project_root/LICENSE" "$project_root/THIRD_PARTY_NOTICES.md" "$app_directory/Contents/Resources/"

plutil -lint "$app_directory/Contents/Info.plist"
codesign --force --sign - "$app_directory/Contents/Frameworks/libPaddockCore.dylib"
codesign --force --sign - "$app_directory"
codesign --verify --deep --strict "$app_directory"

# Do not replace a working app until the complete new bundle passes validation.
destination="$project_root/build/Paddock.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$stage_directory/previous.app"
fi
if ! mv "$app_directory" "$destination"; then
    if [[ -e "$stage_directory/previous.app" ]]; then
        mv "$stage_directory/previous.app" "$destination"
    fi
    exit 1
fi
printf '\nBuilt %s\n' "$destination"
