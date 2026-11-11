#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d /tmp/revault-agent-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/revault-swift-module-cache}"
swiftc -parse-as-library Sources/ReVaultMail/Agent/LocalAgentCLI.swift Tests/AgentCLITests.swift -o "$test_dir/agent-tests"
"$test_dir/agent-tests"
