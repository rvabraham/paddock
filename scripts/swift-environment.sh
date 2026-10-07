#!/bin/bash
# Shared by build, test, and icon generation. Source this file from bash.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$project_root/.build/cache"
swift_compiler="$(xcrun --find swiftc)"
swift_sdk="$(xcrun --sdk macosx --show-sdk-path)"
swift_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -target "$(uname -m)-apple-macosx26.0" -sdk "$swift_sdk" -module-cache-path "$CLANG_MODULE_CACHE_PATH")

# Some upgraded CLT installations retain an obsolete duplicate module map.
# Hide only that duplicate from this build with a VFS overlay, never by
# modifying Apple's toolchain. Healthy installations need no workaround.
swift_include="$(dirname "$swift_compiler")/../include/swift"
if [[ -f "$swift_include/module.modulemap" && -f "$swift_include/bridging.modulemap" ]] \
    && grep -q 'module SwiftBridging' "$swift_include/module.modulemap" \
    && grep -q 'module SwiftBridging' "$swift_include/bridging.modulemap"; then
    swift_include="$(cd "$swift_include" && pwd)"
    overlay_directory="$project_root/.build/toolchain-overlay"
    mkdir -p "$overlay_directory"
    printf '// Locally hide an obsolete duplicate SwiftBridging definition.\n' > "$overlay_directory/empty.modulemap"
    overlay_source="$(printf '%s' "$swift_include/module.modulemap" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    overlay_destination="$(printf '%s' "$overlay_directory/empty.modulemap" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    overlay_staging="$(mktemp "$overlay_directory/.overlay.XXXXXX")"
    if ! printf '{"version":0,"roots":[{"type":"file","name":"%s","external-contents":"%s"}]}\n' \
        "$overlay_source" "$overlay_destination" > "$overlay_staging"; then
        rm -f "$overlay_staging"
        return 1
    fi
    mv "$overlay_staging" "$overlay_directory/overlay.json"
    swift_flags+=(-vfsoverlay "$overlay_directory/overlay.json" -Xcc -ivfsoverlay -Xcc "$overlay_directory/overlay.json")
fi
