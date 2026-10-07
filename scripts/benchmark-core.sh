#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swift-environment.sh"
benchmark_directory="$(mktemp -d "${TMPDIR:-/tmp}/paddock-benchmark.XXXXXX")"
trap 'rm -rf "$benchmark_directory"' EXIT
"$swift_compiler" --version
uname -m
sw_vers
"$swift_compiler" "${swift_flags[@]}" -O -parse-as-library \
    "$project_root"/Sources/PaddockCore/*.swift \
    "$project_root/scripts/benchmarks/CoreBenchmark.swift" -o "$benchmark_directory/Benchmark"
"$benchmark_directory/Benchmark" "$@"
