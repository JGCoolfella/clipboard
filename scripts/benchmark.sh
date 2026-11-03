#!/bin/zsh
set -eu
cd "${0:A:h}/.."
TASK_BENCH_DIR=$(mktemp -d /private/tmp/clipboard-benchmark.XXXXXX)
trap 'rm -rf "$TASK_BENCH_DIR"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -O Sources/AppIdentity.swift Sources/Models.swift Sources/Integrations.swift Sources/Security.swift Sources/Persistence.swift Tests/Benchmark.swift -o "$TASK_BENCH_DIR/benchmark" -framework AppKit -framework Carbon -framework Security -framework CryptoKit -framework ServiceManagement
"$TASK_BENCH_DIR/benchmark"
