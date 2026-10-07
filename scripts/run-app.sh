#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$project_root/scripts/build-app.sh" "${1:-release}"
open "$project_root/build/Paddock.app"
