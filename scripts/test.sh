#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/swift-environment.sh"
cd "$project_root"
test_directory="$(mktemp -d "$project_root/.build/verification.XXXXXX")"
trap 'status=$?; if [[ "$status" -eq 0 ]]; then rm -rf "$test_directory"; else printf "Test build preserved at %s\n" "$test_directory" >&2; fi' EXIT
mkdir -p "$test_directory/modules"
developer_directory="$(xcode-select -p)"
if [[ -d "$developer_directory/Library/Developer/Frameworks/Testing.framework" ]]; then
    testing_frameworks="$developer_directory/Library/Developer/Frameworks"
elif [[ -d "$developer_directory/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework" ]]; then
    testing_frameworks="$developer_directory/Platforms/MacOSX.platform/Developer/Library/Frameworks"
else
    printf 'Swift Testing.framework was not found in the selected Apple developer tools.\n' >&2
    exit 1
fi

cat > "$test_directory/TestMain.swift" <<'SWIFT'
import Testing
import Darwin
@main struct PaddockTestMain {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
SWIFT

"$swift_compiler" "${swift_flags[@]}" -Onone -enable-testing -parse-as-library \
    -emit-library -emit-module -module-name PaddockCore \
    -emit-module-path "$test_directory/modules/PaddockCore.swiftmodule" \
    -Xlinker -install_name -Xlinker '@rpath/libPaddockCore.dylib' \
    "$project_root"/Sources/PaddockCore/*.swift \
    -o "$test_directory/libPaddockCore.dylib"

testing_plugin="$(dirname "$swift_compiler")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
test_flags=(-F "$testing_frameworks" -framework Testing)
if [[ ! -d "$testing_frameworks/_Testing_Foundation.framework/Modules" ]]; then
    # CLT may ship the overlay dylib without its Swift module. The tests use
    # Testing's standard Equatable checks, so its Foundation overlay is optional.
    test_flags+=(-Xfrontend -disable-cross-import-overlays)
fi
if [[ -f "$testing_plugin" ]]; then
    test_flags+=(-load-plugin-library "$testing_plugin")
fi
"$swift_compiler" "${swift_flags[@]}" "${test_flags[@]}" -parse-as-library \
    -I "$test_directory/modules" -L "$test_directory" -lPaddockCore \
    -Xlinker -rpath -Xlinker '@executable_path' \
    -Xlinker -rpath -Xlinker "$testing_frameworks" \
    "$project_root"/Tests/PaddockCoreTests/*.swift "$test_directory/TestMain.swift" \
    -o "$test_directory/PaddockTests"
"$test_directory/PaddockTests" "$@"
