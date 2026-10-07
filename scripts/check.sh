#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for script in "$project_root"/scripts/*.sh; do
    bash -n "$script"
done
plutil -lint "$project_root/Resources/Info.plist"
printf 'Developer script and property list checks passed.\n'
