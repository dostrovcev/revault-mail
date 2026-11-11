#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d /tmp/revault-mail-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/revault-swift-module-cache}"
swiftc -parse-as-library Sources/ReVaultMail/Mail/MailSearch.swift Sources/ReVaultMail/Util/InterfaceMetrics.swift Tests/ReVaultMailTests/MailSearchTests.swift -o "$test_dir/search-tests"
"$test_dir/search-tests"
