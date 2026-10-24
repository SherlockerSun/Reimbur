#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/verification
swiftc -swift-version 5 -D REIMBUR_VERIFY -parse-as-library -I Sources/CSQLite \
    Sources/Reimbur/*.swift Tests/Verification.swift -o .build/verification/ReimburChecks
.build/verification/ReimburChecks
